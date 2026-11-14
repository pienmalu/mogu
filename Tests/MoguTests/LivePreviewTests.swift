import AppKit
import XCTest

/// 記号を隠す見た目（ライブプレビュー）。文字は1つも変えず、カーソルのある所だけ記号を見せる。
@MainActor
final class LivePreviewTests: XCTestCase {
    private func makeEditor(_ text: String, caret: Int) -> (EditorController, BlockLayoutManager, NSWindow) {
        let editor = EditorController(folder: URL(fileURLWithPath: NSTemporaryDirectory()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.newNote()
        editor.textView.string = text
        editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        let layout = editor.textView.layoutManager as! BlockLayoutManager
        layout.ensureLayout(for: editor.textView.textContainer!)
        return (editor, layout, window)
    }

    /// index の字が、幅を持って見えているか。
    private func isVisible(_ layout: BlockLayoutManager, _ index: Int) -> Bool {
        let property = layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: index))
        return !property.contains(.null) && !property.contains(.controlCharacter)
    }

    func testMarkersAreHiddenAwayFromCaretButTextIsUntouched() {
        let text = "# 見出し\nこれは**太字**です\n終わり"
        let (editor, layout, _) = makeEditor(text, caret: (text as NSString).length)
        XCTAssertFalse(isVisible(layout, 0), "見出しの # は隠れる")
        XCTAssertTrue(isVisible(layout, 2), "見出しの文字は見える")
        let bold = (text as NSString).range(of: "**太字**")
        XCTAssertFalse(isVisible(layout, bold.location))
        XCTAssertFalse(isVisible(layout, NSMaxRange(bold) - 1))
        XCTAssertEqual(editor.textView.string, text, "文字は変わらない（コピーすれば Markdown のまま）")
    }

    func testCaretRevealsOnlyTheElementItTouches() {
        let text = "# 見出し\nこれは**太字**と`code`です"
        let bold = (text as NSString).range(of: "**太字**")
        let code = (text as NSString).range(of: "`code`")
        let (editor, layout, _) = makeEditor(text, caret: (text as NSString).length)

        editor.textView.setSelectedRange(NSRange(location: bold.location + 3, length: 0))
        layout.ensureLayout(for: editor.textView.textContainer!)
        XCTAssertTrue(isVisible(layout, bold.location), "太字の中にカーソルがあれば ** が見える")
        XCTAssertFalse(isVisible(layout, code.location), "同じ行でも、離れた ` は隠れたまま")
        XCTAssertFalse(isVisible(layout, 0), "別の行の # も隠れたまま")

        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        layout.ensureLayout(for: editor.textView.textContainer!)
        XCTAssertTrue(isVisible(layout, 0), "見出しの行にカーソルがあれば # が見える")
        XCTAssertFalse(isVisible(layout, bold.location), "カーソルが離れたら、また隠れる")
    }

