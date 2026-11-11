import XCTest

final class RewritePromptTests: XCTestCase {
    func testCleanKeepsSurroundingWhitespace() {
        XCTAssertEqual(RewritePrompt.clean("直した文。\n", original: "\n下書き\n\n"), "\n直した文。\n\n")
        XCTAssertEqual(RewritePrompt.clean("  直した文。", original: "下書き"), "直した文。")
    }

    func testCleanUnwrapsCodeFence() {
        XCTAssertEqual(RewritePrompt.clean("```markdown\n- 直した\n```", original: "- 下書き"), "- 直した")
        XCTAssertEqual(RewritePrompt.clean("```\ncode\n```", original: "```\ncode\n```"), "```\ncode\n```", "元がコードなら外さない")
    }

    func testRequestDisablesThinking() {
        let body = RewritePrompt.requestBody(for: "下書き")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual(((body["messages"] as? [[String: String]])?.last)?["content"], "下書き")
    }
}
