import AppKit
import SwiftUI

/// 見た目の確認用。場面ごとに PNG を描く。
/// 使い方: ./tools/render.sh [出力フォルダ] [--window] [--active]
///   なし       … 本文だけ（画面に出さずに描く）
///   --window   … 窓全体とシートも撮る（画面に一瞬出る。画面収録の許可が要る）
///   --active   … 窓を前に出してキーにする（カーソルと選択の色が本物になる。一瞬フォーカスを奪う）
@main
enum RenderMain {
    static let args = CommandLine.arguments
    static let out = URL(fileURLWithPath: args.dropFirst().first { !$0.hasPrefix("--") } ?? "build/shots")
    static let wantsWindow = args.contains("--window")
    static let wantsActive = args.contains("--active")

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(wantsActive ? .accessory : .prohibited)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (name, text) in Samples.editor {
            for theme in Theme.Kind.allCases {
                renderEditor(text, name: "editor-\(name)-\(theme)", theme: theme)
            }
        }
        if wantsWindow {
            renderWindows()
            renderSheets()
        }
    }

    // MARK: - 本文だけ

    @MainActor static func renderEditor(_ text: String, name: String, theme: Theme.Kind, width: CGFloat = 820, height: CGFloat = 900) {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = EditorController(folder: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = theme.appearance
        window.contentView = editor.scrollView
        editor.newNote()
        editor.textView.string = text
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        pump(0.1)
        let view = editor.scrollView
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        save(rep, name)
    }

    // MARK: - 窓全体

    @MainActor static func renderWindows() {
        for theme in Theme.Kind.allCases {
            shootMain("window-\(theme)", theme: theme, notes: Samples.notes, open: "20261111-083000.md")
        }
        shootMain("window-search-empty", theme: .light, notes: Samples.notes, open: "20261111-083000.md", query: "存在しない言葉")
        shootMain("window-empty-folder", theme: .light, notes: [], open: nil)
        shootMain("window-narrow", theme: .light, notes: Samples.notes, open: "20261111-083000.md", size: NSSize(width: 560, height: 640))
        shootMain("window-no-sidebar", theme: .dark, notes: Samples.notes, open: "20261111-083000.md", collapse: true)
        shootMain("window-selection", theme: .light, notes: Samples.notes, open: "20261111-083000.md",
                  select: NSRange(location: 40, length: 30))
    }

    @MainActor static func shootMain(_ name: String, theme: Theme.Kind, notes: [(String, String)], open: String?,
                                     query: String = "", size: NSSize = NSSize(width: 1040, height: 720),
                                     collapse: Bool = false, select: NSRange? = nil) {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, (file, text)) in notes.enumerated() {
            let url = folder.appendingPathComponent(file)
            try? text.write(to: url, atomically: false, encoding: .utf8)
            let date = Date().addingTimeInterval(-Samples.spacing[min(index, Samples.spacing.count - 1)])
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        NSApp.appearance = theme.appearance
        let store = NoteStore(folder: folder)
        let editor = EditorController(folder: folder)
        let sidebar = Sidebar(store: store, onNew: {}, onOpenFirst: {}, onChooseFolder: {}, onTrash: { _ in })
        let main = MainWindow(store: store, editor: editor, sidebar: sidebar)
        main.window.appearance = theme.appearance
        main.window.setContentSize(size)
        if let open {
            let target = folder.appendingPathComponent(open).standardizedFileURL
            editor.open(target)
            let deadline = Date().addingTimeInterval(3)
            while store.notes.count < notes.count, Date() < deadline { pump(0.05) }
            store.selection = target
        } else {
            editor.newNote()
            pump(0.3)
        }
        store.query = query
        main.split.splitViewItems.first?.isCollapsed = collapse  // 前回の状態が残っていても、撮る場面どおりにする
        if let select { editor.textView.setSelectedRange(select) }
        if wantsActive {
            NSApp.activate(ignoringOtherApps: true)
            main.window.makeKeyAndOrderFront(nil)
            main.window.makeFirstResponder(editor.textView)
        } else {
            main.window.orderFrontRegardless()
        }
        pump(0.6)
        capture(main.window, name)
        main.window.orderOut(nil)
    }

    // MARK: - 推敲シート

    @MainActor static func renderSheets() {
        let server = LLMServer(home: URL(fileURLWithPath: "/nonexistent"))
        let cases: [(String, RewriteSession.Phase, String)] = [
            ("starting", .starting, ""),
            ("writing", .writing, String(Samples.rewritten.prefix(60))),
            ("done", .done, Samples.rewritten),
            ("failed", .failed(LLMServer.Failure.tooLong.localizedDescription), ""),
        ]
        for theme in Theme.Kind.allCases {
            for (name, phase, result) in cases where theme == .light || name == "done" {
                NSApp.appearance = theme.appearance
                let session = RewriteSession(original: Samples.draft, server: server)
                session.result = result
                if phase == .done { session.pieces = Proofread.diff(Samples.draft, result) }
                session.phase = phase
                let host = NSHostingController(rootView: RewriteSheet(session: session, onAccept: { _ in }, onClose: {}))
                let window = NSWindow(contentViewController: host)
                window.styleMask = [.titled, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.appearance = theme.appearance
                window.orderFrontRegardless()
                pump(0.5)
                capture(window, "sheet-\(name)-\(theme)")
                window.orderOut(nil)
            }
        }
    }

    // MARK: - 補助

    static func scratchFolder() -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fude-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func capture(_ window: NSWindow, _ name: String) {
        let file = out.appendingPathComponent("\(name).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
        try? task.run()
        task.waitUntilExit()
        print(task.terminationStatus == 0 ? file.path : "撮れませんでした: \(name)")
    }

    static func save(_ rep: NSBitmapImageRep, _ name: String) {
        let file = out.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print(file.path)
    }
}

extension Theme {
    enum Kind: String, CaseIterable, CustomStringConvertible {
        case light, dark
        var description: String { rawValue }
        var appearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    }
}

/// 見本の文。
enum Samples {
    /// 一覧の日付のまとまり（今日・昨日・今週・それより前）が出るように、更新日時をずらす。
    static let spacing: [TimeInterval] = [0, 3600, 86400, 86400 * 3, 86400 * 20, 86400 * 60]

    static let notes: [(String, String)] = [
        ("20261111-083000.md", long),
        ("読書メモ.md", "# 『情報の呼吸法』\n\n> 情報は溜めるより流す\n\n- 読みながら考えたことを、すぐ書く\n"),
        ("20261110-221500.md", "買い物\n- 牛乳\n- 卵\n- [x] 洗剤\n"),
        ("20261108-091500.md", "# 週次ふりかえり\n\n今週は**論文の第3章**を書き上げた。来週は図を直す。\n"),
        ("20261022-130000.md", "Swift の `Observation` を試す。SwiftUI との相性は良さそう。\n"),
        ("20260912-100000.md", "旅行の持ち物\n- パスポート\n- 充電器\n"),
    ]

    static let editor: [(String, String)] = [
        ("long", long),
        ("empty", ""),
        ("oneline", "明日の10時に歯医者"),
        ("mixed", mixed),
    ]

    static let long = """
    # 打ち合わせメモ

    来週の**研究室ミーティング**までにやること。資料は [共有フォルダ](https://example.com) にまとめる。

    ## やること
    - [x] 先行研究を3本読む
    - [ ] 実験の設定を見直す。サンプル数が足りないので、*もう一度* 集め直すかどうかを先生に相談する
    - [ ] `results.csv` を整理する

    ## 気づき
    > 書く前に、何を言いたいかを一文で言えるようにする。
    > 言えないなら、まだ書く段階ではない。

    1. まず結論
    2. 次に根拠
       - 数字を出す
    3. 最後に ~~言い訳~~ 次の一手

    ---

    ```swift
    let note = "殴り書き"
    print(note)
    ```

    #研究 #メモ
    """

    static let mixed = """
    ## Gemma 4 を Mac で動かす

    llama.cpp の `llama-server` に GGUF を渡すだけ。M4 なら E4B で 30 tokens/s ほど出る。
    Apple Silicon の unified memory は、こういう用途でこそ効いてくる。

    - **E2B**：3.1 GB、速いが文はやや硬い
    - **E4B**：5.0 GB、日本語が自然
    """

    static let draft = """
    きょうのゼミ、先生にいわれたこと
    - 実験のサンプル数たりない。もう少しあつめたほうがいい　あと統計の検定もちゃんとやれと
    - 先行研究のまとめがあまい、2020年以降のやつを追加
    """

    static let rewritten = """
    今日のゼミで先生から指摘されたこと
    - 実験のサンプル数が足りない。もう少し集める必要がある。また、統計の検定もきちんと行うこと。
    - 先行研究のまとめが浅い。2020年以降の文献を追加すること。
    """
}
