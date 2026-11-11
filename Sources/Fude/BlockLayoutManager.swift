import AppKit

extension NSAttributedString.Key {
    /// 行のまとまりに描く飾り（"code" = 全幅の背景、"quote" = 左の縦線）。文字には影響しない。
    static let fudeBlock = NSAttributedString.Key("FudeBlock")
    /// インラインのコード（文字の高さだけの下地を描く）。
    static let fudeInlineCode = NSAttributedString.Key("FudeInlineCode")
    /// ⌘クリックで開くリンク先。
    static let fudeLink = NSAttributedString.Key("FudeLink")
}

/// 行の高さをそろえ、文字の後ろに飾りを描く：コードブロックの下地（本文の幅いっぱい）、引用の縦線、インラインコードの下地。
final class BlockLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

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

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let theme = Theme.shared
        let ns = storage.string as NSString

        storage.enumerateAttribute(.fudeBlock, in: characters) { value, range, _ in
            guard let kind = value as? String else { return }
            // 見えている部分だけでなく、まとまり全体の形で描く（角の丸みが途中で出ないように）
            var block = range
            _ = storage.attribute(.fudeBlock, at: range.location, longestEffectiveRange: &block,
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
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -4), xRadius: 6, yRadius: 6).fill()
            case "quote":
                theme.quoteBar.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + container.lineFragmentPadding, y: rect.minY + 3,
                                                 width: 3, height: rect.height - 6),
                             xRadius: 1.5, yRadius: 1.5).fill()
            default:
                break
            }
        }

        // インラインコード：行の高さではなく、文字の高さだけの下地
        storage.enumerateAttribute(.fudeInlineCode, in: characters) { value, range, _ in
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
                NSBezierPath(roundedRect: box.insetBy(dx: -2, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}
