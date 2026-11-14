import XCTest

final class FormattingTests: XCTestCase {
    /// 「|」でカーソル、「[」「]」… ではなく、範囲を数で渡して、書き換えた後の文字と選んだ文字を返す。
    private func run(_ text: String, _ selection: NSRange, _ edit: (NSString, NSRange) -> Formatting.Edit?) -> (String, String)? {
        guard let edit = edit(text as NSString, selection) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        return (result, (result as NSString).substring(with: edit.selection))
    }

    private func range(_ text: String, of piece: String) -> NSRange { (text as NSString).range(of: piece) }

    func testBoldWrapsAndUnwraps() {
        let wrapped = run("これは太字です", range("これは太字です", of: "太字")) { Formatting.toggleWrap($0, selection: $1, marker: "**") }
        XCTAssertEqual(wrapped?.0, "これは**太字**です")
        XCTAssertEqual(wrapped?.1, "太字")
        let unwrapped = run("これは**太字**です", range("これは**太字**です", of: "太字")) { Formatting.toggleWrap($0, selection: $1, marker: "**") }
        XCTAssertEqual(unwrapped?.0, "これは太字です")
        XCTAssertEqual(unwrapped?.1, "太字")
        let withMarkers = run("これは**太字**です", range("これは**太字**です", of: "**太字**")) { Formatting.toggleWrap($0, selection: $1, marker: "**") }
        XCTAssertEqual(withMarkers?.0, "これは太字です")
    }

    func testItalicOnBoldAddsOneMore() {
        let text = "**太字**"
        let both = run(text, range(text, of: "太字")) { Formatting.toggleWrap($0, selection: $1, marker: "*") }
        XCTAssertEqual(both?.0, "***太字***")
        let back = run("***太字***", range("***太字***", of: "太字")) { Formatting.toggleWrap($0, selection: $1, marker: "*") }
        XCTAssertEqual(back?.0, "**太字**")
    }

    func testWrapWithNoSelectionPutsCaretBetweenMarkers() {
        let edit = Formatting.toggleWrap("ab", selection: NSRange(location: 1, length: 0), marker: "`")
        XCTAssertEqual(edit.text, "``")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    func testLink() {
        let text = "公式を見る"
        let pasted = run(text, range(text, of: "公式")) { Formatting.link($0, selection: $1, url: "https://example.com") }
        XCTAssertEqual(pasted?.0, "[公式](https://example.com)を見る")
        let empty = Formatting.link(text as NSString, selection: range(text, of: "公式"))
        XCTAssertEqual(empty.text, "[公式]()")
        XCTAssertEqual(empty.selection, NSRange(location: 5, length: 0), "( ) の中にカーソル")
        XCTAssertTrue(Formatting.isURL(" https://example.com/a?b=1\n"))
        XCTAssertFalse(Formatting.isURL("https://example.com と書いた"))
        XCTAssertFalse(Formatting.isURL("example.com"))
    }

    func testSetBlockReplacesExistingMarker() {
        XCTAssertEqual(run("買い物", NSRange(location: 3, length: 0)) { Formatting.setBlock($0, selection: $1, prefix: "## ") }?.0, "## 買い物")
        XCTAssertEqual(run("# 買い物", NSRange(location: 5, length: 0)) { Formatting.setBlock($0, selection: $1, prefix: "- [ ] ") }?.0, "- [ ] 買い物")
        XCTAssertEqual(run("  - [x] 買い物\n次", NSRange(location: 8, length: 0)) { Formatting.setBlock($0, selection: $1, prefix: "") }?.0, "  買い物\n次")
        let caret = Formatting.setBlock("買い物", selection: NSRange(location: 1, length: 0), prefix: "> ")
        XCTAssertEqual(caret.selection, NSRange(location: 3, length: 0), "カーソルは同じ文字の所に残る")
    }

    func testToggleTask() {
        XCTAssertEqual(run("- [ ] 牛乳", NSRange(location: 7, length: 0)) { Formatting.toggleTask($0, selection: $1) }?.0, "- [x] 牛乳")
        XCTAssertEqual(run("- [x] 牛乳", NSRange(location: 7, length: 0)) { Formatting.toggleTask($0, selection: $1) }?.0, "- [ ] 牛乳")
        XCTAssertEqual(run("- 牛乳", NSRange(location: 3, length: 0)) { Formatting.toggleTask($0, selection: $1) }?.0, "- [ ] 牛乳")
        XCTAssertEqual(run("牛乳\n卵\n", NSRange(location: 0, length: 4)) { Formatting.toggleTask($0, selection: $1) }?.0, "- [ ] 牛乳\n- [ ] 卵\n")
    }

    func testIndentNestsUnderTheLineAbove() {
        let bullets = run("- 親\n- 子", NSRange(location: 6, length: 0)) { Formatting.indent($0, selection: $1, outdent: false) }
        XCTAssertEqual(bullets?.0, "- 親\n  - 子")
        let numbered = run("1. 親\n- 子", NSRange(location: 7, length: 0)) { Formatting.indent($0, selection: $1, outdent: false) }
        XCTAssertEqual(numbered?.0, "1. 親\n   - 子", "番号の下は 3 文字下げる")
        let back = run("1. 親\n   - 子", NSRange(location: 10, length: 0)) { Formatting.indent($0, selection: $1, outdent: true) }
        XCTAssertEqual(back?.0, "1. 親\n- 子")
        XCTAssertNil(Formatting.indent("ふつうの行", selection: NSRange(location: 2, length: 0), outdent: false), "箇条書きでなければ、ふつうの Tab")
    }

    func testMoveLines() {
        XCTAssertEqual(run("一\n二\n三", NSRange(location: 2, length: 0)) { Formatting.moveLines($0, selection: $1, up: true) }?.0, "二\n一\n三")
        XCTAssertEqual(run("一\n二\n三", NSRange(location: 2, length: 0)) { Formatting.moveLines($0, selection: $1, up: false) }?.0, "一\n三\n二")
        XCTAssertEqual(run("一\n二\n三", NSRange(location: 4, length: 0)) { Formatting.moveLines($0, selection: $1, up: true) }?.0, "一\n三\n二")
        XCTAssertNil(Formatting.moveLines("一\n二", selection: NSRange(location: 0, length: 0), up: true))
        XCTAssertNil(Formatting.moveLines("一\n二", selection: NSRange(location: 2, length: 0), up: false))
        let moved = run("一\n二二\n三", NSRange(location: 3, length: 1)) { Formatting.moveLines($0, selection: $1, up: false) }
        XCTAssertEqual(moved?.1, "二", "選んでいた文字は、動いた先でも選ばれている")
    }

    func testTaskShortcut() {
        let edit = Formatting.taskShortcut("[]", caret: 2)
        XCTAssertEqual(edit?.text, "- [ ] ")
        XCTAssertNil(Formatting.taskShortcut("文の中の[]", caret: 6))
    }
}
