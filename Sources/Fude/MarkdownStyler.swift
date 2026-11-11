import AppKit

/// Markdown の文字列に見た目だけを付ける。文字は1つも変えないので、コピーすればそのまま Markdown になる。
enum MarkdownStyler {
    enum Style: Equatable {
        case heading(Int)
        case marker          // 番号など、いつも見せる記号（薄くする）
        case syntax          // #、**、`、[]() など、カーソルのない行では隠す記号
        case bullet(Int)     // 箇条書きの - * +（点を描く。数字は入れ子の深さ）
        case checkbox(Bool)  // [ ] と [x]（箱を描く。true は済み）
        case bold, italic, strike, code, tag
        case codeBlock
        case quote
        case list(indent: Int)  // 記号までの文字数。折り返した行を記号の後ろにそろえる
        case done            // 済んだチェック項目
        case link(String)
        case rule            // 水平線
        case blank           // 空行（段落の切れ目）
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
                    spans.append(Span(range: content, style: .syntax))
                } else {
                    fenceStart = lineRange.location
                    spans.append(Span(range: content, style: .syntax))
                }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if trimmed.isEmpty {
                spans.append(Span(range: lineRange, style: .blank))
                continue
            }
            spans += lineSpans(ns, content)
        }
        if inFence {  // 閉じていない囲みは、最後までコードとして見せる
            spans.append(Span(range: NSRange(location: fenceStart, length: ns.length - fenceStart), style: .codeBlock))
        }
        return spans
    }

    private static func lineSpans(_ ns: NSString, _ line: NSRange) -> [Span] {
        var spans: [Span] = []
        var rest = line  // 行頭の記号を除いた残り（インラインの対象）

        if let m = rule.firstMatch(in: ns as String, range: line) {
            return [Span(range: m.range, style: .rule)]
        }
        if let m = heading.firstMatch(in: ns as String, range: line) {
            let level = m.range(at: 1).length
            spans.append(Span(range: line, style: .heading(level)))
            spans.append(Span(range: m.range, style: .syntax))
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        } else if let m = quote.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: line, style: .quote))
            spans.append(Span(range: m.range, style: .syntax))
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        } else if let m = list.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: line, style: .list(indent: m.range.length)))
            let symbol = m.range(at: 2)
            let box = m.range(at: 3)
            if box.location != NSNotFound {
                // チェック項目は点を描かず、「- [ ]」の位置に箱を1つ描く
                let checked = ns.substring(with: box).lowercased().contains("x")
                spans.append(Span(range: NSRange(location: symbol.location, length: box.location + 3 - symbol.location), style: .checkbox(checked)))
                let after = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
                if checked, after.length > 0 { spans.append(Span(range: after, style: .done)) }
            } else if symbol.length == 1, "-*+".contains(ns.substring(with: symbol)) {
                let depth = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\t", with: "  ").count / 2
                spans.append(Span(range: symbol, style: .bullet(depth)))
            } else {
                spans.append(Span(range: symbol, style: .marker))
            }
            rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        }
        return spans + inlineSpans(ns, rest)
    }

    private static func inlineSpans(_ ns: NSString, _ range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        let text = ns as String
        var spans: [Span] = []
        var codeRanges: [NSRange] = []
        for m in inlineCode.matches(in: text, range: range) {
            codeRanges.append(m.range)
            spans.append(Span(range: m.range, style: .code))
            spans.append(Span(range: NSRange(location: m.range.location, length: 1), style: .syntax))
            spans.append(Span(range: NSRange(location: NSMaxRange(m.range) - 1, length: 1), style: .syntax))
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in link.matches(in: text, range: range) where outsideCode(m.range) {
            let target = ns.substring(with: m.range(at: 2))
            spans.append(Span(range: m.range(at: 1), style: .link(target)))
            spans.append(Span(range: NSRange(location: m.range.location, length: 1), style: .syntax))
            spans.append(Span(range: NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))), style: .syntax))
        }
        for m in bareURL.matches(in: text, range: range) where outsideCode(m.range) {
            spans.append(Span(range: m.range, style: .link(ns.substring(with: m.range))))
        }
        for (expression, style, marker) in [(bold, Style.bold, 2), (strike, .strike, 2), (italic, .italic, 1)] {
            for m in expression.matches(in: text, range: range) where outsideCode(m.range) {
                spans.append(Span(range: m.range, style: style))
                spans.append(Span(range: NSRange(location: m.range.location, length: marker), style: .syntax))
                spans.append(Span(range: NSRange(location: NSMaxRange(m.range) - marker, length: marker), style: .syntax))
            }
        }
        for m in tag.matches(in: text, range: range) where outsideCode(m.range) {
            spans.append(Span(range: m.range, style: .tag))
        }
        return spans
    }

    // MARK: - 適用（範囲と種類 → 属性）

    /// 全体の見た目を付け直す。文字は変えず、Undo にも積まない。
    static func apply(to storage: NSTextStorage, theme: Theme = .shared) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: full)
        for span in spans(in: storage.string) {
            apply(span, to: storage, theme: theme)
        }
        storage.endEditing()
    }

    private static func apply(_ span: Span, to storage: NSTextStorage, theme: Theme) {
        let r = span.range
        switch span.style {
        case .heading(let level):
            storage.addAttribute(.font, value: theme.headingFont(level), range: r)
            storage.addAttribute(.paragraphStyle, value: theme.headingParagraph(level), range: r)
        case .marker:
            storage.addAttribute(.foregroundColor, value: theme.inkSecondary, range: r)
        case .syntax:
            storage.addAttribute(.foregroundColor, value: theme.inkFaint, range: r)
            storage.addAttribute(.fudeHide, value: true, range: r)
        case .bullet(let depth):
            // 文字は透明にして幅だけ残し、上に点を描く（記号を見せても隠しても行がずれない）
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            storage.addAttribute(.fudeBullet, value: depth, range: r)
        case .checkbox(let checked):
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            storage.addAttribute(.fudeCheckbox, value: checked, range: r)
        case .bold:
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                guard let font = value as? NSFont else { return }
                // 本文の大きさなら文久ゴシックの太字、見出しなどはそのまま太らせる
                let bold = abs(font.pointSize - theme.fontSize) < 0.5 && !font.isFixedPitch
                    ? theme.boldFont : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: sub)
            }
        case .italic:
            // 欧文は傾ける。和文は傾けられないので、組版の慣習どおり傍点を打つ（描くのは BlockLayoutManager）
            storage.addAttribute(.obliqueness, value: 0.16, range: r)
            storage.addAttribute(.fudeEmphasis, value: true, range: r)
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.foregroundColor, value: theme.inkSecondary, range: r)
        case .code:
            storage.addAttribute(.font, value: theme.monoFont, range: r)
            storage.addAttribute(.fudeInlineCode, value: true, range: r)
        case .codeBlock:
            storage.addAttribute(.font, value: theme.monoFont, range: r)
            storage.addAttribute(.fudeBlock, value: "code", range: r)
            storage.addAttribute(.paragraphStyle, value: theme.codeParagraph, range: r)
        case .quote:
            storage.addAttribute(.foregroundColor, value: theme.inkSecondary, range: r)
            storage.addAttribute(.paragraphStyle, value: theme.quoteParagraph, range: r)
            // 続く引用の行と縦線がつながるよう、行末の改行まで含める
            let ns = storage.string as NSString
            let withNewline = NSMaxRange(r) < ns.length && ns.character(at: NSMaxRange(r)) == 10
            storage.addAttribute(.fudeBlock, value: "quote", range: NSRange(location: r.location, length: r.length + (withNewline ? 1 : 0)))
        case .list(let indent):
            let prefix = (storage.string as NSString).substring(with: NSRange(location: r.location, length: min(indent, r.length)))
            storage.addAttribute(.paragraphStyle, value: theme.listParagraph(prefix: prefix), range: r)
        case .done:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.strikethroughColor, value: theme.inkFaint, range: r)
            storage.addAttribute(.foregroundColor, value: theme.inkSecondary, range: r)
        case .link(let target):
            // 記号がなくても見分けられるよう、細い下線を引く。開くのは ⌘クリック
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.underlineColor, value: theme.inkFaint, range: r)
            if let url = URL(string: target), url.scheme != nil {
                storage.addAttribute(.fudeLink, value: url, range: r)
            }
        case .tag:
            storage.addAttribute(.foregroundColor, value: theme.inkSecondary, range: r)
        case .rule:
            storage.addAttribute(.foregroundColor, value: theme.inkFaint, range: r)
            storage.addAttribute(.fudeBlock, value: "rule", range: r)
            storage.addAttribute(.fudeHide, value: true, range: r)
        case .blank:
            storage.addAttribute(.paragraphStyle, value: theme.blankParagraph, range: r)
        }
    }

}
