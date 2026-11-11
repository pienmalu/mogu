import AppKit

/// 本文を書く欄。文字はプレーンテキストのまま持ち、見た目だけ MarkdownStyler で付ける。
final class MarkdownTextView: NSTextView {
    /// 本文の上の余白（窓の上端の信号ボタンと重ならないように）。
    var topInset: CGFloat = 52

    /// 空のときに出す書き出しの案内。
    static let placeholder = "書きはじめる"
    static let hint = "範囲を選んで ⌘J で推敲。⌘P でほかのメモを探す。"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let container = textContainer else { return }
        let theme = Theme.shared
        let x = textContainerOrigin.x + container.lineFragmentPadding
        let font = theme.bodyFont
        let top = textContainerOrigin.y + ((theme.lineHeight - (font.ascender - font.descender)) / 2).rounded()
        (Self.placeholder as NSString).draw(at: NSPoint(x: x, y: top),
                                            withAttributes: [.font: font, .foregroundColor: theme.inkFaint])
        let small = NSFont.systemFont(ofSize: 12)
        (Self.hint as NSString).draw(at: NSPoint(x: x, y: top + theme.lineHeight + 6),
                                     withAttributes: [.font: small, .foregroundColor: theme.inkSecondary])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true  // 案内を出す・消す
    }

    /// カーソルは行の高さではなく、文字の高さで描く（朱の細い線）。
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let font = typingAttributes[.font] as? NSFont ?? Theme.shared.bodyFont
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let line = min(rect.height, (paragraph?.maximumLineHeight ?? 0) > 0 ? paragraph!.maximumLineHeight : Theme.shared.lineHeight)
        let height = min(line, ceil(font.ascender - font.descender) + 2)
        var caret = rect
        // 段落の前の空きは行の上に付くので、下から数えて行の真ん中に置く
        caret.origin.y = rect.maxY - line + ((line - height) / 2).rounded()
        caret.size.height = height
        caret.size.width = 2
        super.drawInsertionPoint(in: caret, color: Theme.shared.shu, turnedOn: flag)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, (newSize.width - Theme.shared.columnWidth) / 2)
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: topInset)
        }
    }

    /// ⌘クリックでリンクを開く。ふつうのクリックはカーソルを置くだけ。
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func link(at event: NSEvent) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let url = storage.attribute(.fudeLink, at: candidate, effectiveRange: nil) as? URL { return url }
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
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

/// 開いているノート1つを受け持つ。読む・書く・外の変更を取り込む。
@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    /// 本文と、右上の字数をまとめた入れ物（窓にはこれを置く）。
    let container = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

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

    var isDirty: Bool { textView.string != savedBody }
    var isBlankNew: Bool { url == nil && textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(folder: URL) {
        self.folder = folder
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.shared.paper

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
        textView.backgroundColor = Theme.shared.paper
        textView.insertionPointColor = Theme.shared.shu
        textView.selectedTextAttributes = [.backgroundColor: Theme.shared.selection]
        textView.typingAttributes = Theme.shared.baseAttributes
        textView.defaultParagraphStyle = Theme.shared.bodyParagraph
        scrollView.documentView = textView
        super.init()
        textView.delegate = self

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Theme.shared.inkSecondary
        statusLabel.alignment = .right
        for view in [scrollView, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: self.container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: self.container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: self.container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.container.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: self.container.topAnchor, constant: 15),
            statusLabel.trailingAnchor.constraint(equalTo: self.container.trailingAnchor, constant: -18),
        ])
    }

    // MARK: - 字数

    /// 字数（空白と改行は数えない）。
    nonisolated static func count(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }

    private static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// 右上の表示。選んでいるときは「選んだ字数 / 全体」。
    func updateStatus() {
        let total = Self.count(textView.string)
        guard total > 0 else {
            statusLabel.stringValue = ""
            return
        }
        let all = Self.number.string(from: NSNumber(value: total)) ?? "\(total)"
        let range = textView.selectedRange()
        if range.length > 0 {
            let part = Self.count((textView.string as NSString).substring(with: range))
            statusLabel.stringValue = "\(Self.number.string(from: NSNumber(value: part)) ?? "\(part)") / \(all)字"
        } else {
            statusLabel.stringValue = "\(all)字"
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateStatus()
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
        textView.string = body
        restyle()
        let clamped = NSRange(location: min(selection.location, (body as NSString).length), length: 0)
        textView.setSelectedRange(clamped)
        textView.undoManager?.removeAllActions()
        textView.scrollRangeToVisible(clamped)
        updateStatus()
    }

    private func restyle() {
        guard let storage = textView.textStorage else { return }
        MarkdownStyler.apply(to: storage)
        textView.typingAttributes = Theme.shared.baseAttributes
    }

    // MARK: - 書く

    func textDidChange(_ notification: Notification) {
        // 日本語の変換中は触らない（属性を変えると変換が壊れる。確定した時点でもう一度呼ばれる）。
        guard !textView.hasMarkedText() else { return }
        restyle()
        updateStatus()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
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
