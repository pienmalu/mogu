import AppKit
import XCTest

/// 行送りがそろっていること（書体が混ざる行・折り返し・コード入りの行でも、本文の行は同じ高さ）。
@MainActor
final class LineHeightTests: XCTestCase {
    func testBodyLinesShareOneHeight() {
        let editor = EditorController(folder: URL(fileURLWithPath: NSTemporaryDirectory()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.newNote()
        let lines = [
            "ふつうの行",
            "とても長い行。" + String(repeating: "折り返して二行目以降になるまで書き続ける。", count: 4),
            "`code` の入った行",
            "**太字**の入った行",
            "English と日本語が混ざった行 with words",
            "- 箇条書きの行",
        ]
        editor.textView.string = lines.joined(separator: "\n")
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        let layout = editor.textView.layoutManager!
        layout.ensureLayout(for: editor.textView.textContainer!)
        var heights: [CGFloat] = []
        var fragments = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, used, _, _, _ in
            heights.append(used.height)
            fragments += 1
        }
        XCTAssertGreaterThan(fragments, lines.count, "長い行が折り返している")
        XCTAssertEqual(Set(heights), [Theme.shared.lineHeight], "本文の行の高さがそろっていない: \(heights)")
    }
}
