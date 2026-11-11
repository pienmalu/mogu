import AppKit

/// 筆の「はらい」の形。メニューバーのアイコンとアプリのアイコンで使う。
enum BrushMark {
    /// 1×1 の正方形の中のはらい（左上の打ち込みから、右下へ細く抜ける）。y は上向き。
    static func stroke(in rect: NSRect) -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = NSBezierPath()
        // 右はらい：左上で筆を置き（入筆）、右下へ太りながら下り、最後は水平に細く抜ける
        path.move(to: p(0.16, 0.86))
        // 上の縁：入筆の肩から、腹のふくらみを経て、右の先へ寝かせて抜く
        path.curve(to: p(0.98, 0.20), controlPoint1: p(0.36, 0.84), controlPoint2: p(0.50, 0.24))
        // 下の縁：先から戻る。先は細く、腹で厚く
        path.curve(to: p(0.42, 0.34), controlPoint1: p(0.72, 0.16), controlPoint2: p(0.52, 0.18))
        path.curve(to: p(0.12, 0.74), controlPoint1: p(0.30, 0.50), controlPoint2: p(0.18, 0.64))
        // 入筆の丸み
        path.curve(to: p(0.16, 0.86), controlPoint1: p(0.08, 0.80), controlPoint2: p(0.10, 0.86))
        path.close()
        return path
    }

    /// メニューバー用（テンプレート画像。明暗はシステムが合わせる）。
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            stroke(in: rect.insetBy(dx: 0, dy: 1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fude"
        return image
    }

    /// アプリのアイコン：紙の上に墨のはらい、左下に朱の落款。
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            let card = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
            let radius = card.width * 0.225
            // 紙（わずかな影で浮かせる）
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            shadow.set()
            NSColor(srgbRed: 0xFC / 255, green: 0xFC / 255, blue: 0xFA / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
            // 墨のはらい
            NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x2A / 255, alpha: 1).setFill()
            stroke(in: card.insetBy(dx: card.width * 0.13, dy: card.width * 0.16).offsetBy(dx: card.width * 0.01, dy: card.width * 0.05)).fill()
            // 朱の落款
            let sealSide = card.width * 0.17
            // 落款は書の慣習どおり左下に
            let seal = NSRect(x: card.minX + card.width * 0.15, y: card.minY + card.width * 0.14,
                              width: sealSide, height: sealSide)
            NSColor(srgbRed: 0xC8 / 255, green: 0x40 / 255, blue: 0x2C / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: seal, xRadius: sealSide * 0.12, yRadius: sealSide * 0.12).fill()
            let glyph = "筆" as NSString
            let font = NSFont(name: "ToppanBunkyuMidashiMinchoStdN-ExtraBold", size: sealSide * 0.72)
                ?? NSFont(name: "HiraMinProN-W6", size: sealSide * 0.72) ?? .boldSystemFont(ofSize: sealSide * 0.72)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0xFC / 255, green: 0xFC / 255, blue: 0xFA / 255, alpha: 1)]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: seal.midX - size.width / 2, y: seal.midY - size.height / 2 + sealSide * 0.02), withAttributes: attributes)
            return true
        }
    }
}
