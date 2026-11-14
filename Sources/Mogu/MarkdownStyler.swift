import AppKit

/// Markdown の文字列に見た目だけを付ける。文字は1つも変えないので、コピーすればそのまま Markdown になる。
enum MarkdownStyler {
    enum Style: Equatable {
        case heading(Int)
        case marker          // #、**、` などの記号（薄くする）
        case bold, italic, strike, code, tag
        case codeBlock
        case quote
        case list(indent: Int)  // 記号までの文字数。折り返した行を記号の後ろにそろえる
        case done            // 済んだチェック項目
        case link(String)
        case rule            // 水平線
        /// カーソルが離れている間は隠す記号。同じ番号の範囲は、1つのまとまり（太字の前後の ** など）。
        case hide(MarkerScope.Kind, Int)
        case bullet          // 箇条書きの記号（• として見せる）
        case number          // 番号つきの箇条書きの番号
        case checkbox(Bool, Int)  // [ ] と [x]（チェックボックスとして見せる）。番号は、隠す記号（- ）と同じまとまり
    }

    struct Span: Equatable {
        let range: NSRange
        let style: Style
    }

    // MARK: - 解析（文字列 → 範囲と種類）

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let quote = regex(#"^>[ \t]?"#)
    private static let list = regex(#"^([ \t]*)([-*+]|\d{1,3}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    /// `*` は日本語の文中でも効かせる。`_` は snake_case を誤って拾わないよう、前後が文字のときは効かせない。
    private static let italic = regex(#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)|(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let bareURL = regex(#"(?<![(<\w])https?://[^\s<>()\]]+"#)
    private static let tag = regex(#"(?<=^|\s)#[^\s#\p{P}][^\s#]*"#)

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var inFence = false
        var fenceStart = 0
        var fenceID = 0
        var nextID = 0  // 隠す記号のまとまりの番号
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            var content = lineRange
            while content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            let line = ns.substring(with: content)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inFence {
                    spans.append(Span(range: NSRange(location: fenceStart, length: NSMaxRange(lineRange) - fenceStart), style: .codeBlock))
                } else {
                    fenceStart = lineRange.location
                    nextID += 1
                    fenceID = nextID
                }
                spans.append(Span(range: content, style: .marker))
                spans.append(Span(range: content, style: .hide(.block, fenceID)))
                inFence.toggle()
                continue
            }
            if inFence { continue }
            spans += lineSpans(ns, content, &nextID)
        }
        if inFence {  // 閉じていない囲みは、最後までコードとして見せる
            spans.append(Span(range: NSRange(location: fenceStart, length: ns.length - fenceStart), style: .codeBlock))
        }
        return spans
    }

    private static func lineSpans(_ ns: NSString, _ line: NSRange, _ nextID: inout Int) -> [Span] {
        var spans: [Span] = []
        var rest = line  // 行頭の記号を除いた残り（インラインの対象）
        func newID() -> Int {
            nextID += 1
            return nextID
        }

        if let m = rule.firstMatch(in: ns as String, range: line) {
            return [Span(range: m.range, style: .rule), Span(range: m.range, style: .hide(.line, newID()))]
        }
        if let m = heading.firstMatch(in: ns as String, range: line) {
            let level = m.range(at: 1).length
            spans.append(Span(range: line, style: .heading(level)))
            spans.append(Span(range: m.range, style: .marker))
            spans.append(Span(range: m.range, style: .hide(.line, newID())))
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        } else if let m = quote.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: line, style: .quote))
            spans.append(Span(range: m.range, style: .marker))
            spans.append(Span(range: m.range, style: .hide(.own, newID())))
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        } else if let m = list.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: line, style: .list(indent: m.range.length)))
            let ordered = !"-*+".contains(ns.substring(with: m.range(at: 2)))
            spans.append(Span(range: m.range(at: 2), style: ordered ? .number : .marker))
            let box = m.range(at: 3)
            if box.location == NSNotFound {
                if !ordered { spans.append(Span(range: m.range(at: 2), style: .bullet)) }
            } else {
                spans.append(Span(range: box, style: .marker))
                let checked = ns.substring(with: box).lowercased().contains("x")
                // 「- 」を隠し、「[ ]」をチェックボックスとして見せる（その後ろの空白は、そのまま間隔になる）
                let id = newID()
                let marker = m.range(at: 2).location
                spans.append(Span(range: NSRange(location: marker, length: box.location - marker), style: .hide(.own, id)))
                spans.append(Span(range: NSRange(location: box.location, length: 3), style: .checkbox(checked, id)))
                let after = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
                if checked, after.length > 0 { spans.append(Span(range: after, style: .done)) }
            }
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        }
        return spans + inlineSpans(ns, rest, &nextID)
    }

    private static func inlineSpans(_ ns: NSString, _ range: NSRange, _ nextID: inout Int) -> [Span] {
        guard range.length > 0 else { return [] }
        let text = ns as String
        var spans: [Span] = []
        var codeRanges: [NSRange] = []
        /// 記号を薄くし、カーソルがこのまとまりに触れていない間は隠す。
        func marker(_ ranges: [NSRange]) {
            nextID += 1
            for r in ranges {
                spans.append(Span(range: r, style: .marker))
                spans.append(Span(range: r, style: .hide(.element, nextID)))
            }
        }
        for m in inlineCode.matches(in: text, range: range) {
            codeRanges.append(m.range)
            spans.append(Span(range: m.range, style: .code))
            marker([NSRange(location: m.range.location, length: 1), NSRange(location: NSMaxRange(m.range) - 1, length: 1)])
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in link.matches(in: text, range: range) where outsideCode(m.range) {
            let target = ns.substring(with: m.range(at: 2))
            spans.append(Span(range: m.range(at: 1), style: .link(target)))
            marker([NSRange(location: m.range.location, length: 1),
                    NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1)))])
        }
        for m in bareURL.matches(in: text, range: range) where outsideCode(m.range) {
            spans.append(Span(range: m.range, style: .link(ns.substring(with: m.range))))
        }
        for (expression, style, length) in [(bold, Style.bold, 2), (strike, .strike, 2), (italic, .italic, 1)] {
            for m in expression.matches(in: text, range: range) where outsideCode(m.range) {
                spans.append(Span(range: m.range, style: style))
                marker([NSRange(location: m.range.location, length: length), NSRange(location: NSMaxRange(m.range) - length, length: length)])
            }
        }
        for m in tag.matches(in: text, range: range) where outsideCode(m.range) {
            spans.append(Span(range: m.range, style: .tag))
        }
        return spans
    }

    // MARK: - 適用（範囲と種類 → 属性）

    /// 見た目を付け直す。文字は変えず、Undo にも積まない。
    /// range を渡すと、その範囲（行のまとまり）だけ付け直す。長いノートでも1字ごとに全体を組み直さずに済む。
    static func apply(to storage: NSTextStorage, in range: NSRange? = nil, theme: Theme = .shared) {
        let target = range ?? NSRange(location: 0, length: storage.length)
        let text = range == nil ? storage.string : (storage.string as NSString).substring(with: target)
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: target)
        var scopes: [Int: MarkerScope] = [:]
        for span in spans(in: text) {
            let moved = Span(range: NSRange(location: span.range.location + target.location, length: span.range.length), style: span.style)
            apply(moved, to: storage, theme: theme, scopes: &scopes)
        }
        storage.endEditing()
    }

    /// 行の中の書き換えなら、その行だけ付け直せばよい。コードブロックの囲み（```）が絡むときは、全体に及ぶ。
    static func canRestyleLocally(_ storage: NSTextStorage, lines: NSRange) -> Bool {
        guard lines.length > 0 else { return false }
        let text = (storage.string as NSString).substring(with: lines)
        if text.contains("```") || text.contains("~~~") { return false }
        var inCode = false
        storage.enumerateAttribute(.moguBlock, in: lines) { value, _, stop in
            if value as? String == "code" {
                inCode = true
                stop.pointee = true
            }
        }
        return !inCode
    }

    /// 囲みの記号の数。増減したら、コードブロックの範囲が変わっている。
    static func fenceCount(in text: String) -> Int {
        text.components(separatedBy: "```").count + text.components(separatedBy: "~~~").count
    }

    private static func apply(_ span: Span, to storage: NSTextStorage, theme: Theme, scopes: inout [Int: MarkerScope]) {
        let r = span.range
        func scope(_ kind: MarkerScope.Kind, _ id: Int) -> MarkerScope {
            if let known = scopes[id] { return known }
            let made = MarkerScope(kind)
            scopes[id] = made
            return made
        }
        switch span.style {
        case .hide(let kind, let id):
            storage.addAttribute(.moguScope, value: scope(kind, id), range: r)
        case .bullet:
            storage.addAttribute(.moguBullet, value: true, range: r)
            storage.addAttribute(.foregroundColor, value: theme.textColor, range: r)
        case .number:
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: r)
        case .checkbox(let checked, let id):
            storage.addAttribute(.moguCheckbox, value: checked, range: r)
            storage.addAttribute(.moguScope, value: scope(.own, id), range: r)
        case .heading(let level):
            storage.addAttribute(.font, value: theme.headingFont(level), range: r)
            storage.addAttribute(.paragraphStyle, value: theme.headingParagraph(level), range: r)
        case .marker:
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: r)
        case .bold:
            addTrait(.boldFontMask, storage, r)
        case .italic:
            addTrait(.italicFontMask, storage, r)
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: r)
        case .code:
            storage.addAttribute(.font, value: theme.monoFont, range: r)
            // 下地は BlockLayoutManager が文字の高さだけ描く（.backgroundColor だと行の高さまで伸びる）
            storage.addAttribute(.moguInlineCode, value: true, range: r)
        case .codeBlock:
            storage.addAttribute(.font, value: theme.monoFont, range: r)
            storage.addAttribute(.moguBlock, value: "code", range: r)
            storage.addAttribute(.paragraphStyle, value: theme.codeParagraph, range: r)
        case .quote:
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: r)
            storage.addAttribute(.paragraphStyle, value: theme.quoteParagraph, range: r)
            // 続く引用の行と縦線がつながるよう、行末の改行まで含める
            let ns = storage.string as NSString
            let withNewline = NSMaxRange(r) < ns.length && ns.character(at: NSMaxRange(r)) == 10
            storage.addAttribute(.moguBlock, value: "quote", range: NSRange(location: r.location, length: r.length + (withNewline ? 1 : 0)))
        case .list(let indent):
            let prefix = (storage.string as NSString).substring(with: NSRange(location: r.location, length: min(indent, r.length)))
            storage.addAttribute(.paragraphStyle, value: theme.listParagraph(prefix: prefix), range: r)
        case .done:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.foregroundColor, value: theme.tertiaryColor, range: r)
        case .link(let target):
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: r)
            // .link にすると、クリックしただけで開いてしまい、リンクの中にカーソルを置けない。開くのは ⌘クリック
            if let url = URL(string: target), url.scheme != nil {
                storage.addAttribute(.moguLink, value: url, range: r)
            }
        case .tag:
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: r)
        case .rule:
            storage.addAttribute(.foregroundColor, value: theme.tertiaryColor, range: r)
            storage.addAttribute(.moguRule, value: true, range: r)
        }
    }

    private static func addTrait(_ trait: NSFontTraitMask, _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }
}
