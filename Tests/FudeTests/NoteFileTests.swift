import XCTest

final class NoteFileTests: XCTestCase {
    private func roundTrip(_ text: String, bom: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        var data = Data(bom ? [0xEF, 0xBB, 0xBF] : [])
        data.append(Data(text.utf8))
        guard let parsed = NoteFile.parse(data) else { return XCTFail("読めない", file: file, line: line) }
        XCTAssertEqual(parsed.serialized(), data, file: file, line: line)
    }

    func testRoundTripKeepsBytes() {
        roundTrip("")
        roundTrip("本文だけ")
        roundTrip("末尾改行あり\n")
        roundTrip("---\ndate: 2026-01-01\ntags: [a, b]\n---\n本文\n")
        roundTrip("---\r\ntitle: x\r\n---\r\n一行目\r\n二行目\r\n")  // CRLF
        roundTrip("混在\r\nしている\n改行\n")                     // 混在は触らない
        roundTrip("BOM つき\n", bom: true)
        roundTrip("---\n閉じていない frontmatter\n")
    }

    func testFrontmatterIsSeparated() throws {
        let file = try XCTUnwrap(NoteFile.parse(Data("---\ntitle: 会議\n---\n# 本文\n".utf8)))
        XCTAssertEqual(file.frontmatter, "---\ntitle: 会議\n---\n")
        XCTAssertEqual(file.body, "# 本文\n")
    }

    func testCRLFIsEditedAsLF() throws {
        let file = try XCTUnwrap(NoteFile.parse(Data("a\r\nb\r\n".utf8)))
        XCTAssertTrue(file.usesCRLF)
        XCTAssertEqual(file.body, "a\nb\n")
        var edited = file
        edited.body = "a\nb\nc\n"
        XCTAssertEqual(String(data: edited.serialized(), encoding: .utf8), "a\r\nb\r\nc\r\n")
    }

    func testNonUTF8IsRefused() {
        XCTAssertNil(NoteFile.parse(Data([0x82, 0xA0, 0xFF, 0xFE])))  // Shift_JIS などは読まない
    }

    func testTitle() {
        XCTAssertEqual(NoteFile.title(body: "\n\n# 買い物\n- 牛乳", fileName: "20261111-101010.md"), "買い物")
        XCTAssertEqual(NoteFile.title(body: "", fileName: "20261111-101010.md"), "無題")
        XCTAssertEqual(NoteFile.title(body: "# 本文の見出し", fileName: "会議メモ.md"), "会議メモ")
        XCTAssertEqual(NoteFile.title(body: "- [ ] 電話する", fileName: "2026-11-11-01-02-03.md"), "電話する")
        XCTAssertEqual(NoteFile.snippet(body: "# 買い物\n- 牛乳\n- 卵", fileName: "20261111-101010.md"), "牛乳 卵")
    }
}

final class SnippetTests: XCTestCase {
    func testSnippetDropsMarkup() {
        XCTAssertEqual(NoteFile.snippet(body: "# 題\n今週は**論文**と[資料](https://x.y)と`code`", fileName: "20261111-101010.md"),
                       "今週は論文と資料とcode")
    }
}
