import AppKit

extension NSAttributedString.Key {
    /// 行のまとまりに描く飾り（"code" = 全幅の背景、"quote" = 左の縦線）。文字には影響しない。
    static let moguBlock = NSAttributedString.Key("MoguBlock")
    /// インラインのコード（文字の高さだけの下地を描く）。
    static let moguInlineCode = NSAttributedString.Key("MoguInlineCode")
    /// ⌘クリックで開くリンク先。
    static let moguLink = NSAttributedString.Key("MoguLink")
    /// カーソルが離れている間は隠す記号（値は MarkerScope）。
    static let moguScope = NSAttributedString.Key("MoguScope")
    /// 箇条書きの記号。• として見せる。
    static let moguBullet = NSAttributedString.Key("MoguBullet")
    /// チェックボックスの `[ ]`（値は、済んでいるか）。
    static let moguCheckbox = NSAttributedString.Key("MoguCheckbox")
    /// 水平線の `---`。
    static let moguRule = NSAttributedString.Key("MoguRule")
}

/// 隠す記号のまとまり。カーソル（選択）がこのまとまりに触れている間だけ、記号を見せる。
/// 同じまとまりの記号（太字の前後の ** など）は、同じ MarkerScope を持つ。
final class MarkerScope: NSObject {
    enum Kind {
        /// その行にカーソルがある間、見せる（見出しの #、水平線）。
        case line
        /// 記号に挟まれた範囲にカーソルが触れている間、見せる（太字、リンクなど）。
        case element
        /// 記号そのものの中にカーソルがある間だけ、見せる（チェックボックスの「- [ ]」、引用の「> 」）。
        case own
        /// コードブロックの中にカーソルがある間、見せる（``` の行）。
        case block
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

/// 行の高さをそろえ、記号を隠し、文字の後ろに飾りを描く。
/// 文字そのものは1つも変えない（隠すのも置き換えるのも、見た目だけ。コピーすれば Markdown のまま）。
final class BlockLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// いまの選択。記号を見せるかどうかは、これで決まる。変えるときは reveal(for:) を使う。
    private(set) var selection = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    // MARK: - 記号を見せるか、隠すか

    /// 選択が動いたら呼ぶ。見せ方が変わりうる行だけ、組み直す。
    func reveal(for newSelection: NSRange) {
        let old = selection
        selection = newSelection
        guard Theme.shared.hidesMarkers, let storage = textStorage, old != newSelection else { return }
        for range in [affected(by: old), affected(by: newSelection)] where range.length > 0 {
            var hasMarkers = false
            storage.enumerateAttribute(.moguScope, in: range) { value, _, stop in
                if value != nil {
                    hasMarkers = true
                    stop.pointee = true
                }
            }
            guard hasMarkers else { continue }
            invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    /// 文字を書き換えた直後に、組み直さずに選択だけ合わせる（そのあと全体の見た目を付け直すとき）。
    func setSelection(_ range: NSRange) {
        selection = range
    }

    /// この選択で見せ方が変わりうる範囲：選択のある行と、選択の端がコードブロックの中ならそのブロック。
    private func affected(by selection: NSRange) -> NSRange {
        guard let storage = textStorage, storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        let clamped = NSRange(location: min(selection.location, ns.length),
                              length: min(selection.length, ns.length - min(selection.location, ns.length)))
        var range = ns.paragraphRange(for: clamped)
        for edge in [clamped.location, max(clamped.location, NSMaxRange(clamped) - 1)] where edge < ns.length {
            var block = NSRange()
            if storage.attribute(.moguBlock, at: edge, longestEffectiveRange: &block,
                                 in: NSRange(location: 0, length: ns.length)) as? String == "code" {
                range = NSUnionRange(range, block)
            }
        }
        return range
    }

    /// index の文字が属するまとまりの範囲。
    private func range(of scope: MarkerScope, at index: Int) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: index, length: 0) }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch scope.kind {
        case .line:
            var line = ns.paragraphRange(for: NSRange(location: index, length: 0))
            if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            return line
        case .block:
            var block = NSRange(location: index, length: 0)
            _ = storage.attribute(.moguBlock, at: index, longestEffectiveRange: &block, in: full)
            return block
        case .element, .own:
            // 同じまとまりの記号を、その行の中から集める
            var result = NSRange(location: index, length: 0)
            storage.enumerateAttribute(.moguScope, in: ns.paragraphRange(for: NSRange(location: index, length: 0))) { value, run, _ in
                if value as? MarkerScope === scope { result = result.length == 0 ? run : NSUnionRange(result, run) }
            }
            return result
        }
    }