    func testCheckboxTogglesByClickAndKeepsCaret() {
        let text = "メモ\n- [ ] 牛乳\n- [x] 卵"
        let (editor, layout, _) = makeEditor(text, caret: 1)
        let box = (text as NSString).range(of: "[ ]")
        let rect = try! XCTUnwrap(layout.checkboxRect(at: box.location))
        let origin = editor.textView.textContainerOrigin
        let point = NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
        XCTAssertEqual(editor.textView.checkbox(at: point), box)

        editor.textView.toggleCheckbox(box)
        XCTAssertEqual(editor.textView.string, "メモ\n- [x] 牛乳\n- [x] 卵")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 0), "カーソルは動かない")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, text, "⌘Z で戻せる")
    }

    func testCheckboxLineStartsAtTheLeftEdge() {
        // 隠した「- 」が前の行に付くと、行頭の字下げが狂う（チェックボックスが右にずれる）
        let text = "前の行\n- [ ] 牛乳"
        let (_, layout, _) = makeEditor(text, caret: 0)
        let box = (text as NSString).range(of: "[ ]")
        let rect = try! XCTUnwrap(layout.checkboxRect(at: box.location))
        XCTAssertEqual(rect.minX, layout.textContainers[0].lineFragmentPadding, accuracy: 0.5)
    }

    func testTypingRestylesOnlyThatLineButResultMatchesFullRestyle() {
        let text = "# 見出し\n本文\n- [ ] 牛乳\n```\ncode\n```\n後"
        let (editor, _, _) = makeEditor(text, caret: 9)
        editor.textView.insertText("**太字**", replacementRange: NSRange(location: 9, length: 0))
        let incremental = NSAttributedString(attributedString: editor.textView.textStorage!)
        let full = NSTextStorage(string: editor.textView.string)
        MarkdownStyler.apply(to: full)
        // 隠す記号のまとまり（MarkerScope）は作るたびに別物なので、字の形と色で比べる
        for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle, .moguBlock, .moguCheckbox] {
            for index in 0..<full.length {
                let a = incremental.attribute(key, at: index, effectiveRange: nil) as? NSObject
                let b = full.attribute(key, at: index, effectiveRange: nil) as? NSObject
                XCTAssertEqual(a, b, "\(key.rawValue) が \(index) 文字目で違う")
            }
        }
    }

    /// 書き換えたあとの見た目が、全体を付け直したものと同じか。
    private func assertMatchesFullRestyle(_ editor: EditorController, file: StaticString = #filePath, line: UInt = #line) {
        let incremental = NSAttributedString(attributedString: editor.textView.textStorage!)
        let full = NSTextStorage(string: editor.textView.string)
        MarkdownStyler.apply(to: full)
        for index in 0..<full.length {
            for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle, .moguBlock, .moguCheckbox] {
                XCTAssertEqual(incremental.attribute(key, at: index, effectiveRange: nil) as? NSObject,
                               full.attribute(key, at: index, effectiveRange: nil) as? NSObject,
                               "\(key.rawValue) が \(index) 文字目で違う", file: file, line: line)
            }
            XCTAssertEqual(incremental.attribute(.moguScope, at: index, effectiveRange: nil) != nil,
                           full.attribute(.moguScope, at: index, effectiveRange: nil) != nil,
                           "隠す記号かどうかが \(index) 文字目で違う", file: file, line: line)
        }
    }

    func testSplittingALineRestylesBothHalves() {
        let (heading, _, _) = makeEditor("# 見出し続き\n後", caret: 5)
        heading.textView.insertText("\n", replacementRange: NSRange(location: 5, length: 0))
        assertMatchesFullRestyle(heading)

        let text = "これは**太字**です\n後"
        let (bold, _, _) = makeEditor(text, caret: 6)
        bold.textView.insertText("\n", replacementRange: NSRange(location: 6, length: 0))
        assertMatchesFullRestyle(bold)

        let (pasted, _, _) = makeEditor("- [ ] 牛乳と卵\n後", caret: 8)
        pasted.textView.insertText("X\n", replacementRange: NSRange(location: 8, length: 0))
        assertMatchesFullRestyle(pasted)

        let (joined, _, _) = makeEditor("# 見出し\n**太字**\n後", caret: 6)
        joined.textView.insertText("", replacementRange: NSRange(location: 5, length: 1))
        assertMatchesFullRestyle(joined)
    }

    func testSlashCommandsFilter() {
        XCTAssertEqual(SlashCommand.matching("").count, SlashCommand.all.count)
        XCTAssertEqual(SlashCommand.matching("mi").map(\.title), ["見出し 1", "見出し 2", "見出し 3"])
        XCTAssertEqual(SlashCommand.matching("todo").first?.title, "ToDo")
        XCTAssertEqual(SlashCommand.matching("議事").map(\.title), ["議事録を始める"])
        XCTAssertTrue(SlashCommand.matching("zzz").isEmpty)
    }

    func testSlashMenuTurnsLineIntoHeading() {
        let (editor, _, window) = makeEditor("買い物\n", caret: 4)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        editor.textView.insertText("/", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue(editor.slashMenu.isOpen)
        editor.textView.insertText("h2", replacementRange: editor.textView.selectedRange())
        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(editor.textView.string, "買い物\n## ")
        XCTAssertFalse(editor.slashMenu.isOpen)
    }

    func testSlashDoesNotOpenInsideWordsOrDates() {
        let (editor, _, _) = makeEditor("11", caret: 2)
        editor.textView.insertText("/", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(editor.slashMenu.isOpen)
    }

    // MARK: - 探す・並べる

    private func note(_ title: String, _ body: String, daysAgo: Int, now: Date) -> NoteSummary {
        NoteSummary(url: URL(fileURLWithPath: "/tmp/\(title).md"), title: title, snippet: body,
                    modified: now.addingTimeInterval(-Double(daysAgo) * 86400), searchText: (title + "\n" + body).lowercased())
    }

    func testQuickOpenPutsTitleMatchesFirstAndOffersNewNote() {
        let now = Date()
        let notes = [note("買い物", "論文を印刷する", daysAgo: 0, now: now), note("論文メモ", "第3章", daysAgo: 3, now: now),
                     note("旅行", "持ち物", daysAgo: 5, now: now)]
        let rows = QuickOpenModel.search(notes, query: "論文")
        XCTAssertEqual(rows.map(\.title), ["論文メモ", "買い物", "「論文」で新しいメモを作る"])
        XCTAssertEqual(rows[1].detail, "論文を印刷する", "本文で当たったときは、その行を見せる")
        XCTAssertEqual(QuickOpenModel.search(notes, query: "").map(\.title), ["買い物", "論文メモ", "旅行"])
    }

    func testSidebarGroupsByDate() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
        let notes = [0, 1, 3, 20, 70].map { note("n\($0)", "", daysAgo: $0, now: now) }
        XCTAssertEqual(NoteDate.sections(notes, now: now).map(\.title), ["今日", "昨日", "過去 7 日間", "過去 30 日間", "9月"])
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 1))!
        XCTAssertEqual(NoteDate.group(lastYear, now: now), "2025年12月")
    }
}
