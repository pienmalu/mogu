import XCTest

final class ListContinuationTests: XCTestCase {
    func testContinues() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- 牛乳"), .insert("- "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "  * 二段目"), .insert("  * "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "9. 九"), .insert("10. "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- [x] 済んだ"), .insert("- [ ] "))
    }

    func testEndsOnEmptyItem() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- "), .endList)
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- [ ] "), .endList)
    }

    func testIgnoresPlainLines() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "ふつうの文"), .none)
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "-ハイフンだけ"), .none)
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "2026年"), .none)
    }
}
