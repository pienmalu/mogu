import AppKit

/// 見た目の決めごと。「原稿と朱筆」：ふだんは静かな紙と墨。朱は、カーソル・赤字・済んだ印にだけ使う。
/// 色・書体・行間の調整はここだけで済むようにする。
final class Theme {
    static let shared = Theme()

    // MARK: - 色（ライト／ダーク）

    static func color(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }

    /// 紙。
    let paper = color(0xFCFCFA, 0x1C1C1F)
    /// 墨。本文。紙の上で 14.7:1 ／ 13.1:1。
    let ink = color(0x26262A, 0xE4E2DD)
    /// 読ませる二次の文字（引用・一覧の2行目・字数）。6.2:1 ／ 7.0:1。
    let inkSecondary = color(0x5F5F66, 0xA6A5AB)
    /// 記号（#、**、`、- など）。読ませないので薄い。
    let inkFaint = color(0xA9A9AE, 0x5E5E64)
    /// 罫と、引用の縦線。
    let rule = color(0xE3E3DF, 0x38383D)
    /// 朱。4.8:1 ／ 5.2:1。
    let shu = color(0xC8402C, 0xE8664F)
    /// コードの下地。
    let wash = color(0xF1F1EE, 0x27272B)
    /// 一覧で選んでいる行。
    let selectedRow = color(0xE9E9E5, 0x323237)
    /// 選択範囲（朱をうすく）。
    let selection = color(0xC8402C, 0xE8664F, alpha: 0.16)

    // MARK: - 書体

    /// 本文の大きさと行の高さ（行間 1.75）。
    let fontSize: CGFloat = 16
    var lineHeight: CGFloat { (fontSize * 1.75).rounded() }
    /// 本文の幅の上限（全角でおよそ 40 字）。
    var columnWidth: CGFloat { fontSize * 40 }

    /// 欧文は SF（明朝と組むときは New York）、和文は凸版文久体（なければヒラギノ）。
    private static func mixed(_ japanese: [String], size: CGFloat, weight: NSFont.Weight, serif: Bool = false) -> NSFont {
        var latin = NSFont.systemFont(ofSize: size, weight: weight)
        if serif, let descriptor = latin.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) {
            latin = font
        }
        guard let jp = japanese.lazy.compactMap({ NSFont(name: $0, size: size) }).first else { return latin }
        let descriptor = latin.fontDescriptor.addingAttributes([.cascadeList: [jp.fontDescriptor]])
        return NSFont(descriptor: descriptor, size: size) ?? latin
    }

    private static let gothic = ["ToppanBunkyuGothicPr6N-Regular", "HiraginoSans-W3"]
    private static let gothicBold = ["ToppanBunkyuGothicPr6N-DB", "HiraginoSans-W6"]
    private static let midashi = ["ToppanBunkyuMidashiMinchoStdN-ExtraBold", "HiraMinProN-W6"]

    lazy var bodyFont = Self.mixed(Self.gothic, size: fontSize, weight: .regular)
    lazy var boldFont = Self.mixed(Self.gothicBold, size: fontSize, weight: .semibold)
    lazy var monoFont: NSFont = {
        let size = fontSize - 2
        let latin = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let jp = Self.gothic.lazy.compactMap({ NSFont(name: $0, size: size) }).first else { return latin }
        return NSFont(descriptor: latin.fontDescriptor.addingAttributes([.cascadeList: [jp.fontDescriptor]]), size: size) ?? latin
    }()

    /// 見出し。大きい2段は見出し明朝、小さい段は文久ゴシックの太字。
    func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: Self.mixed(Self.midashi, size: 26, weight: .heavy, serif: true)
        case 2: Self.mixed(Self.midashi, size: 21, weight: .heavy, serif: true)
        case 3: Self.mixed(Self.gothicBold, size: 17.5, weight: .semibold)
        default: boldFont
        }
    }

    func headingLineHeight(_ level: Int) -> CGFloat {
        switch level {
        case 1: 40
        case 2: 34
        default: lineHeight
        }
    }

    // MARK: - 段落

    /// 行の高さを固定する（lineHeightMultiple だと、カーソルや下地まで縦に伸びるため）。
    func paragraph(lineHeight: CGFloat, before: CGFloat = 0, indent: CGFloat = 0, firstIndent: CGFloat? = nil,
                   tailIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = before
        style.headIndent = indent
        style.firstLineHeadIndent = firstIndent ?? indent
        style.tailIndent = tailIndent
        return style
    }

    var bodyParagraph: NSParagraphStyle { paragraph(lineHeight: lineHeight) }

    /// 空行は短く（段落の切れ目として効き、間延びしない）。
    var blankParagraph: NSParagraphStyle { paragraph(lineHeight: (lineHeight * 0.6).rounded()) }

    func headingParagraph(_ level: Int) -> NSParagraphStyle {
        paragraph(lineHeight: headingLineHeight(level), before: level == 1 ? 18 : level == 2 ? 14 : 8)
    }

    var quoteParagraph: NSParagraphStyle { paragraph(lineHeight: lineHeight, indent: 18) }

    var codeLineHeight: CGFloat { (fontSize * 1.5).rounded() }
    var codeParagraph: NSParagraphStyle { paragraph(lineHeight: codeLineHeight, indent: 14, tailIndent: -14) }

    /// 箇条書きの2行目以降を、記号の後ろの文字にそろえる。
    func listParagraph(prefix: String) -> NSParagraphStyle {
        let width = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
        return paragraph(lineHeight: lineHeight, indent: ceil(width), firstIndent: 0)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: bodyParagraph]
    }
}
