import AppKit
import Combine
import SwiftUI

/// 部品をつなぐ。メニューバーの項目、ホットキー、窓、一覧、エディタ。
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Mogu" }

    private var store: NoteStore!
    private var editor: EditorController!
    private var mainWindow: MainWindow!
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var meetingHotKey: GlobalHotKey?
    private var meeting: MeetingController!
    private var quickOpen: QuickOpen!
    private var server: LLMServer!
    private var rewriteWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    static var defaultFolder: URL {
        // 書類フォルダは避ける（簡易署名だとビルドのたびにアクセス許可を聞かれるため）。
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Notes")
    }

    func launch() {
        let saved = UserDefaults.standard.string(forKey: NoteStore.folderKey).map { URL(fileURLWithPath: $0) }
        let folder = saved ?? Self.defaultFolder
        store = NoteStore(folder: folder)
        editor = EditorController(folder: folder)

        server = LLMServer(home: LLMServer.locateHome())
        meeting = MeetingController(home: LLMServer.locateHome(), editor: editor, store: store, server: server,
                                    showWindow: { [weak self] in self?.showWindow() })
        let sidebar = Sidebar(store: store, meeting: meeting.session,
                              onSearch: { [weak self] in self?.focusSearch() },
                              onNew: { [weak self] in self?.newNote() },
                              onMeeting: { [weak self] in self?.toggleMeeting() },
                              onChooseFolder: { [weak self] in self?.chooseFolder() },
                              onTrash: { [weak self] in self?.trash($0) })
        quickOpen = QuickOpen(onOpen: { [weak self] in self?.open($0) },
                              onCreate: { [weak self] in self?.createNote(titled: $0) })
        editor.slashMenu.onAction = { [weak self] action in
            switch action {
            case .meeting: self?.toggleMeeting()
            case .rewrite: self?.rewrite()
            default: break
            }
        }
        let bar = MeetingBar(session: meeting.session,
                             onStop: { [weak self] in self?.toggleMeeting() },
                             onCancelSummary: { [weak self] in self?.meeting.cancelSummary() },
                             onInsert: { [weak self] in self?.meeting.insertSummary() })
        mainWindow = MainWindow(store: store, editor: editor, sidebar: sidebar, bar: bar)

        // 一覧で選んだら開く。エディタが保存して新しいファイルができたら、一覧の選択をそれに合わせる。
        store.$selection
            .sink { [weak self] url in
                guard let self, let url, url != self.editor.url else { return }
                self.editor.open(url)
            }
            .store(in: &cancellables)
        editor.onSaved = { [weak self] url in
            guard let self else { return }
            if self.store.selection != url { self.store.selection = url }
            self.store.reload()
        }
        store.onExternalChange = { [weak self] in self?.editor.reloadIfChangedOnDisk() }

        NSApp.mainMenu = buildMainMenu()
        setUpStatusItem()
        hotKey = GlobalHotKey(GlobalHotKey.newNote) { [weak self] in self?.hotKeyPressed() }
        meetingHotKey = GlobalHotKey(GlobalHotKey.meeting) { [weak self] in self?.toggleMeeting() }
        // 録っている間は、メニューバーのアイコンを赤い丸にする（窓を隠していても、録っているとわかるように）
        meeting.session.$phase
            .map { $0 == .recording }
            .removeDuplicates()
            .sink { [weak self] recording in self?.updateStatusIcon(recording: recording) }
            .store(in: &cancellables)
        meeting.recoverLeftover()

        editor.newNote()
        showWindow()
    }

    func shutdown() {
        editor?.save()
        server?.stop()
    }

    // MARK: - 操作

    /// ホットキー：前に出ていれば隠す。隠れていれば新しいメモで出す（書きかけが空ならそれを使う）。
    private func hotKeyPressed() {
        if mainWindow.isFrontmost {
            mainWindow.hide()
        } else {
            if !editor.isBlankNew { newNote() }
            mainWindow.show()
        }
    }

    func showWindow() {
        mainWindow.show()
    }

    @objc func newNote() {
        editor.newNote()
        store.selection = nil
        mainWindow.show()
    }

    @objc func showFromMenu() { showWindow() }

    @objc func hideWindow() { mainWindow.hide() }

    /// ノートを探す窓を出す（もう一度押すと閉じる）。
    @objc func focusSearch() {
        mainWindow.show(focusEditor: false)
        quickOpen.toggle(notes: store.notes, over: mainWindow.window)
    }

    private func open(_ url: URL) {
        store.selection = url
        mainWindow.show()
    }

    /// 探した言葉を題にして、新しいメモを作る。
    private func createNote(titled title: String) {
        newNote()
        editor.insert("# \(title)\n\n", at: 0)
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length, length: 0))
    }

    @objc func copyAsMarkdown() { editor.copyAll() }

    /// 開いているノートなら、エディタから手放してから移す（次の保存で書き戻さないように）。
    func trash(_ url: URL) {
        if editor.url == url { editor.discard() }
        store.trash(url)
    }

    @objc func revealInFinder() {
        if let url = editor.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(store.folder)
        }
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.folder
        panel.prompt = "このフォルダに保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.save()
        editor.folder = url
        editor.newNote()
        store.setFolder(url)
    }

    // MARK: - 議事録

    /// 録っていなければ新しいノートで始め、録っていれば終える。
    @objc func toggleMeeting() {
        meeting.toggle()
    }

    var isRecording: Bool { meeting?.session.isRecording ?? false }

    /// 終了の前に、録っている会議を終えて文字起こしをノートに入れる（要約は作らない）。
    func finishMeeting() async {
        await meeting.stop(summarize: false)
        editor.save()
    }

    // MARK: - 推敲

    /// 選んだ範囲（なければ本文全体）を推敲する。結果はシートで見せ、置き換えるかを選ばせる。
    @objc func rewrite() {
        guard rewriteWindow == nil, !editor.textView.hasMarkedText() else { return }
        let text = editor.textView.string as NSString
        var range = editor.textView.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: text.length) }
        let original = text.substring(with: range)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        let session = RewriteSession(original: original, server: server)
        let sheet = RewriteSheet(session: session,
                                 onAccept: { [weak self] result in
                                     guard let self else { return }
                                     // シートを出している間に本文が変わっていたら、置き換えない
                                     let now = self.editor.textView.string as NSString
                                     if NSMaxRange(range) <= now.length, now.substring(with: range) == original {
                                         self.editor.replace(range, with: result)
                                     } else {
                                         NSSound.beep()
                                     }
                                     self.closeRewrite()
                                 },
                                 onClose: { [weak self] in self?.closeRewrite() })
        let host = NSHostingController(rootView: sheet)
        let window = NSWindow(contentViewController: host)
        rewriteWindow = window
        mainWindow.window.beginSheet(window)
        session.start()
    }

    private func closeRewrite() {
        guard let rewriteWindow else { return }
        mainWindow.window.endSheet(rewriteWindow)
        self.rewriteWindow = nil
        mainWindow.window.makeFirstResponder(editor.textView)
    }

    @objc func chooseModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = RewriteModel(rawValue: raw) else { return }
        RewriteModel.current = model
    }

    @objc func toggleSidebar() {
        mainWindow.split.toggleSidebar(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - メニューバーの項目

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        updateStatusIcon(recording: false)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "議事録を録っています")?
                .withSymbolConfiguration(red)
        } else {
            button.image = NSImage(systemSymbolName: "text.justify.left", accessibilityDescription: Self.appName)
        }
    }

    /// Dock のアイコンを右クリックしたときのメニュー。
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("新しいメモ", #selector(newNote)))
        menu.addItem(item(isRecording ? "議事録を終える" : "議事録を始める", #selector(toggleMeeting)))
        return menu
    }

    /// 左クリックで窓を出し入れ、右クリック（か ⌃クリック）でメニュー。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = buildStatusMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if mainWindow.isFrontmost {
            mainWindow.hide()
        } else {
            mainWindow.show()
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("新しいメモ（\(GlobalHotKey.newNote.label)）", #selector(newNote)))
        menu.addItem(item(isRecording ? "議事録を終える（\(GlobalHotKey.meeting.label)）" : "議事録を始める（\(GlobalHotKey.meeting.label)）",
                          #selector(toggleMeeting)))
        menu.addItem(item("開く", #selector(showFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("保存先：\(store.folder.lastPathComponent)…", #selector(chooseFolder)))
        menu.addItem(item("Finder で開く", #selector(revealInFinder)))
        menu.addItem(.separator())
        let models = NSMenu()
        for model in RewriteModel.allCases {
            let entry = item(model.label, #selector(chooseModel(_:)))
            entry.representedObject = model.rawValue
            entry.state = model == RewriteModel.current ? .on : .off
            models.addItem(entry)
        }
        if !server.isAvailable {
            models.addItem(.separator())
            models.addItem(NSMenuItem(title: "未設定：./scripts/setup.sh を実行", action: nil, keyEquivalent: ""))
        }
        let modelHolder = NSMenuItem(title: "推敲のモデル", action: nil, keyEquivalent: "")
        modelHolder.submenu = models
        menu.addItem(modelHolder)
        menu.addItem(.separator())
        menu.addItem(item("\(Self.appName) を終了", #selector(quit), key: "q"))
        return menu
    }

    // MARK: - キーボードショートカット（メニューバーには出ないが、キーはこれで効く）

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(item("隠す", #selector(hideWindow), key: "w"))
        app.addItem(item("終了", #selector(quit), key: "q"))
        add(app, to: main, title: Self.appName)

        let file = NSMenu(title: "ファイル")
        file.addItem(item("新しいメモ", #selector(newNote), key: "n"))
        file.addItem(item("議事録を始める・終える", #selector(toggleMeeting), key: "r"))
        file.addItem(item("ノートを探す", #selector(focusSearch), key: "p"))
        file.addItem(item("Markdown でコピー", #selector(copyAsMarkdown), key: "c", modifiers: [.command, .shift]))
        file.addItem(item("Finder で表示", #selector(revealInFinder), key: "r", modifiers: [.command, .shift]))
        add(file, to: main, title: "ファイル")

        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "検索", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let next = edit.addItem(withTitle: "次を検索", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = Int(NSFindPanelAction.next.rawValue)
        edit.addItem(.separator())
        edit.addItem(item("推敲", #selector(rewrite), key: "j"))
        add(edit, to: main, title: "編集")

        // 書式。どれも Markdown の記号を足したり外したりする（本文の欄が受け取る）
        let format = NSMenu(title: "書式")
        func formatItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.tag = tag
            format.addItem(entry)
        }
        formatItem("太字", #selector(MarkdownTextView.toggleBold(_:)), "b")
        formatItem("斜体", #selector(MarkdownTextView.toggleItalic(_:)), "i")
        formatItem("取り消し線", #selector(MarkdownTextView.toggleStrike(_:)), "x", [.command, .shift])
        formatItem("コード", #selector(MarkdownTextView.toggleCode(_:)), "e")
        formatItem("リンク", #selector(MarkdownTextView.makeLink(_:)), "k")
        format.addItem(.separator())
        formatItem("ふつうの文", #selector(MarkdownTextView.setHeading(_:)), "0", [.command, .option], tag: 0)
        formatItem("見出し 1", #selector(MarkdownTextView.setHeading(_:)), "1", [.command, .option], tag: 1)
        formatItem("見出し 2", #selector(MarkdownTextView.setHeading(_:)), "2", [.command, .option], tag: 2)
        formatItem("見出し 3", #selector(MarkdownTextView.setHeading(_:)), "3", [.command, .option], tag: 3)
        format.addItem(.separator())
        formatItem("ToDo にする・チェックする", #selector(MarkdownTextView.toggleTask(_:)), "\r")
        formatItem("行を上へ", #selector(MarkdownTextView.moveLineUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .control])
        formatItem("行を下へ", #selector(MarkdownTextView.moveLineDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .control])
        add(format, to: main, title: "書式")

        let view = NSMenu(title: "表示")
        view.addItem(item("一覧を出す・隠す", #selector(toggleSidebar), key: "s", modifiers: [.command, .control]))
        add(view, to: main, title: "表示")
        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu, title: String) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        main.addItem(holder)
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
}
