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

    /// 録っている間の様子を、1行にする。音が届いていない、speech.cpp が読んでいない、文字が返らない、を見分けられる。
    func testDescribesAudioHealth() {
        let fine = MeetingAudio.Health(seconds: 30, peak: 0.62, transcriber: Transcriber.Stats(pendingBytes: 0, droppedBytes: 0, events: 12))
        let me = MeetingAudio.Health(seconds: 30, peak: 0.41, transcriber: Transcriber.Stats(events: 3))
        XCTAssertEqual(MeetingAudio.describe(other: fine, me: me),
                       "相手: 音 30.0 秒・最大 0.62・待ち 0.0 秒・返り 12 行 ／ 自分: 音 30.0 秒・最大 0.41・待ち 0.0 秒・返り 3 行")
        // speech.cpp が音を読んでいない（待ちが増える）、終わっている（捨てた）
        let stuck = MeetingAudio.Health(seconds: 30, peak: 0.5, transcriber: Transcriber.Stats(pendingBytes: 32000 * 45, droppedBytes: 32000 * 3, events: 0))
        XCTAssertTrue(MeetingAudio.describe(other: stuck, me: me).hasPrefix("相手: 音 30.0 秒・最大 0.50・待ち 45.0 秒・捨てた 3.0 秒・返り 0 行 ／"))
        // まだ相手の声が聞こえていない、Mac の音を取れていない
        let quiet = MeetingAudio.Health(seconds: 30, peak: 0.05, transcriber: nil)
        XCTAssertTrue(MeetingAudio.describe(other: quiet, me: me).hasPrefix("相手: 音 30.0 秒・最大 0.05・文字起こしは始めていない ／"))
        XCTAssertTrue(MeetingAudio.describe(other: nil, me: me).hasPrefix("相手: Mac の音を取っていない ／ 自分: "))
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
        XCTAssertEqual(paragraphs.map(\.text.count), [203, 101])  // 間に「、」が入る
    }

    /// 文字起こしは句読点を付けないことが多い。つなぐときに、切れ目が分かるように区切りを入れる。
    func testUnpunctuatedUtterancesAreJoinedWithSeparators() {
        let items = ["ありがとうございます。", "職歴にも触れていただいたかと思うんですけれども", "詳しくお伺いしていきたいとおもいます",
                     "ご説明いただいてもよろしいでしょうか"].enumerated().map { Utterance(start: Double($0.offset), speaker: .other, text: $0.element) }
        XCTAssertEqual(MeetingTranscript.paragraphs(items).map(\.text),
                       ["ありがとうございます。職歴にも触れていただいたかと思うんですけれども、詳しくお伺いしていきたいとおもいます。ご説明いただいてもよろしいでしょうか"])
        XCTAssertEqual(MeetingTranscript.separator(after: "では次へ。"), "")
        XCTAssertEqual(MeetingTranscript.separator(after: "なぜですか？"), "")
        XCTAssertEqual(MeetingTranscript.separator(after: "研究とか"), "、")
        XCTAssertEqual(MeetingTranscript.separator(after: "ほかに何か"), "、")
        XCTAssertEqual(MeetingTranscript.separator(after: "案をいくつか"), "、")
        XCTAssertEqual(MeetingTranscript.separator(after: "そうですか"), "。")
        XCTAssertEqual(MeetingTranscript.separator(after: ""), "")
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

    /// 決定事項や TODO が「なし」だけなら、見出しごと落とす。要約は残す。
    func testCleanDropsSectionsThatSayNothing() {
        let output = "## 要約\n- 職歴を聞いた\n\n## 決定事項\n- なし\n\n## TODO\n- [ ] なし。\n"
        XCTAssertEqual(MeetingPrompt.clean(output), "## 要約\n- 職歴を聞いた")
        let mixed = "## 要約\n- 話した\n\n## 決定事項\n- なし\n\n## TODO\n- [ ] 田中さんが金曜までに見積もりを出す\n- なし"
        XCTAssertEqual(MeetingPrompt.clean(mixed), "## 要約\n- 話した\n\n## TODO\n- [ ] 田中さんが金曜までに見積もりを出す\n- なし")
        XCTAssertEqual(MeetingPrompt.clean("## 要約\n- なし"), "## 要約\n- なし")
        XCTAssertEqual(MeetingPrompt.clean("見出しのない答え"), "見出しのない答え")
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
