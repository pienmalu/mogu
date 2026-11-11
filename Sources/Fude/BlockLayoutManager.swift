import AppKit

extension NSAttributedString.Key {
    /// 行のまとまりに描く飾り（"code" = 全幅の背景、"quote" = 左の縦線）。文字には影響しない。
    static let fudeBlock = NSAttributedString.Key("FudeBlock")
}

/// コードブロックの背景を本文の幅いっぱいに、引用の左に縦線を描く。
final class BlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let theme = Theme.shared
        storage.enumerateAttribute(.fudeBlock, in: characters) { value, range, _ in
            guard let kind = value as? String else { return }
            // 見えている部分だけでなく、まとまり全体の形で描く（角の丸みが途中で出ないように）
            var block = range
            _ = storage.attribute(.fudeBlock, at: range.location, longestEffectiveRange: &block,
                                  in: NSRange(location: 0, length: storage.length))
            // 最後の改行は次の行の頭に見えるので含めない
            if block.length > 1, (storage.string as NSString).character(at: NSMaxRange(block) - 1) == 10 { block.length -= 1 }
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
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
    }
}