    /// index にある記号を、いま見せるか。
    func isRevealed(_ scope: MarkerScope, at index: Int) -> Bool {
        guard Theme.shared.hidesMarkers else { return true }
        let range = range(of: scope, at: index)
        let (start, end) = (selection.location, NSMaxRange(selection))
        if scope.kind == .own {
            // 記号の後ろ（本文の頭）にカーソルがあるだけでは、見せない
            return start < NSMaxRange(range) && (end > range.location || (selection.length == 0 && end == range.location))
        }
        return start <= NSMaxRange(range) && end >= range.location
    }

    /// 記号を隠す（幅のない、描かない字にする）。箇条書きの記号は • に、チェックボックスは決まった幅の空きに替える。
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard Theme.shared.hidesMarkers, let storage = textStorage else { return 0 }
        let ns = storage.string as NSString
        let count = glyphRange.length
        var newGlyphs: [CGGlyph] = []
        var newProperties: [NSLayoutManager.GlyphProperty] = []
        func edit() {
            guard newGlyphs.isEmpty else { return }
            newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
            newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        }
        var k = 0
        while k < count {
            let index = characterIndexes[k]
            guard index < storage.length else { break }
            var run = NSRange()
            let attributes = storage.attributes(at: index, effectiveRange: &run)
            let hidden = (attributes[.moguScope] as? MarkerScope).map { !isRevealed($0, at: index) } ?? false
            let bullet = attributes[.moguBullet] != nil
            var boxStart = NSNotFound
            if hidden, attributes[.moguCheckbox] != nil {
                var box = NSRange()
                _ = storage.attribute(.moguCheckbox, at: index, longestEffectiveRange: &box, in: NSRange(location: 0, length: storage.length))
                boxStart = box.location
            }
            while k < count, characterIndexes[k] < NSMaxRange(run) {
                if hidden {
                    edit()
                    // 幅のない、描かない字にする。ただし次の2つは「空き」にして、幅を下の boundingBoxForControlGlyphAt で決める。
                    // - チェックボックスの頭の1字（チェックボックスの幅）
                    // - 行頭の字（幅 0。幅のない字で行を始めると、その字が前の行の終わりに付いてしまい、行頭の字下げが狂うため）
                    let at = characterIndexes[k]
                    let startsLine = at == 0 || ns.character(at: at - 1) == 10
                    newProperties[k] = at == boxStart || startsLine ? .controlCharacter : .null
                } else if bullet, let dot = Self.bulletGlyph(in: font) {
                    edit()
                    newGlyphs[k] = dot
                }
                k += 1
            }
        }
        guard !newGlyphs.isEmpty else { return 0 }
        setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var character: [UniChar] = [0x2022]  // •
        var glyph: [CGGlyph] = [0]
        return CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) ? glyph[0] : nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        // 隠している記号だけ（改行やタブは、そのまま）
        guard let storage = textStorage, charIndex < storage.length,
              storage.attribute(.moguScope, at: charIndex, effectiveRange: nil) != nil,
              let unit = UnicodeScalar((storage.string as NSString).character(at: charIndex)),
              !CharacterSet.controlCharacters.contains(unit), !CharacterSet.newlines.contains(unit) else { return action }
        return .whitespace
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var width: CGFloat = 0
        var box = NSRange()
        if let storage = textStorage, charIndex < storage.length,
           storage.attribute(.moguCheckbox, at: charIndex, longestEffectiveRange: &box, in: NSRange(location: 0, length: storage.length)) != nil,
           box.location == charIndex {
            width = Theme.shared.checkboxSize + 1
        }
        return NSRect(x: glyphPosition.x, y: proposedRect.minY, width: width, height: proposedRect.height)
    }

    // MARK: - 行の高さ

    /// 行の高さを段落の決まり（maximumLineHeight）にそろえ、文字を行の上下の真ん中に置く。
    /// baselineOffset 属性で寄せると、TextKit 1 では行の高さまで増えてしまうため、ここで決める。
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let index = min(characters.location, storage.length - 1)
        let paragraph = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let height = (paragraph?.maximumLineHeight ?? 0) > 0 ? paragraph!.maximumLineHeight : Theme.shared.lineHeight
        // 行の中でいちばん大きい字に合わせる
        var ascender: CGFloat = 0
        var descender: CGFloat = 0
        storage.enumerateAttribute(.font, in: characters) { value, _, _ in
            guard let font = value as? NSFont else { return }
            ascender = max(ascender, font.ascender)
            descender = min(descender, font.descender)
        }
        if ascender == 0, let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont {
            ascender = font.ascender
            descender = font.descender
        }
        let ns = storage.string as NSString
        let startsParagraph = characters.location == 0 || ns.character(at: characters.location - 1) == 10
        let endsParagraph = NSMaxRange(characters) >= ns.length || ns.character(at: NSMaxRange(characters) - 1) == 10
        let before = startsParagraph ? (paragraph?.paragraphSpacingBefore ?? 0) : 0
        let after = endsParagraph ? (paragraph?.paragraphSpacing ?? 0) : 0

        var rect = lineFragmentRect.pointee
        rect.size.height = before + height + after
        lineFragmentRect.pointee = rect
        var used = lineFragmentUsedRect.pointee
        used.origin.y = rect.origin.y + before
        used.size.height = height
        lineFragmentUsedRect.pointee = used
        baselineOffset.pointee = before + ((height - (ascender - descender)) / 2).rounded() + ascender
        return true
    }

    // MARK: - 飾り

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let theme = Theme.shared
        let ns = storage.string as NSString

        storage.enumerateAttribute(.moguBlock, in: characters) { value, range, _ in
            guard let kind = value as? String else { return }
            // 見えている部分だけでなく、まとまり全体の形で描く（角の丸みが途中で出ないように）
            var block = range
            _ = storage.attribute(.moguBlock, at: range.location, longestEffectiveRange: &block,
                                  in: NSRange(location: 0, length: storage.length))
            // 最後の改行は次の行の頭に見えるので含めない
            if block.length > 1, ns.character(at: NSMaxRange(block) - 1) == 10 { block.length -= 1 }
            // 行ごとの使用域（段落の前後の空きを除いた部分）を足し合わせる
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            var rect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in rect = rect.union(used) }
            guard !rect.isNull else { return }
            // 描けるのはテキストコンテナの内側だけなので、字下げした段落の左の空きに描く
            rect.origin.x = 0
            rect.size.width = container.size.width
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch kind {
            case "code":
                theme.codeBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            case "quote":
                theme.quoteBar.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + container.lineFragmentPadding, y: rect.minY + 2,
                                                 width: 3, height: rect.height - 4),
                             xRadius: 1.5, yRadius: 1.5).fill()
            default:
                break
            }
        }

        // インラインコード：行の高さではなく、文字の高さだけの下地
        storage.enumerateAttribute(.moguInlineCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? theme.monoFont
            let height = ceil(font.ascender - font.descender) + 4
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { lineRect, _ in
                var box = lineRect.offsetBy(dx: origin.x, dy: origin.y)
                box.origin.y += ((box.height - height) / 2).rounded()
                box.size.height = height
                theme.codeBackground.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
        }

        // チェックボックス
        storage.enumerateAttribute(.moguCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool, let rect = checkboxRect(at: range.location) else { return }
            Self.drawCheckbox(in: rect.offsetBy(dx: origin.x, dy: origin.y), checked: checked, theme: theme)
        }

        // 水平線
        storage.enumerateAttribute(.moguRule, in: characters) { value, range, _ in
            guard value != nil, let scope = storage.attribute(.moguScope, at: range.location, effectiveRange: nil) as? MarkerScope,
                  !isRevealed(scope, at: range.location) else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let padding = container.lineFragmentPadding
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + padding, y: line.midY.rounded() - 0.5, width: container.size.width - padding * 2, height: 1).fill()
        }
    }

    /// index から始まるチェックボックスの、描く場所（テキストコンテナの座標）。記号を見せている間は nil。
    func checkboxRect(at index: Int) -> NSRect? {
        guard let storage = textStorage, index < storage.length,
              storage.attribute(.moguCheckbox, at: index, effectiveRange: nil) != nil,
              let scope = storage.attribute(.moguScope, at: index, effectiveRange: nil) as? MarkerScope,
              !isRevealed(scope, at: index) else { return nil }
        var box = NSRange()
        _ = storage.attribute(.moguCheckbox, at: index, longestEffectiveRange: &box, in: NSRange(location: 0, length: storage.length))
        let glyph = glyphIndexForCharacter(at: box.location)
        let line = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let size = Theme.shared.checkboxSize
        return NSRect(x: fragment.minX + location(forGlyphAt: glyph).x, y: (line.midY - size / 2).rounded(), width: size, height: size)
    }

    private static func drawCheckbox(in rect: NSRect, checked: Bool, theme: Theme) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
        if checked {
            theme.accentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.52))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.33))
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            theme.checkboxBorder.setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }
    }
}
