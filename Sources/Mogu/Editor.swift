import AppKit

/// 本文を書く欄。文字はプレーンテキストのまま持ち、見た目だけ MarkdownStyler で付ける。
final class MarkdownTextView: NSTextView {
    /// 本文の上の余白（窓の上端の信号ボタンと重ならないように）。
    var topInset: CGFloat = 36

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, (newSize.width - Theme.shared.columnWidth) / 2)
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: (topInset + bottomInset) / 2)
        }
    }

    /// ⌘クリックでリンクを開く。チェックボックスは押すと切り替わる。ふつうのクリックはカーソルを置くだけ。
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        if let box = checkbox(at: convert(event.locationInWindow, from: nil)) {
            toggleCheckbox(box)
            return
        }
        super.mouseDown(with: event)
    }

    /// point にあるチェックボックスの `[ ]` の範囲。なければ nil。
    func checkbox(at point: NSPoint) -> NSRange? {
        guard let storage = textStorage, storage.length > 0, let layout = layoutManager as? BlockLayoutManager else { return nil }
        let origin = textContainerOrigin
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        let line = (string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
        var found: NSRange?
        storage.enumerateAttribute(.moguCheckbox, in: line) { value, range, stop in
            guard value != nil, let rect = layout.checkboxRect(at: range.location) else { return }
            if rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4).contains(point) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// `[ ]` と `[x]` を入れ替える（⌘Z で戻せる）。カーソルは動かさない。
    func toggleCheckbox(_ box: NSRange) {
        guard box.length == 3, !hasMarkedText() else { return }
        let mark = NSRange(location: box.location + 1, length: 1)
        let next = (string as NSString).substring(with: mark) == " " ? "x" : " "
        let selection = selectedRange()
        guard shouldChangeText(in: mark, replacementString: next) else { return }
        textStorage?.replaceCharacters(in: mark, with: next)
        didChangeText()
        setSelectedRange(selection)
    }

    /// 本文の下の余白。最後の行が窓の下端に貼り付かないように（議事録のバーとも重ならない）。
    var bottomInset: CGFloat = 96

    /// 上下の余白を別々にする（textContainerInset は上下が同じ値なので、文字の置き場所をずらす）。
    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: topInset)
    }

    private func link(at event: NSEvent) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let url = storage.attribute(.moguLink, at: candidate, effectiveRange: nil) as? URL { return url }
        }
        return nil
    }

    /// 箇条書きの行で改行したら、次の行にも同じ記号を入れる。中身のない行なら記号を消して抜ける。
    /// 日本語の変換中の Enter は確定に使われ、ここには来ない。
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        switch ListContinuation.action(forLineBeforeCursor: before) {
        case .none:
            super.insertNewline(sender)
        case .insert(let prefix):
            insertText("\n" + prefix, replacementRange: selection)
        case .endList:
            insertText("", replacementRange: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        }
    }

    /// ペーストは常に文字だけ（Web やほかのアプリの書式を持ち込まない）。
    /// 文字を選んでいるときに URL を貼ると、選んだ文字がリンクになる。
    override func paste(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, !hasMarkedText(), let pasted = NSPasteboard.general.string(forType: .string), Formatting.isURL(pasted),
           !(string as NSString).substring(with: selection).contains("\n") {
            apply(Formatting.link(string as NSString, selection: selection, url: pasted.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        pasteAsPlainText(sender)
    }

    /// 行頭で `[]` と打って空白を打つと、ToDo になる。
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let typed = string as? String, typed == " " || typed == "　", !hasMarkedText(), selectedRange().length == 0,
           let edit = Formatting.taskShortcut(self.string as NSString, caret: selectedRange().location) {
            apply(edit)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: - 書式（メニューとキーから呼ばれる）

    /// 書き換えを、Undo できる形で行う。
    func apply(_ edit: Formatting.Edit) {
        guard !hasMarkedText() else { return }
        if edit.range.length > 0 || !edit.text.isEmpty {
            guard shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            didChangeText()
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    private func wrap(_ marker: String) {
        apply(Formatting.toggleWrap(string as NSString, selection: selectedRange(), marker: marker))
    }

    @objc func toggleBold(_ sender: Any?) { wrap("**") }
    @objc func toggleItalic(_ sender: Any?) { wrap("*") }
    @objc func toggleStrike(_ sender: Any?) { wrap("~~") }
    @objc func toggleCode(_ sender: Any?) { wrap("`") }
    @objc func makeLink(_ sender: Any?) { apply(Formatting.link(string as NSString, selection: selectedRange())) }
    @objc func toggleTask(_ sender: Any?) { apply(Formatting.toggleTask(string as NSString, selection: selectedRange())) }

    @objc func moveLineUp(_ sender: Any?) {
        if let edit = Formatting.moveLines(string as NSString, selection: selectedRange(), up: true) { apply(edit) }
    }

    @objc func moveLineDown(_ sender: Any?) {
        if let edit = Formatting.moveLines(string as NSString, selection: selectedRange(), up: false) { apply(edit) }
    }

    /// 見出しにする・戻す（メニューの項目の tag が、見出しの段。0 はふつうの文）。
    @objc func setHeading(_ sender: NSMenuItem) {
        apply(Formatting.setBlock(string as NSString, selection: selectedRange(), prefix: sender.tag == 0 ? "" : String(repeating: "#", count: sender.tag) + " "))
    }

    // MARK: - 何も書いていないときの案内

    /// 空のノートに薄く出す文字。
    var placeholder = "書きはじめる。「/」でコマンド"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let font = Theme.shared.bodyFont
        let y = origin.y + ((Theme.shared.lineHeight - (font.ascender - font.descender)) / 2).rounded()
        (placeholder as NSString).draw(at: NSPoint(x: origin.x + padding, y: y),
                                       withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }
}

/// 開いているノート1つを受け持つ。読む・書く・外の変更を取り込む。
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownTextView

    /// 開いているファイル。まだ一度も保存していない新しいメモなら nil。
    private(set) var url: URL?
    var folder: URL
    /// 保存して新しいファイルができたとき・書き込んだときに呼ぶ。
    var onSaved: ((URL) -> Void)?

    private var file = NoteFile()
    /// ディスクにある本文（最後に読んだか書いたもの）。これと違うときだけ書く。
    private var savedBody = ""
    private var diskDate: Date?
    private var saveTimer: Timer?
    /// 「/」で出すコマンドのメニュー。
    private(set) var slashMenu: SlashMenu!
    /// 前に見た目を付けてからの、文字の書き換え。1回だけなら、その行だけ付け直す。
    private var edits: [NSRange] = []
    private var fenceCount = 0

    var isDirty: Bool { textView.string != savedBody }
    var isBlankNew: Bool { url == nil && textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(folder: URL) {
        self.folder = folder
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // TextKit 1 で組む（コードブロックの背景などを自前の LayoutManager で描くため）
        let contentSize = scrollView.contentSize
        let storage = NSTextStorage()
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = MarkdownTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.isRichText = false            // コピーもペーストも文字だけ
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = Theme.shared.baseAttributes
        textView.defaultParagraphStyle = Theme.shared.bodyParagraph
        scrollView.documentView = textView
        super.init()
        textView.delegate = self
        storage.delegate = self
        slashMenu = SlashMenu(textView: textView)
    }

    // MARK: - 開く・新しく作る

    func open(_ target: URL) {
        save()
        guard let data = try? Data(contentsOf: target), let parsed = NoteFile.parse(data) else {
            NSSound.beep()
            NSLog("読めませんでした（UTF-8 でないか、消えています）: \(target.path)")
            return
        }
        url = target
        file = parsed
        savedBody = parsed.body
        diskDate = Self.modificationDate(target)
        show(parsed.body, selection: NSRange(location: 0, length: 0))
    }

    func newNote() {
        save()
        url = nil
        file = NoteFile()
        savedBody = ""
        diskDate = nil
        show("", selection: NSRange(location: 0, length: 0))
    }

    /// 保存せずに手放す（ゴミ箱に入れたノートを開いていたとき）。
    func discard() {
        saveTimer?.invalidate()
        url = nil
        file = NoteFile()
        savedBody = ""
        diskDate = nil
        show("", selection: NSRange(location: 0, length: 0))
    }

    private func show(_ body: String, selection: NSRange) {
        slashMenu.close()
        textView.string = body
        edits = []
        let clamped = NSRange(location: min(selection.location, (body as NSString).length), length: 0)
        textView.setSelectedRange(clamped)
        restyle()
        textView.undoManager?.removeAllActions()
        textView.scrollRangeToVisible(clamped)
    }

    /// 見た目を付け直す。1か所を書き換えただけなら、その行だけ（長いノートでも軽いように）。
    private func restyle() {
        guard let storage = textView.textStorage else { return }
        (textView.layoutManager as? BlockLayoutManager)?.setSelection(textView.selectedRange())
        let fences = MarkdownStyler.fenceCount(in: storage.string)
        var lines: NSRange?
        if edits.count == 1, fences == fenceCount, NSMaxRange(edits[0]) <= storage.length {
            let range = (storage.string as NSString).paragraphRange(for: edits[0])
            if MarkdownStyler.canRestyleLocally(storage, lines: range) { lines = range }
        }
        MarkdownStyler.apply(to: storage, in: lines)
        edits = []
        fenceCount = fences
        textView.typingAttributes = Theme.shared.baseAttributes
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { edits.append(editedRange) }
    }

    // MARK: - 書く

    func textDidChange(_ notification: Notification) {
        // 日本語の変換中は触らない（属性を変えると変換が壊れる。確定した時点でもう一度呼ばれる）。
        guard !textView.hasMarkedText() else { return }
        restyle()
        slashMenu.textChanged()
        textView.needsDisplay = textView.string.isEmpty  // 空になったら、案内の文字を出す
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// カーソルが動いたら、その場所の記号だけを見せる。日本語の変換中は触らない。
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView.hasMarkedText() else { return }
        (textView.layoutManager as? BlockLayoutManager)?.reveal(for: textView.selectedRange())
        slashMenu.selectionChanged()
    }

    /// 「/」のメニューが出ている間の ↑↓・Enter・Esc と、箇条書きの字下げ（Tab、⇧Tab）。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if slashMenu.handle(selector) { return true }
        let outdent = selector == #selector(NSResponder.insertBacktab(_:))
        if selector == #selector(NSResponder.insertTab(_:)) || outdent,
           let edit = Formatting.indent(textView.string as NSString, selection: textView.selectedRange(), outdent: outdent) {
            self.textView.apply(edit)
            return true
        }
        return false
    }

    /// 変わっていれば書く。開いただけでは書かない。
    func save() {
        saveTimer?.invalidate()
        guard !textView.hasMarkedText() else { return }
        let body = textView.string
        guard body != savedBody else { return }

        var target: URL
        if let url {
            target = url
            // 開いた後にほかのアプリが書き換えていたら、上書きせず別のファイルに残す。
            // 本文まで違うときだけ競合とみなす（同期ツールが日時だけ変えることがあるため）。
            if let onDisk = Self.modificationDate(url), let diskDate, onDisk != diskDate {
                if let data = try? Data(contentsOf: url), let parsed = NoteFile.parse(data), parsed.body == savedBody {
                    file = parsed  // frontmatter などが外で変わっていれば、それを引き継ぐ
                    self.diskDate = onDisk
                } else {
                    target = Self.uniqueURL(in: url.deletingLastPathComponent(),
                                            stem: url.deletingPathExtension().lastPathComponent + " の競合コピー")
                    NSLog("外で変更されていたので、別のファイルに保存します: \(target.lastPathComponent)")
                }
            }
        } else {
            guard !isBlankNew else { return }  // 空のメモはファイルにしない
            target = Self.uniqueURL(in: folder, stem: Self.timestamp())
        }

        var updated = file
        updated.body = body
        do {
            try updated.serialized().write(to: target, options: .atomic)
        } catch {
            NSSound.beep()
            NSLog("保存できませんでした: \(error)")
            return
        }
        url = target.standardizedFileURL
        file = updated
        savedBody = body
        diskDate = Self.modificationDate(target)
        onSaved?(target.standardizedFileURL)
    }

    /// フォルダに変更があったとき。手元に未保存の変更がなければ、ディスクの内容に合わせる。
    func reloadIfChangedOnDisk() {
        guard let url, !isDirty, !textView.hasMarkedText() else { return }
        guard let onDisk = Self.modificationDate(url), onDisk != diskDate,
              let data = try? Data(contentsOf: url), let parsed = NoteFile.parse(data) else { return }
        file = parsed
        diskDate = onDisk
        guard parsed.body != savedBody else { return }
        savedBody = parsed.body
        show(parsed.body, selection: textView.selectedRange())
    }

    /// 本文全体を Markdown のままクリップボードへ。
    func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    /// 範囲を置き換える（Undo できる形で）。推敲の採用などに使う。
    func replace(_ range: NSRange, with text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    /// 文字を足す（Undo できる形で）。カーソルは、いま書いている場所から動かさない。議事録の挿入に使う。
    func insert(_ text: String, at location: Int) {
        let selection = textView.selectedRange()
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        // 挿入した場所より後ろを書いていたら、その分だけずらす
        let moved = selection.location > range.location ? selection.location + (text as NSString).length : selection.location
        textView.setSelectedRange(NSRange(location: moved, length: selection.length))
    }

    // MARK: - 補助

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func uniqueURL(in folder: URL, stem: String) -> URL {
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension("md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension("md")
            n += 1
        }
        return candidate
    }
}
