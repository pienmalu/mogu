import AppKit

/// 見た目の確認用。見本のノートを開いた窓を画面に出さずに描き、PNG にする。
/// 使い方: ./tools/render.sh [出力フォルダ]
@main
enum RenderMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build/shots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fude-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples: [(String, String)] = [
            ("20261110-091500.md", "# 週次ふりかえり\n\n今週は**論文の第3章**を書き上げた。\n"),
            ("20261109-220000.md", "買い物\n- 牛乳\n- 卵\n"),
            ("読書メモ.md", "# 『情報の呼吸法』\n\n> 情報は溜めるより流す\n"),
            ("20261111-083000.md", sample),
        ]
        for (index, (name, text)) in samples.enumerated() {
            let url = folder.appendingPathComponent(name)
            try? text.write(to: url, atomically: false, encoding: .utf8)
            let date = Date().addingTimeInterval(TimeInterval(-3600 * (samples.count - index)))
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.appearance = NSAppearance(named: appearance)
            let store = NoteStore(folder: folder)
            let editor = EditorController(folder: folder)
            let sidebar = Sidebar(store: store, onNew: {}, onOpenFirst: {}, onChooseFolder: {})
            let main = MainWindow(store: store, editor: editor, sidebar: sidebar)
            main.window.appearance = NSAppearance(named: appearance)
            main.window.setContentSize(NSSize(width: 980, height: 700))
            let target = folder.appendingPathComponent("20261111-083000.md").standardizedFileURL
            editor.open(target)
            // 一覧の読み込み（裏で走る）を待つ
            let deadline = Date().addingTimeInterval(3)
            while store.notes.count < samples.count, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            store.selection = target
            main.window.orderFrontRegardless()
            main.window.alphaValue = 0.0
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            main.window.alphaValue = 1.0
            // 本文：NSTextView はそのまま描ける
            let text = editor.textView
            if let rep = text.bitmapImageRepForCachingDisplay(in: text.visibleRect) {
                text.cacheDisplay(in: text.visibleRect, to: rep)
                save(rep, out.appendingPathComponent("editor-\(name).png"))
            }
            // 窓全体：画面に一瞬出して screencapture で撮る（画面収録の許可がなければ撮れない）
            if CommandLine.arguments.contains("--window") {
                main.window.alphaValue = 1
                main.window.orderFrontRegardless()
                for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                let file = out.appendingPathComponent("window-\(name).png")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", "\(main.window.windowNumber)", file.path]
                try? task.run()
                task.waitUntilExit()
                print(task.terminationStatus == 0 ? file.path : "窓は撮れませんでした（画面収録の許可）")
            }
            main.window.orderOut(nil)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    static func save(_ rep: NSBitmapImageRep, _ file: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print(file.path)
    }

    static let sample = """
    # 打ち合わせメモ

    来週の**研究室ミーティング**までにやること。資料は [共有フォルダ](https://example.com) にまとめる。

    ## やること
    - [x] 先行研究を3本読む
    - [ ] 実験の設定を見直す。サンプル数が足りないので、*もう一度* 集め直すかどうかを先生に相談する
    - [ ] `results.csv` を整理する

    ## 気づき
    > 書く前に、何を言いたいかを一文で言えるようにする。

    1. まず結論
    2. 次に根拠
       - 数字を出す
    3. 最後に ~~言い訳~~ 次の一手

    ```swift
    let note = "殴り書き"
    print(note)
    ```

    #研究 #メモ
    """
}
