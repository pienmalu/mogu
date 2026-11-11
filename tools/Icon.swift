import AppKit

/// アイコンを描く。使い方: ./tools/icon.sh（Resources/AppIcon.icns と、確認用の PNG を作る）
@main
enum IconMain {
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, size) in sizes {
            write(BrushMark.appIcon(size: size), pixels: size, to: out.appendingPathComponent("\(name).png"))
        }
        // メニューバーの見え方（明るい・暗いメニューバー、2倍）
        let preview = URL(fileURLWithPath: CommandLine.arguments[2])
        let bar = NSImage(size: NSSize(width: 120, height: 24), flipped: false) { rect in
            for (index, background) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
                let half = NSRect(x: CGFloat(index) * 60, y: 0, width: 60, height: 24)
                background.setFill()
                half.fill()
                let mark = BrushMark.menuBarImage()
                let tinted = NSImage(size: mark.size, flipped: false) { r in
                    mark.draw(in: r)
                    (index == 0 ? NSColor.black : NSColor.white).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: half.midX - 9, y: 3, width: 18, height: 18))
            }
            return true
        }
        write(bar, pixels: 240, to: preview.appendingPathComponent("menubar.png"), height: 48)
        write(BrushMark.appIcon(size: 256), pixels: 256, to: preview.appendingPathComponent("appicon.png"))
    }

    static func write(_ image: NSImage, pixels: CGFloat, to url: URL, height: CGFloat? = nil) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(height ?? pixels),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: height ?? pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: height ?? pixels))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
