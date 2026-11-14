import AppKit

/// 文字の大きさ・行間・色。見た目の調整はここだけで済むようにする。
/// 書体と色は macOS の標準（システムフォントとシステムの色）に従う。
final class Theme {
    static let shared = Theme()

    var fontSize: CGFloat = 15
    /// 本文の行の高さ。行ごとに書体が混ざっても、行送りがそろうように固定する。
    var lineHeight: CGFloat = 25
    /// 本文の幅の上限。窓が広くても1行が長くなりすぎないように。
    var columnWidth: CGFloat = 680

    /// カーソルのない所では、Markdown の記号（#、**、- [ ] など）を隠す。false にすると、いつも薄く見せる。
    var hidesMarkers = true
    /// チェックボックスの一辺。
    var checkboxSize: CGFloat = 15

    var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 1.5, weight: .regular) }

    func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [1.75, 1.4, 1.18, 1.05, 1, 1]
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return .systemFont(ofSize: (fontSize * sizes[min(level, 6) - 1]).rounded(), weight: weight)
    }

    func headingLineHeight(_ level: Int) -> CGFloat {
        switch level {
        case 1: 36
        case 2: 30
        case 3: 26
        default: lineHeight
        }
    }

    var textColor: NSColor { .labelColor }
    var secondaryColor: NSColor { .secondaryLabelColor }
    var tertiaryColor: NSColor { .tertiaryLabelColor }
    var markerColor: NSColor { .tertiaryLabelColor }
    var accentColor: NSColor { .controlAccentColor }
    let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
    }
    var quoteBar: NSColor { .tertiaryLabelColor }
    var checkboxBorder: NSColor { .tertiaryLabelColor }

    // MARK: - 段落（行の高さは固定。文字は BlockLayoutManager が行の真ん中に置く）

    func paragraph(lineHeight: CGFloat, before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0,
                   firstIndent: CGFloat? = nil, tailIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = indent
        style.firstLineHeadIndent = firstIndent ?? indent
        style.tailIndent = tailIndent
        return style
    }

    var bodyParagraph: NSParagraphStyle { paragraph(lineHeight: lineHeight, after: 2) }

    func headingParagraph(_ level: Int) -> NSParagraphStyle {
        paragraph(lineHeight: headingLineHeight(level), before: level <= 2 ? 14 : 8, after: 4)
    }

    var quoteParagraph: NSParagraphStyle { paragraph(lineHeight: lineHeight, after: 2, indent: 16) }  // 左の縦線の分

    var codeParagraph: NSParagraphStyle {
        paragraph(lineHeight: (monoFont.pointSize * 1.5).rounded(), indent: 12, tailIndent: -12)  // 背景の内側の余白
    }

    /// 箇条書きの2行目以降を、記号の後ろの文字にそろえる。prefix は行頭から記号の後ろの空白まで（「  - [ ] 」など）。
    func listParagraph(prefix: String) -> NSParagraphStyle {
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: bodyFont]).width }
        var indent = width(prefix)
        if hidesMarkers, let box = prefix.range(of: "[") {
            // 見えるのは、字下げ、チェックボックス、その後ろの空白
            let lead = String(prefix.prefix { $0 == " " || $0 == "\t" })
            let tail = String(prefix[box.lowerBound...].dropFirst(3))
            indent = width(lead) + checkboxSize + 1 + width(tail)
        } else if hidesMarkers {
            indent = width(prefix.replacingOccurrences(of: "[-*+]", with: "•", options: .regularExpression))
        }
        return paragraph(lineHeight: lineHeight, after: 1, indent: ceil(indent), firstIndent: 0)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyParagraph]
    }
}
