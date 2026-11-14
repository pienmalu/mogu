import AppKit

/// 入口。Dock とメニューバーの両方に出る。
@main
enum MoguMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)  // 文字起こしの speech が先に終わっても、音を書き込む側のこのアプリは落ちないように
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller?.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// 議事録を録っている途中なら、終えて文字起こしをノートに入れてから終了する。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.isRecording else { return .terminateNow }
        Task {
            await controller.finishMeeting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        controller?.dockMenu()
    }

    /// Dock のアイコンを押したときは、窓を出す。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow()
        return false
    }
}
