import AppKit
import SwiftUI

/// ただ1つの窓。左に一覧、右に本文。閉じても隠すだけで、アプリは残る。
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let split = NSSplitViewController()
    private let editor: EditorController

    init(store: NoteStore, editor: EditorController, sidebar: Sidebar, bar: MeetingBar? = nil) {
        self.editor = editor
        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true

        // 本文の上に、議事録のバーを浮かべる（下の中央。出ていないときは大きさが 0 で、クリックを邪魔しない）
        let editorHost = NSViewController()
        let container = NSView()
        editor.scrollView.frame = container.bounds
        editor.scrollView.autoresizingMask = [.width, .height]
        container.addSubview(editor.scrollView)
        if let bar {
            let overlay = NSHostingView(rootView: bar)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                overlay.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
            ])
        }
        editorHost.view = container
        let editorItem = NSSplitViewItem(viewController: editorHost)
        editorItem.minimumThickness = 320

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        split.splitView.autosaveName = "MoguSplit"

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        window.setFrameAutosaveName("MoguMain")
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]  // 今いるデスクトップ（フルスクリーンの上も）に出す
        super.init()
        window.delegate = self
    }

    // MARK: - 透かして手前に出す

    private(set) var isOverlay = false
    /// 透かす前に、一覧が出ていたか（戻すときに出し直す）。
    private var sidebarWasOpen = true

    /// 窓を半透明にして、ほかのアプリの窓より手前に置いたままにする。文字は薄めず、下地だけ透かす。
    func setOverlay(_ on: Bool) {
        guard on != isOverlay else { return }
        isOverlay = on
        window.level = on ? .floating : .normal
        window.isOpaque = !on
        window.backgroundColor = on ? Theme.shared.overlayBackground : .windowBackgroundColor
        // 透かしている間は、どのデスクトップにも付いてくる
        window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        editor.setTranslucent(on)
        // 一覧はすりガラスで透けないので、畳む（⌃⌘S でいつでも出せる）
        // 一覧を出し入れすると本文が上へ流れるので、読んでいる所を覚えておいて戻す
        let clip = editor.scrollView.contentView
        let origin = clip.bounds.origin
        if let sidebar = split.splitViewItems.first {
            if on {
                sidebarWasOpen = !sidebar.isCollapsed
                sidebar.isCollapsed = true
            } else if sidebarWasOpen {
                sidebar.isCollapsed = false
            }
        }
        split.view.layoutSubtreeIfNeeded()
        let restore = { [editor] in
            guard clip.bounds.origin != origin else { return }
            clip.scroll(to: origin)
            editor.scrollView.reflectScrolledClipView(clip)
        }
        restore()
        DispatchQueue.main.async { [weak self] in
            restore()
            // 影は窓の形から作られるので、下地を替えた後に作り直す
            self?.window.invalidateShadow()
        }
    }

    var isFrontmost: Bool { window.isVisible && window.isKeyWindow && NSApp.isActive }

    func show(focusEditor: Bool = true) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if focusEditor { window.makeFirstResponder(editor.textView) }
    }

    func hide() {
        editor.save()
        window.orderOut(nil)
        NSApp.hide(nil)  // 直前のアプリに戻す
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.save()
    }
}
