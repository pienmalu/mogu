import AppKit
import SwiftUI

/// 本文の上に浮かぶ小さな板（「/」のメニューと、ノートを探す窓）。角の丸い、すりガラス。
final class FloatingPanel: NSPanel {
    static let radius: CGFloat = 12

    private let takesKey: Bool
    /// キーを先に受け取る（↑↓、Enter、Esc）。扱ったら true を返す。
    var onKey: ((NSEvent) -> Bool)?
    /// ほかの所を押して、キーの受け手でなくなったとき。
    var onResign: (() -> Void)?

    init<Content: View>(takesKey: Bool, content: Content) {
        self.takesKey = takesKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.mask(radius: Self.radius)
        let host = NSHostingView(rootView: content)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        contentView = glass
    }

    override var canBecomeKey: Bool { takesKey }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey {
            // 日本語の変換中のキー（確定の Enter など）は、そのまま入力欄へ
            let converting = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if !converting, onKey(event) { return }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    func show(_ frame: NSRect, over parent: NSWindow) {
        setFrame(frame, display: true)
        if self.parent == nil { parent.addChildWindow(self, ordered: .above) }
        if takesKey { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// 角の丸い形（伸び縮みする）。影もこの形に沿う。
    private static func mask(radius: CGFloat) -> NSImage {
        let size = radius * 2 + 1
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 板のふち（細い線）。
struct PanelBorder: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: FloatingPanel.radius).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }
}
