import XCTest

final class MarkdownStylerTests: XCTestCase {
    private typealias S = MarkdownStyler.Style

    private func styles(_ text: String) -> [(String, S)] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).map { (ns.substring(with: $0.range), $0.style) }
    }

    private func has(_ text: String, _ piece: String, _ style: S, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(styles(text).contains { $0.0 == piece && $0.1 == style },
                      "\(piece) が \(style) になっていない: \(styles(text))", file: file, line: line)
    }

    func testHeading() {
        has("## 見出し", "## 見出し", .heading(2))
        has("## 見出し", "## ", .syntax)
        XCTAssertFalse(styles("#タグ").contains { if case .heading = $0.1 { true } else { false } })
        has("今日は #メモ を書く", "#メモ", .tag)
    }

    func testInline() {
        has("これは**太字**です", "**太字**", .bold)
        has("これは*斜体*です", "*斜体*", .italic)
        XCTAssertFalse(styles("snake_case_name").contains { $0.1 == .italic })
        has("~~消す~~", "~~消す~~", .strike)
        has("`a**b**c`", "`a**b**c`", .code)
        XCTAssertFalse(styles("`a**b**c`").contains { $0.1 == .bold }, "コードの中は太字にしない")
    }

    func testLinks() {
        has("[公式](https://example.com) を見る", "公式", .link("https://example.com"))
        has("https://example.com/a?b=1 を見る", "https://example.com/a?b=1", .link("https://example.com/a?b=1"))
    }

    func testListsAndTasks() {
        has("- 牛乳", "- 牛乳", .list(indent: 2))
        has("  1. 二段目", "  1. 二段目", .list(indent: 5))
        has("- [x] 電話した", "電話した", .done)
        has("- [x] 電話した", "- [x]", .checkbox(true))
        XCTAssertFalse(styles("- [ ] 電話する").contains { if case .bullet = $0.1 { true } else { false } }, "チェック項目に点は描かない")
        has("    - 孫", "-", .bullet(2))
        has("1. 一", "1.", .marker)
        XCTAssertFalse(styles("- [ ] 電話する").contains { $0.1 == .done })
    }

    func testCodeFence() {
        let text = "前\n```swift\nlet a = **b**\n```\n後"
        has(text, "```swift\nlet a = **b**\n```\n", .codeBlock)
        XCTAssertFalse(styles(text).contains { $0.1 == .bold }, "囲みの中は解釈しない")
    }

    func testQuoteAndRule() {
        has("> 引用", "> 引用", .quote)
        has("---", "---", .rule)
    }
}
