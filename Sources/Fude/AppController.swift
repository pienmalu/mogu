import AppKit
import Combine

/// 部品をつなぐ。メニューバーの項目、ホットキー、窓、一覧、エディタ。
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fude" }

    private var store: NoteStore!
    private var editor: EditorController!
    private var mainWindow: MainWindow!
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
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

        let sidebar = Sidebar(store: store,
                              onNew: { [weak self] in self?.newNote() },
                              onOpenFirst: { [weak self] in self?.openFirstResult() },
                              onChooseFolder: { [weak self] in self?.chooseFolder() })
        mainWindow = MainWindow(store: store, editor: editor, sidebar: sidebar)

        // 一覧で選んだら開く。エディタが保存して新しいファイルができたら、一覧の選択をそれに合わせる。
        store.$selection
            .removeDuplicates()
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
        hotKey = GlobalHotKey { [weak self] in self?.hotKeyPressed() }

        editor.newNote()
        showWindow()
    }

    func shutdown() {
        editor?.save()
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

    @objc func focusSearch() {
        mainWindow.show(focusEditor: false)
        if mainWindow.split.splitViewItems.first?.isCollapsed == true {
            mainWindow.split.splitViewItems.first?.animator().isCollapsed = false
        }
        store.focusSearch.send()
    }

    private func openFirstResult() {
        guard let first = store.visible.first else { return }
        store.selection = first.url
        mainWindow.window.makeFirstResponder(editor.textView)
    }

    @objc func copyAsMarkdown() { editor.copyAll() }

    @objc func trashCurrent() {
        guard let url = editor.url else {
            editor.discard()
            return
        }
        editor.discard()
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
        button.image = NSImage(systemSymbolName: "text.justify.left", accessibilityDescription: Self.appName)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        menu.addItem(item("新しいメモ（\(GlobalHotKey.defaultLabel)）", #selector(newNote)))
        menu.addItem(item("開く", #selector(showFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("保存先：\(store.folder.lastPathComponent)…", #selector(chooseFolder)))
        menu.addItem(item("Finder で開く", #selector(revealInFinder)))
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
        file.addItem(item("ノートを探す", #selector(focusSearch), key: "p"))
        file.addItem(item("Markdown でコピー", #selector(copyAsMarkdown), key: "c", modifiers: [.command, .shift]))
        file.addItem(item("Finder で表示", #selector(revealInFinder), key: "r", modifiers: [.command, .shift]))
        file.addItem(item("ゴミ箱に入れる", #selector(trashCurrent)))
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
        add(edit, to: main, title: "編集")

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
