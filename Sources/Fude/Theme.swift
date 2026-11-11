import AppKit

/// 文字の大きさ・行間・色。見た目の調整はここだけで済むようにする。
final class Theme {
    static let shared = Theme()

    var fontSize: CGFloat = 15
    /// 本文の幅の上限。窓が広くても1行が長くなりすぎないように。
    var columnWidth: CGFloat = 680

    var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 1.5, weight: .regular) }

    func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [1.75, 1.4, 1.18, 1.05, 1, 1]
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return .systemFont(ofSize: (fontSize * sizes[min(level, 6) - 1]).rounded(), weight: weight)
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

    var bodyParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 2
        return style
    }

    func headingParagraph(_ level: Int) -> NSParagraphStyle {
        let style = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
        style.lineHeightMultiple = 1.2
        style.paragraphSpacingBefore = level <= 2 ? 14 : 8
        style.paragraphSpacing = 4
        return style
    }

    var quoteParagraph: NSParagraphStyle {
        let style = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 16  // 左の縦線の分
        style.headIndent = 16
        return style
    }

    var codeParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        style.firstLineHeadIndent = 12  // 背景の内側の余白
        style.headIndent = 12
        style.tailIndent = -12
        return style
    }

    /// 箇条書きの2行目以降を、記号の後ろの文字にそろえる。
    func listParagraph(prefix: String) -> NSParagraphStyle {
        let style = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
        let width = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
        style.headIndent = ceil(width)
        style.paragraphSpacing = 1
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyParagraph]
    }
}
