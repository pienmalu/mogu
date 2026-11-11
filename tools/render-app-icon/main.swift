// アプリのアイコン（Dock、Finder、許可のダイアログなどに出る）を描く。
// 正方形の絵 Resources/AppIcon.png を、macOS のアイコンの角丸の形に切り抜き、影を付ける。
// 使い方: ./tools/render-app-icon.sh
import AppKit

let source = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)  // 72 dpi のまま（iconutil は解像度も見る）
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)  // 1024 の格子で描き、画素数に合わせて縮める
    scale.concat()

    // macOS のアイコンの格子: 1024 の中に 824 の本体、角の半径 185。
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // 影は、本体と同じ形を一度塗って付ける。
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 絵を角丸で切り抜いて置く。
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    source.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.current = nil
    return rep
}

let set = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! render(pixels: size * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
print("wrote \(set.path)")
