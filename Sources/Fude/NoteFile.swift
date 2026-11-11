import Foundation

/// 1つの .md ファイル。編集するのは本文だけで、frontmatter・BOM・改行コードは読んだときのまま書き戻す。
struct NoteFile: Equatable {
    /// 先頭の `---` から閉じの `---` の行まで（改行込み）。なければ空。
    var frontmatter: String = ""
    var body: String = ""
    var hasBOM = false
    /// 改行がすべて CRLF のファイルだけ true。編集中は LF にし、書くときに戻す。
    var usesCRLF = false

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// UTF-8 で読めなければ nil（勝手に別の文字コードで読み書きしない）。
    static func parse(_ data: Data) -> NoteFile? {
        var bytes = data
        var file = NoteFile()
        if bytes.starts(with: bom) {
            file.hasBOM = true
            bytes = bytes.dropFirst(bom.count)
        }
        guard var text = String(data: bytes, encoding: .utf8) else { return nil }
        if text.contains("\r\n"), !text.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
            file.usesCRLF = true
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        (file.frontmatter, file.body) = splitFrontmatter(text)
        return file
    }

    func serialized() -> Data {
        var text = frontmatter + body
        if usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data(hasBOM ? Self.bom : [])
        data.append(Data(text.utf8))
        return data
    }

    static func splitFrontmatter(_ text: String) -> (String, String) {
        guard text.hasPrefix("---\n") else { return ("", text) }
        var offset = text.index(text.startIndex, offsetBy: 4)
        while offset < text.endIndex {
            let lineEnd = text[offset...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[offset..<lineEnd]
            if line == "---" || line == "..." {
                let end = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                return (String(text[..<end]), String(text[end...]))
            }
            guard lineEnd < text.endIndex else { break }
            offset = text.index(after: lineEnd)
        }
        return ("", text)  // 閉じがなければ frontmatter とみなさない
    }

    /// 一覧に出す名前。日時だけのファイル名（このアプリが作るもの）は本文の1行目を、ほかはファイル名を使う。
    static func title(body: String, fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let isTimestamp = !stem.isEmpty && stem.allSatisfy { $0.isNumber || "-_ ".contains($0) }
        guard isTimestamp else { return stem }
        guard let line = firstLines(of: body, count: 1).first else { return "無題" }
        return String(line.prefix(80))
    }

    /// 一覧の2行目。タイトルに使った行の次から。
    static func snippet(body: String, fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let isTimestamp = !stem.isEmpty && stem.allSatisfy { $0.isNumber || "-_ ".contains($0) }
        let lines = firstLines(of: body, count: 3)
        return String((isTimestamp ? lines.dropFirst() : lines[...]).joined(separator: " ").prefix(120))
    }

    /// 一覧に出すときの文字だけ（強調の記号を落とし、リンクは文字の部分だけにする）。
    static func plain(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        return text
    }

    /// 空行を飛ばし、見出しや箇条書きの記号を落とした先頭の数行。
    private static func firstLines(of body: String, count: Int) -> [String] {
        var result: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            for prefix in ["#", "> ", "- [ ] ", "- [x] ", "- ", "* "] {
                while line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)) }
            }
            line = plain(line).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            result.append(line)
            if result.count == count { break }
        }
        return result
    }
}
