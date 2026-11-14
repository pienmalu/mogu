import Foundation

/// 書式のキー操作（太字、字下げ、行の移動など）を、文字の書き換えとして決める（純粋な関数）。
/// どれも Markdown の記号を足したり外したりするだけで、本文はプレーンな文字のまま。
enum Formatting {
    /// 1回の書き換え。range を text に置き換え、そのあと selection を選ぶ。
    struct Edit: Equatable {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    // MARK: - 太字・斜体・取り消し線・コード

    /// 選んだ範囲を marker（`**`、`*`、`~~`、`` ` ``）で挟む。すでに挟まれていれば外す。
    /// 何も選んでいなければ、記号を対で入れて、間にカーソルを置く。
    static func toggleWrap(_ text: NSString, selection: NSRange, marker: String) -> Edit {
        let length = (marker as NSString).length
        let selected = text.substring(with: selection) as NSString
        // 選んだ範囲のすぐ外側にある記号の数（* は太字と斜体で重なるので、数で見分ける）
        let unit = (marker as NSString).character(at: 0)
        var before = 0
        while selection.location - before > 0, text.character(at: selection.location - before - 1) == unit { before += 1 }
        var after = 0
        while NSMaxRange(selection) + after < text.length, text.character(at: NSMaxRange(selection) + after) == unit { after += 1 }
        let around = min(before, after)
        let wrapped = marker == "*" ? around % 2 == 1 : around >= length

        if wrapped {
            let range = NSRange(location: selection.location - length, length: selection.length + length * 2)
            return Edit(range: range, text: selected as String, selection: NSRange(location: range.location, length: selection.length))
        }
        // 記号ごと選んでいるときも外す
        if selected.length >= length * 2, selected.hasPrefix(marker), selected.hasSuffix(marker), marker != "*" || !selected.hasPrefix("**") {
            let inner = selected.substring(with: NSRange(location: length, length: selected.length - length * 2))
            return Edit(range: selection, text: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        return Edit(range: selection, text: marker + (selected as String) + marker,
                    selection: NSRange(location: selection.location + length, length: selection.length))
    }

    /// 選んだ範囲をリンクにする。url がわかっていれば（URL を貼ったとき）それを入れ、なければ ( ) の中にカーソルを置く。
    static func link(_ text: NSString, selection: NSRange, url: String? = nil) -> Edit {
        let label = text.substring(with: selection)
        let replaced = "[\(label)](\(url ?? ""))"
        let length = (replaced as NSString).length
        if url != nil {
            return Edit(range: selection, text: replaced, selection: NSRange(location: selection.location + length, length: 0))
        }
        // 文字を選んでいなければ [ ] の中へ、選んでいれば ( ) の中へ
        let caret = selection.length == 0 ? selection.location + 1 : selection.location + length - 1
        return Edit(range: selection, text: replaced, selection: NSRange(location: caret, length: 0))
    }

    /// 貼ろうとしている文字が、1つの URL か。
    static func isURL(_ pasted: String) -> Bool {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("http://") || text.hasPrefix("https://"), !text.contains(where: \.isWhitespace) else { return false }
        return URL(string: text) != nil
    }

    // MARK: - 行の頭の記号

    private static let prefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6}[ \t]+|>[ \t]?|(?:[-*+]|\d{1,3}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#)
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,3}[.)])([ \t]+)(\[([ xX])\][ \t]+)?"#)

