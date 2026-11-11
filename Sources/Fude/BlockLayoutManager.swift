import AppKit

extension NSAttributedString.Key {
    /// 行のまとまりに描く飾り（"code" = 全幅の背景、"quote" = 左の縦線）。文字には影響しない。
    static let fudeBlock = NSAttributedString.Key("FudeBlock")
    /// インラインのコード（文字の高さだけの下地を描く）。
    static let fudeInlineCode = NSAttributedString.Key("FudeInlineCode")
    /// カーソルのない行では隠す記号。
    static let fudeHide = NSAttributedString.Key("FudeHide")
    /// 箇条書きの点（値は入れ子の深さ）。
    static let fudeBullet = NSAttributedString.Key("FudeBullet")
    /// チェックボックス（値は済みかどうか）。
    static let fudeCheckbox = NSAttributedString.Key("FudeCheckbox")
    /// 強調（和文に傍点を打つ）。
    static let fudeEmphasis = NSAttributedString.Key("FudeEmphasis")
    /// ⌘クリックで開くリンク先。
    static let fudeLink = NSAttributedString.Key("FudeLink")
}

/// 文字の後ろに描く飾り：コードブロックの下地（本文の幅いっぱい）、引用の縦線、水平線、インラインコードの下地。
final class BlockLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// 記号を隠すかどうか（表示メニューで切り替える）。
    static let hideKey = "hideMarkup"
    var hidesMarkup = UserDefaults.standard.object(forKey: BlockLayoutManager.hideKey) as? Bool ?? true

    /// 記号を見せる範囲（カーソルや選択のある行）。
    private(set) var revealed = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    /// 見せる範囲を変える。前の行と今の行だけを作り直す。
    func reveal(_ range: NSRange) {
        guard range != revealed, let storage = textStorage else { return }
        let old = revealed
        revealed = range
        for changed in [old, range] where changed.location != NSNotFound {
            let clamped = NSIntersectionRange(changed, NSRange(location: 0, length: storage.length))
            guard clamped.length > 0 || changed.location < storage.length else { continue }
            invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
    }

    /// 全体の隠す・見せるを作り直す（スイッチを切り替えたとき）。
    func refreshAll() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
    }

    /// 隠しているコードの囲みの行（``` だけの行）か。
    private func isHiddenFence(_ characters: NSRange, in storage: NSTextStorage) -> Bool {
        var content = characters
        let ns = storage.string as NSString
        while content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
        guard content.length > 0, !isRevealed(content.location),
              storage.attribute(.fudeBlock, at: content.location, effectiveRange: nil) as? String == "code" else { return false }
        var hidden = NSRange()
        guard storage.attribute(.fudeHide, at: content.location, longestEffectiveRange: &hidden, in: content) != nil else { return false }
        return NSEqualRanges(hidden, content)
    }

    private func isRevealed(_ index: Int) -> Bool {
        guard revealed.location != NSNotFound else { return false }
        return NSLocationInRange(index, revealed) || (revealed.length == 0 && index == revealed.location)
    }

    /// 隠した記号は幅ゼロで、描かない。本物の制御文字（改行・タブ）はふつうに扱う。
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard hidesMarkup, let storage = textStorage, charIndex < storage.length,
              storage.attribute(.fudeHide, at: charIndex, effectiveRange: nil) != nil, !isRevealed(charIndex) else { return action }
        let unit = (storage.string as NSString).character(at: charIndex)
        return unit == 10 || unit == 9 ? action : .zeroAdvancement
    }

    /// 隠す記号のグリフを「なし」にする（幅もなくなる）。文字そのものは残るので、コピーは Markdown のまま。
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard hidesMarkup, let storage = textStorage, storage.length > 0 else { return 0 }
        var changed = false
        var modified = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var effective = NSRange(location: NSNotFound, length: 0)
        var hide = false
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            if !NSLocationInRange(index, effective) {
                hide = storage.attribute(.fudeHide, at: index, effectiveRange: &effective) != nil
            }
            if hide, !isRevealed(index) {
                // .null にすると、行頭のグリフが前の行の末尾に付いてしまう。制御文字として幅ゼロにする
                modified[i] = .controlCharacter
                changed = true
            }
        }
        guard changed else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
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
        var height = (paragraph?.maximumLineHeight ?? 0) > 0 ? paragraph!.maximumLineHeight : Theme.shared.lineHeight
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
        let before = startsParagraph ? (paragraph?.paragraphSpacingBefore ?? 0) : 0

        if hidesMarkup, isHiddenFence(characters, in: storage) { height = 10 }

        var rect = lineFragmentRect.pointee
        rect.size.height = before + height
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
                theme.wash.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -6), xRadius: 8, yRadius: 8).fill()
            case "quote":
                theme.rule.setFill()
                NSRect(x: rect.minX + container.lineFragmentPadding, y: rect.minY + 5, width: 2, height: rect.height - 10).fill()
            case "rule":
                theme.rule.setFill()
                NSRect(x: rect.minX + container.lineFragmentPadding, y: rect.midY.rounded(),
                       width: rect.width - container.lineFragmentPadding * 2, height: 1).fill()
            default:
                break
            }
        }

        // 箇条書きの点と、チェックボックス
        storage.enumerateAttribute(.fudeBullet, in: characters) { value, range, _ in
            guard let depth = value as? Int, let rect = glyphBox(range, container, origin) else { return }
            let size: CGFloat = 5
            let dot = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
            if depth == 0 {
                theme.ink.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                theme.inkSecondary.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        }
        storage.enumerateAttribute(.fudeCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool, let rect = glyphBox(range, container, origin) else { return }
            let side: CGFloat = 15
            let box = NSRect(x: (rect.midX - side / 2).rounded(), y: (rect.midY - side / 2).rounded(), width: side, height: side)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            if checked {
                theme.shu.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.8, y: box.midY + 0.2))
                check.line(to: NSPoint(x: box.minX + 6.5, y: box.midY + 3))
                check.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4.2))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                theme.paper.setStroke()
                check.stroke()
            } else {
                theme.inkSecondary.setStroke()
                path.lineWidth = 1.2
                let inset = NSBezierPath(roundedRect: box.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.5, yRadius: 3.5)
                inset.lineWidth = 1.2
                inset.stroke()
            }
        }

        // 傍点：強調した和文の字の上に、小さな点を1つずつ
        storage.enumerateAttribute(.fudeEmphasis, in: characters) { value, range, _ in
            guard value != nil else { return }
            for offset in 0..<range.length {
                let index = range.location + offset
                guard let scalar = (ns.substring(with: NSRange(location: index, length: 1))).unicodeScalars.first,
                      scalar.value >= 0x3000, storage.attribute(.fudeHide, at: index, effectiveRange: nil) == nil,
                      let box = glyphBox(NSRange(location: index, length: 1), container, origin) else { continue }
                let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? theme.bodyFont
                let top = box.midY - (font.ascender - font.descender) / 2
                let dot = NSRect(x: box.midX - 1.5, y: top - 5, width: 3, height: 3)
                theme.ink.setFill()
                NSBezierPath(ovalIn: dot).fill()
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
                theme.wash.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -2, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    /// 文字の範囲が占める四角（行の高さ。見た目の位置合わせに使う）。
    func glyphBox(_ range: NSRange, _ container: NSTextContainer, _ origin: NSPoint) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = boundingRect(forGlyphRange: glyphs, in: container)
        let used = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return NSRect(x: rect.minX, y: used.minY, width: rect.width, height: used.height).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 点を置いた位置のチェックボックス（クリックで切り替えるため）。
    func checkbox(at point: NSPoint, in container: NSTextContainer, origin: NSPoint) -> (NSRange, Bool)? {
        guard let storage = textStorage else { return nil }
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = glyphIndex(for: local, in: container)
        let index = characterIndexForGlyph(at: glyph)
        let line = (storage.string as NSString).lineRange(for: NSRange(location: min(index, storage.length), length: 0))
        var found: (NSRange, Bool)?
        storage.enumerateAttribute(.fudeCheckbox, in: line) { value, range, stop in
            guard let checked = value as? Bool, let box = glyphBox(range, container, origin) else { return }
            if box.insetBy(dx: -4, dy: 0).contains(point) {
                found = (range, checked)
                stop.pointee = true
            }
        }
        return found
    }
}
