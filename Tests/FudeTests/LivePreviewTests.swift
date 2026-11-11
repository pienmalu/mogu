import AppKit
import XCTest

/// 記号を隠す表示・チェックボックス・日本語の変換中のふるまい。
@MainActor
final class LivePreviewTests: XCTestCase {
    private var folder: URL!
    private var window: NSWindow!
    private var editor: EditorController!

    override func setUp() async throws {
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        folder = tmp.appendingPathComponent("fude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        editor = EditorController(folder: folder)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.container
        editor.newNote()
        if let layout = editor.textView.layoutManager as? BlockLayoutManager { layout.hidesMarkup = true }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func type(_ text: String) {
        editor.textView.string = text
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
    }

    private func isHidden(_ index: Int) -> Bool {
        let layout = editor.textView.layoutManager!
        layout.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.propertyForGlyph(at: glyph) == .controlCharacter
    }

    func testMarkupHidesOutsideCaretLine() {
        type("## 見出し\n本文の**太字**")
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))  // 2行目
        editor.revealCurrentLines()
        XCTAssertTrue(isHidden(0), "カーソルのない行の # は隠れる")
        XCTAssertFalse(isHidden(9), "カーソルの行の ** は見える")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))  // 1行目へ
        editor.revealCurrentLines()
        XCTAssertFalse(isHidden(0), "カーソルが来たら # が見える")
        XCTAssertTrue(isHidden(11), "離れた行の ** は隠れる")
        XCTAssertEqual(editor.textView.string, "## 見出し\n本文の**太字**", "文字は変わらない")
    }

    func testSwitchShowsEverything() {
        type("## 見出し\n本文")
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.revealCurrentLines()
        (editor.textView.layoutManager as! BlockLayoutManager).hidesMarkup = false
        (editor.textView.layoutManager as! BlockLayoutManager).refreshAll()
        XCTAssertFalse(isHidden(0))
    }

    func testCheckboxToggleIsUndoable() {
        type("- [ ] 電話する")
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.textView.toggleCheckbox(nil)
        XCTAssertEqual(editor.textView.string, "- [x] 電話する")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "- [ ] 電話する")
    }

    func testComposingIsNotDisturbed() {
        type("## 見出し\n")
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let marked = view.markedRange()
        let underline = view.textStorage!.attribute(.underlineStyle, at: marked.location, effectiveRange: nil)
        // 変換中に選択の通知や文字の変更の通知が来ても、装飾も保存もしない
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        editor.save()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.textStorage!.attribute(.underlineStyle, at: marked.location, effectiveRange: nil) as? Int,
                       underline as? Int, "変換中の下線が消えない")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "変換中は保存しない")
        view.insertText("日本", replacementRange: marked)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "## 見出し\n日本")
    }
}