    /// カーソルのある行を、別の種類の行にする（見出し、箇条書き、ToDo、引用）。今の記号は置き換える。字下げは残す。
    static func setBlock(_ text: NSString, selection: NSRange, prefix newPrefix: String) -> Edit {
        let line = contentRange(of: text.paragraphRange(for: NSRange(location: selection.location, length: 0)), in: text)
        let content = text.substring(with: line)
        let match = prefix.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length))
        let indent = match.map { (content as NSString).substring(with: $0.range(at: 1)) } ?? ""
        let old = match?.range.length ?? 0
        let replaced = indent + newPrefix
        let shift = (replaced as NSString).length - old
        let caret = max(line.location + (replaced as NSString).length, selection.location + shift)
        return Edit(range: NSRange(location: line.location, length: old), text: replaced, selection: NSRange(location: caret, length: 0))
    }

    /// ToDo のチェックを付け外しする。ToDo でない行は、ToDo にする。選んだ行すべてに効く。
    static func toggleTask(_ text: NSString, selection: NSRange) -> Edit {
        let block = text.paragraphRange(for: selection)
        let lines = text.substring(with: block).components(separatedBy: "\n")
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            if index == lines.count - 1, line.isEmpty, lines.count > 1 {  // 最後の改行のあとの空
                result.append(line)
            } else if let m = listItem.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                if m.range(at: 5).location != NSNotFound {
                    let mark = ns.substring(with: m.range(at: 5)) == " " ? "x" : " "
                    result.append(ns.replacingCharacters(in: m.range(at: 5), with: mark))
                } else {
                    result.append(ns.replacingCharacters(in: NSRange(location: NSMaxRange(m.range), length: 0), with: "[ ] "))
                }
            } else {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                result.append(indent + "- [ ] " + line.dropFirst(indent.count))
            }
        }
        let replaced = result.joined(separator: "\n")
        let grew = (replaced as NSString).length - block.length
        // 1行だけなら、カーソルを元の文字の所に保つ。複数行なら、そのまま全体を選ぶ
        let after = selection.length == 0
            ? NSRange(location: max(block.location, selection.location + grew), length: 0)
            : NSRange(location: block.location, length: (replaced as NSString).length)
        return Edit(range: block, text: replaced, selection: after)
    }

    // MARK: - 字下げ（Tab と ⇧Tab）

    /// 箇条書きの行を、1段下げる（outdent なら上げる）。箇条書きでない1行にカーソルがあるだけなら nil（ふつうの Tab）。
    static func indent(_ text: NSString, selection: NSRange, outdent: Bool) -> Edit? {
        let block = text.paragraphRange(for: selection)
        let body = text.substring(with: contentRange(of: block, in: text))
        let lines = body.components(separatedBy: "\n")
        func isList(_ line: String) -> Bool {
            listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        guard lines.count > 1 || isList(lines[0]) else { return nil }

        // 下げる幅は、すぐ上の行の記号の幅に合わせる（「- 」なら 2、「1. 」なら 3）。そうすると Markdown として入れ子になる
        var step = 2
        if block.location > 0 {
            let above = text.substring(with: text.paragraphRange(for: NSRange(location: block.location - 1, length: 0)))
            if let m = listItem.firstMatch(in: above, range: NSRange(location: 0, length: (above as NSString).length)) {
                step = m.range(at: 2).length + m.range(at: 3).length
            }
        }
        var firstShift = 0
        var total = 0
        let changed = lines.enumerated().map { index, line -> String in
            guard !line.isEmpty else { return line }
            var shift = step
            var result = String(repeating: " ", count: step) + line
            if outdent {
                let leading = line.prefix { $0 == " " }.count
                let remove = line.hasPrefix("\t") ? 1 : min(leading, leading % 2 == 1 ? 3 : 2)
                result = String(line.dropFirst(remove))
                shift = -remove
            }
            if index == 0 { firstShift = shift }
            total += shift
            return result
        }.joined(separator: "\n")
        guard total != 0 else { return Edit(range: NSRange(location: selection.location, length: 0), text: "", selection: selection) }

        let range = NSRange(location: block.location, length: (body as NSString).length)
        let start = max(block.location, selection.location + firstShift)
        let after = selection.length == 0
            ? NSRange(location: start, length: 0)
            : NSRange(location: start, length: max(0, NSMaxRange(selection) + total - start))
        return Edit(range: range, text: changed, selection: after)
    }

    // MARK: - 行を上下に動かす

    /// 選んだ行を、1つ上（up）か下の行と入れ替える。端なら nil。
    static func moveLines(_ text: NSString, selection: NSRange, up: Bool) -> Edit? {
        let block = text.paragraphRange(for: selection)
        if up {
            guard block.location > 0 else { return nil }
            let other = text.paragraphRange(for: NSRange(location: block.location - 1, length: 0))
            var first = text.substring(with: block)
            var second = text.substring(with: other)
            if !first.hasSuffix("\n") {  // 最後の行には改行がないので、改行を付け替える
                first += "\n"
                second = String(second.dropLast())
            }
            return Edit(range: NSUnionRange(other, block), text: first + second,
                        selection: NSRange(location: selection.location - other.length, length: selection.length))
        }
        guard NSMaxRange(block) < text.length else { return nil }
        let other = text.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var first = text.substring(with: other)
        var second = text.substring(with: block)
        if !first.hasSuffix("\n") {
            first += "\n"
            second = String(second.dropLast())
        }
        return Edit(range: NSUnionRange(block, other), text: first + second,
                    selection: NSRange(location: selection.location + (first as NSString).length, length: selection.length))
    }

    // MARK: - 打ちながら効く書き換え

    /// 行頭で `[]` と打って空白を打つと、ToDo（`- [ ] `）になる。空白を入れる直前に呼ぶ。そうでなければ nil。
    static func taskShortcut(_ text: NSString, caret: Int) -> Edit? {
        let line = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        guard before.dropFirst(indent.count) == "[]" else { return nil }
        let replaced = indent + "- [ ] "
        return Edit(range: NSRange(location: line.location, length: caret - line.location), text: replaced,
                    selection: NSRange(location: line.location + (replaced as NSString).length, length: 0))
    }

    /// 行のうち、最後の改行を除いた範囲。
    private static func contentRange(of line: NSRange, in text: NSString) -> NSRange {
        var range = line
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return range
    }
}
