import Foundation

/// 議事録の要約の頼み方と、返ってきた文の後始末（純粋な関数）。
enum MeetingPrompt {
    /// 一度に渡す文字起こしの長さ（文字）。これより長い会議は、分けて要点を抜き出してからまとめる。
    static let chunkCharacters = 6000

    static let notesSystem = """
    あなたは会議の書記です。ユーザーが渡すのは、会議の音声を自動で文字にしたものの一部です。
    聞き間違いによる誤字が混ざっています。文脈から意味を汲み取ってください。
    この部分で話された要点を、箇条書き（- で始まる行）だけで返してください。
    - 決まったこと、誰かがやると言ったこと、期限、数字、固有名詞は落とさない。
    - 話されていないことは書かない。推測で補わない。
    - 相づちや雑談は省く。
    - 前置きや説明は書かない。
    """

    static let summarySystem = """
    あなたは会議の書記です。ユーザーが渡すのは、会議の音声を自動で文字にしたもの（またはその要点）と、参加者が会議中に書いたメモです。
    文字起こしには聞き間違いによる誤字が混ざっています。文脈から意味を汲み取り、メモの書き方を正しいものとして扱ってください。
    次の形の Markdown だけを返してください。前置き、説明、コードブロックでの囲みは書かないでください。

    ## 要約
    - （話し合ったことを、3〜6個の箇条書きで）

    ## 決定事項
    - （決まったこと。なければ「- なし」）

    ## TODO
    - [ ] （やること。担当や期限が話されていれば、文の中に書く。なければ「- なし」）

    話されていないことは書かない。推測で補わない。
    """

    /// 要点を抜き出すとき（長い会議の一部分ずつ）。
    static func notesRequest(chunk: String) -> [String: Any] {
        LLMServer.requestBody(system: notesSystem, user: chunk)
    }

    /// 議事録にまとめるとき。material は、短い会議なら文字起こしそのもの、長い会議なら抜き出した要点。
    static func summaryRequest(material: String, memo: String) -> [String: Any] {
        let memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = "# 文字起こし\n\(material)"
        if !memo.isEmpty { user += "\n\n# 参加者のメモ\n\(String(memo.prefix(3000)))" }
        return LLMServer.requestBody(system: summarySystem, user: user)
    }

    /// 返ってきた文を、ノートに入れられる形にする。``` の囲みと、最初の見出しより前の前置きを落とす。
    static func clean(_ output: String) -> String {
        var lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let first = lines.firstIndex(where: { $0.hasPrefix("## ") }) { lines.removeFirst(first) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 会議中に書いたメモ（本文から、見出しの行と文字起こしを除いた部分）。
    static func memo(from body: String) -> String {
        var text = body
        if let range = text.range(of: MeetingTranscript.heading, options: .backwards) { text = String(text[..<range.lowerBound]) }
        let lines = text.components(separatedBy: "\n")
        return lines.dropFirst(lines.first?.hasPrefix("# ") == true ? 1 : 0).joined(separator: "\n")
    }
}

extension LLMServer {
    /// 文字起こしから議事録（要約・決定事項・TODO）を作る。長い会議は、分けて要点を抜き出してからまとめる。
    /// onProgress には、いま何をしているかを渡す。
    func summarize(_ utterances: [Utterance], memo: String, onProgress: @MainActor (String) -> Void) async throws -> String {
        let chunks = MeetingTranscript.chunks(MeetingTranscript.plain(utterances), limit: MeetingPrompt.chunkCharacters)
        var material = chunks.first ?? ""
        if chunks.count > 1 {
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                onProgress("要点を拾っています \(index + 1)/\(chunks.count)")
                notes.append(try await chat(MeetingPrompt.notesRequest(chunk: chunk)))
                try Task.checkCancellation()
            }
            material = notes.joined(separator: "\n")
        }
        onProgress("要約を書いています")
        return MeetingPrompt.clean(try await chat(MeetingPrompt.summaryRequest(material: material, memo: memo)))
    }
}
