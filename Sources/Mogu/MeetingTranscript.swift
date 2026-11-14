import Foundation

/// 誰の声か。マイクから入った声が「自分」、Mac から出た声（オンライン会議の相手）が「相手」。
enum Speaker: String, Codable {
    case me = "自分"
    case other = "相手"
}

/// 確定した発言1つ。start は会議を始めてからの秒。
struct Utterance: Equatable, Codable {
    var start: TimeInterval
    var speaker: Speaker
    var text: String
}

/// 発言の列を、ノートに入れる文字と、要約を頼む文字にする（純粋な関数だけ）。
enum MeetingTranscript {
    /// ノートの中の見出し。要約はこの見出しの前に入れる。
    static let heading = "## 文字起こし"

    /// 会議を始めてからの時間。1時間未満は 05:07、それ以上は 1:05:07。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 同じ人が続けて話した分を、1つの段落にまとめる（長くなりすぎたら分ける）。
    static func paragraphs(_ utterances: [Utterance], limit: Int = 160) -> [Utterance] {
        var result: [Utterance] = []
        for item in utterances.sorted(by: { $0.start < $1.start }) {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, last.speaker == item.speaker, last.text.count < limit {
                result[result.count - 1].text += text
            } else {
                result.append(Utterance(start: item.start, speaker: item.speaker, text: text))
            }
        }
        return result
    }

    /// 相手の声（Mac から出た音）が一度でも聞こえた会議だけ、誰の発言かを書く。
    /// 対面の会議はマイクに全員の声が入るので、全部が「自分」になってしまうため。
    static func isLabeled(_ utterances: [Utterance]) -> Bool {
        utterances.contains { $0.speaker == .other }
    }

    /// ノートに入れる Markdown。1段落が1行で、頭に時刻（と話した人）が付く。
    static func markdown(_ utterances: [Utterance]) -> String {
        let labeled = isLabeled(utterances)
        let lines = paragraphs(utterances).map { item in
            "`\(clock(item.start))` " + (labeled ? "**\(item.speaker.rawValue)** " : "") + item.text
        }
        return lines.joined(separator: "\n\n")
    }

    /// 要約を頼むときの文字。記号を付けず、短くする。
    static func plain(_ utterances: [Utterance]) -> String {
        let labeled = isLabeled(utterances)
        return paragraphs(utterances).map { item in
            "[\(clock(item.start))] " + (labeled ? "\(item.speaker.rawValue): " : "") + item.text
        }.joined(separator: "\n")
    }

    /// 長い文字を、行の切れ目で limit 文字以下のまとまりに分ける（1行が limit を超えるときは、その行だけで1つ）。
    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 本文の終わりに文字起こしを足すときの文字（前の文との間を1行あける）。
    static func section(_ utterances: [Utterance], after body: String) -> String {
        let gap = body.isEmpty || body.hasSuffix("\n\n") ? "" : (body.hasSuffix("\n") ? "\n" : "\n\n")
        return gap + heading + "\n\n" + markdown(utterances) + "\n"
    }

    /// 要約を入れる位置（文字起こしの見出しの前。見出しがなければ本文の終わり）と、入れる文字。
    static func summaryInsertion(_ summary: String, into body: String) -> (location: Int, text: String) {
        let ns = body as NSString
        var search = ns.range(of: "\n" + heading, options: .backwards)
        if search.location == NSNotFound, body.hasPrefix(heading) { search = NSRange(location: 0, length: 0) }
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.location != NSNotFound else {
            let gap = body.isEmpty || body.hasSuffix("\n\n") ? "" : (body.hasSuffix("\n") ? "\n" : "\n\n")
            return (ns.length, gap + text + "\n")
        }
        let location = search.location == 0 && search.length == 0 ? 0 : search.location + 1  // 見出しの行の頭
        let before = ns.substring(to: location)
        let gap = before.isEmpty || before.hasSuffix("\n\n") ? "" : "\n"
        return (location, gap + text + "\n\n")
    }
}

/// 録っている間の発言を、1つずつファイルに残す。アプリが落ちても、次に開いたときに取り戻せるように。
/// ノートのフォルダではなく、キャッシュに置く。
struct MeetingJournal {
    let url: URL

    static var standard: MeetingJournal {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.haruka.mogu")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return MeetingJournal(url: caches.appendingPathComponent("meeting-journal.jsonl"))
    }

    private struct Header: Codable {
        var started: Date
    }

    func begin(started: Date) {
        guard let data = try? JSONEncoder().encode(Header(started: started)) else { return }
        try? (data + Data("\n".utf8)).write(to: url)
    }

    func append(_ utterance: Utterance) {
        guard let data = try? JSONEncoder().encode(utterance), let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    func finish() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 前回、終えられなかった会議が残っていれば返す。
    func leftover() -> (started: Date, utterances: [Utterance])? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        guard let first = lines.first, let header = try? JSONDecoder().decode(Header.self, from: Data(first.utf8)) else { return nil }
        let utterances = lines.dropFirst().compactMap { try? JSONDecoder().decode(Utterance.self, from: Data($0.utf8)) }
        return (header.started, utterances)
    }
}
