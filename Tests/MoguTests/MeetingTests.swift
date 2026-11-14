import XCTest

final class MeetingTests: XCTestCase {
    // MARK: - speech.cpp の出力

    func testParsesSpeechEvents() {
        XCTAssertEqual(Transcriber.parse(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":9972,"item_id":"a"}"#),
                       .started(id: "a", ms: 9972))
        XCTAssertEqual(Transcriber.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"それでは"}"#),
                       .delta(id: "a", text: "それでは"))
        XCTAssertEqual(Transcriber.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"それでは始めます。"}"#),
                       .completed(id: "a", text: "それでは始めます。"))
        XCTAssertNil(Transcriber.parse(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#))
        XCTAssertNil(Transcriber.parse("reading 16-bit PCM"))
    }

    // MARK: - 文字起こしの形

    func testClock() {
        XCTAssertEqual(MeetingTranscript.clock(0), "00:00")
        XCTAssertEqual(MeetingTranscript.clock(307.9), "05:07")
        XCTAssertEqual(MeetingTranscript.clock(3907), "1:05:07")
    }

    func testInPersonMeetingHasNoSpeakerLabels() {
        let items = [Utterance(start: 0, speaker: .me, text: "始めます。"), Utterance(start: 4, speaker: .me, text: "議題は2つです。")]
        XCTAssertEqual(MeetingTranscript.markdown(items), "`00:00` 始めます。議題は2つです。")
    }

    func testOnlineMeetingLabelsSpeakersAndSortsByTime() {
        let items = [Utterance(start: 12, speaker: .me, text: "はい。"),
                     Utterance(start: 3, speaker: .other, text: "聞こえますか。"),
                     Utterance(start: 70, speaker: .other, text: "では次へ。")]
        XCTAssertEqual(MeetingTranscript.markdown(items),
                       "`00:03` **相手** 聞こえますか。\n\n`00:12` **自分** はい。\n\n`01:10` **相手** では次へ。")
        XCTAssertEqual(MeetingTranscript.plain(items), "[00:03] 相手: 聞こえますか。\n[00:12] 自分: はい。\n[01:10] 相手: では次へ。")
    }

    func testLongSpeechIsSplitIntoParagraphs() {
        let items = (0..<6).map { Utterance(start: Double($0) * 10, speaker: .me, text: String(repeating: "あ", count: 50)) }
        let paragraphs = MeetingTranscript.paragraphs(items, limit: 160)
        XCTAssertEqual(paragraphs.map(\.start), [0, 40])
        XCTAssertEqual(paragraphs.map(\.text.count), [200, 100])
    }

    func testChunksSplitAtLineBreaks() {
        let text = ["一行目です", "二行目です", "三行目です"].joined(separator: "\n")
        XCTAssertEqual(MeetingTranscript.chunks(text, limit: 11), ["一行目です\n二行目です", "三行目です"])
        XCTAssertEqual(MeetingTranscript.chunks(text, limit: 1000), [text])
        XCTAssertEqual(MeetingTranscript.chunks("", limit: 10), [])
    }

    // MARK: - ノートへの入れ方

    func testTranscriptSectionKeepsOneBlankLineAfterNotes() {
        let items = [Utterance(start: 0, speaker: .me, text: "はい。")]
        XCTAssertEqual(MeetingTranscript.section(items, after: "# 会議\n\nメモ"), "\n\n## 文字起こし\n\n`00:00` はい。\n")
        XCTAssertEqual(MeetingTranscript.section(items, after: "# 会議\n\n"), "## 文字起こし\n\n`00:00` はい。\n")
    }

    func testSummaryGoesBeforeTranscript() {
        let body = "# 会議\n\nメモ\n\n## 文字起こし\n\n`00:00` はい。\n"
        let (location, text) = MeetingTranscript.summaryInsertion("## 要約\n- 決めた\n", into: body)
        let result = (body as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: text)
        XCTAssertEqual(result, "# 会議\n\nメモ\n\n## 要約\n- 決めた\n\n## 文字起こし\n\n`00:00` はい。\n")
    }

    func testSummaryGoesToEndWhenTranscriptHeadingWasRemoved() {
        let (location, text) = MeetingTranscript.summaryInsertion("## 要約\n- 決めた", into: "# 会議\n\nメモ")
        XCTAssertEqual(location, ("# 会議\n\nメモ" as NSString).length)
        XCTAssertEqual(text, "\n\n## 要約\n- 決めた\n")
    }

    // MARK: - 要約の頼み方

    func testCleanDropsFencesAndPreamble() {
        let output = "はい、まとめます。\n```markdown\n## 要約\n- 決めた\n\n## TODO\n- [ ] やる\n```"
        XCTAssertEqual(MeetingPrompt.clean(output), "## 要約\n- 決めた\n\n## TODO\n- [ ] やる")
    }

    func testMemoIsNotesWithoutTitleAndTranscript() {
        let body = "# 会議 2026-11-14 15:00\n\n田中さんが担当\n\n## 文字起こし\n\n`00:00` はい。\n"
        XCTAssertEqual(MeetingPrompt.memo(from: body).trimmingCharacters(in: .whitespacesAndNewlines), "田中さんが担当")
    }

    // MARK: - 落ちたときの控え

    func testJournalKeepsUtterancesUntilFinished() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mogu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = MeetingJournal(url: folder.appendingPathComponent("journal.jsonl"))
        XCTAssertNil(journal.leftover())

        let started = Date(timeIntervalSince1970: 1_800_000_000)
        journal.begin(started: started)
        journal.append(Utterance(start: 1, speaker: .me, text: "一つ目"))
        journal.append(Utterance(start: 9, speaker: .other, text: "二つ目"))
        let left = try XCTUnwrap(journal.leftover())
        XCTAssertEqual(left.started, started)
        XCTAssertEqual(left.utterances.map(\.text), ["一つ目", "二つ目"])

        journal.finish()
        XCTAssertNil(journal.leftover())
    }
}
