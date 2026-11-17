import AppKit
import XCTest

/// 同じノートの見出しへ飛ぶリンク。
final class AnchorTests: XCTestCase {
    private let note = "# 目次\n[志望動機](#志望動機)\n\n## A01 自己紹介\n本文\n```\n## 志望動機\n```\n## 志望動機のもう一つの言い方\n## 志望動機\n答え\n"

    private func line(at location: Int?) -> String? {
        guard let location else { return nil }
        let ns = note as NSString
        return ns.substring(with: ns.lineRange(for: NSRange(location: location, length: 0))).trimmingCharacters(in: .newlines)
    }

    func testFindsHeadingWithSameText() {
        let location = NoteAnchor.headingLocation(in: note, anchor: "志望動機")
        XCTAssertEqual(line(at: location), "## 志望動機")
        XCTAssertEqual(location, (note as NSString).range(of: "## 志望動機\n答え").location, "コードの囲みの中と、字が続く別の見出しには当たらない")
    }

    func testFindsHeadingByLeadingCode() {
        XCTAssertEqual(line(at: NoteAnchor.headingLocation(in: note, anchor: "A01")), "## A01 自己紹介")
    }

    func testMissingHeading() {
        XCTAssertNil(NoteAnchor.headingLocation(in: note, anchor: "逆質問"))
        XCTAssertNil(NoteAnchor.headingLocation(in: note, anchor: "本文"), "見出しでない行には当たらない")
    }

    @MainActor func testAnchorLinkIsMarkedAndWebLinkIsNot() {
        let storage = NSTextStorage(string: "[志望動機](#A05) と [外](https://example.com)")
        MarkdownStyler.apply(to: storage, theme: Theme.shared)
        XCTAssertEqual(storage.attribute(.moguAnchor, at: 1, effectiveRange: nil) as? String, "A05")
        XCTAssertNil(storage.attribute(.moguLink, at: 1, effectiveRange: nil))
        let web = (storage.string as NSString).range(of: "外").location
        XCTAssertNil(storage.attribute(.moguAnchor, at: web, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.moguLink, at: web, effectiveRange: nil))
    }

    /// 長いノートで、見出しにカーソルが移り、その行まで画面が送られる。
    @MainActor func testJumpMovesCaretAndScrolls() {
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let editor = EditorController(folder: tmp.appendingPathComponent("mogu-tests-\(UUID().uuidString)"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.textView.enclosingScrollView ?? editor.textView
        let body = "[下へ](#A02)\n" + String(repeating: "行\n", count: 400) + "## A02 見出し\n" + String(repeating: "行\n", count: 400)
        editor.textView.string = body
        MarkdownStyler.apply(to: editor.textView.textStorage!)
        window.layoutIfNeeded()
        let location = NoteAnchor.headingLocation(in: body, anchor: "A02")!
        editor.textView.jump(to: location)
        XCTAssertEqual(editor.textView.selectedRange().location, location)
        XCTAssertGreaterThan(editor.textView.visibleRect.minY, 1000, "見出しまで送られている")
    }
}
