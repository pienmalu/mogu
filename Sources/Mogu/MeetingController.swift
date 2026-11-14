import AppKit

/// 議事録の流れ：始める → 録りながらメモを書く → 終える → 文字起こしを入れる → 要約を入れる。
/// ノートへの書き込みは、すべてエディタを通す（⌘Z で戻せる。裏でファイルを書き換えない）。
@MainActor
final class MeetingController {
    let session: MeetingSession
    private let editor: EditorController
    private let store: NoteStore
    private let server: LLMServer
    private let files: SpeechFiles
    private let showWindow: () -> Void
    private var summaryTask: Task<Void, Never>?

    init(home: URL, editor: EditorController, store: NoteStore, server: LLMServer, showWindow: @escaping () -> Void) {
        files = SpeechFiles(home: home)
        session = MeetingSession(files: files)
        self.editor = editor
        self.store = store
        self.server = server
        self.showWindow = showWindow
    }

    /// 録っていなければ始め、録っていれば終える。
    func toggle() {
        if session.isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    // MARK: - 始める

    func start() {
        if session.phase == .ready { insertSummary() }  // 前の会議の要約が待っていれば、先に入れる
        guard !session.isBusy else {
            NSSound.beep()
            return
        }
        guard files.isAvailable else {
            alert("議事録の準備がまだです", "ターミナルで ./scripts/setup.sh meeting を実行すると、文字起こしに使う speech.cpp とモデル（0.66 GB）を取ってきます。")
            return
        }
        Task {
            guard await MeetingSession.askForMicrophone() else {
                alert("マイクを使えません", "システム設定の「プライバシーとセキュリティ」→「マイク」で、\(AppController.appName) を許可してください。",
                      settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
            begin()
        }
    }

    private func begin() {
        guard !session.isBusy else { return }
        // 新しいノートを作り、見出しを入れてすぐ保存する（議事録の入れ先を決めるため）
        editor.newNote()
        store.selection = nil
        editor.insert(Self.title() + "\n\n", at: 0)
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length, length: 0))
        editor.save()
        do {
            try session.start(noteURL: editor.url)
        } catch {
            // 見出しだけのノートを残さない（ゴミ箱へ）
            if let url = editor.url {
                editor.discard()
                store.trash(url)
            }
            alert("議事録を始められません", error.localizedDescription)
            return
        }
        showWindow()
    }

    static func title(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "# 会議 " + formatter.string(from: date)
    }

    // MARK: - 終える

    /// 録るのをやめ、文字起こしをノートに入れる。summarize が true なら、続けて要約も作る。
    func stop(summarize: Bool = true) async {
        guard session.isRecording else { return }
        let utterances = await session.stop()
        guard !utterances.isEmpty else {
            session.transcriptSaved()
            session.notify("声が聞こえませんでした")
            return
        }
        openNote()
        let body = editor.textView.string
        editor.insert(MeetingTranscript.section(utterances, after: body), at: (body as NSString).length)
        editor.save()
        if !editor.isDirty { session.transcriptSaved() }

        guard summarize else {
            session.finish()
            return
        }
        guard server.isAvailable else {
            session.notify("文字起こしを入れました。要約には ./scripts/setup.sh が要ります")
            return
        }
        session.phase = .summarizing("要約を書いています")
        let memo = MeetingPrompt.memo(from: body)
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await server.summarize(utterances, memo: memo) { [weak self] step in
                    guard let self, !Task.isCancelled else { return }
                    session.phase = .summarizing(step)
                }
                guard !Task.isCancelled else { return }
                guard !summary.isEmpty else {
                    session.notify("要約できませんでした。文字起こしは入っています")
                    return
                }
                session.pendingSummary = summary
                // 議事録のノートを開いていて、変換の途中でなければ、そのまま入れる。そうでなければ、押されるのを待つ
                if editor.url == session.noteURL, !editor.textView.hasMarkedText() {
                    insertSummary()
                } else {
                    session.phase = .ready
                }
            } catch {
                guard !Task.isCancelled else { return }
                session.notify("要約できませんでした。文字起こしは入っています")
                NSLog("要約できませんでした: \(error.localizedDescription)")
            }
        }
    }

    func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        session.finish()
    }

    /// できあがった要約を、文字起こしの前に入れる。
    func insertSummary() {
        guard let summary = session.pendingSummary else { return }
        openNote()
        let (location, text) = MeetingTranscript.summaryInsertion(summary, into: editor.textView.string)
        editor.insert(text, at: location)
        editor.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        editor.save()
        session.pendingSummary = nil
        session.notify("議事録ができました")
        showWindow()
    }

    /// 議事録のノートを開く。ゴミ箱に入れられていたら、新しいノートを作る。
    private func openNote() {
        editor.textView.unmarkText()  // 変換の途中なら確定する
        if let url = session.noteURL, editor.url == url { return }
        if let url = session.noteURL, FileManager.default.fileExists(atPath: url.path) {
            editor.open(url)
            store.selection = url
        } else {
            editor.newNote()
            store.selection = nil
            editor.insert(Self.title(session.started ?? Date()) + "\n", at: 0)
            editor.save()
            session.noteURL = editor.url
        }
    }

    // MARK: - 落ちたときの後始末

    /// 前回、終えられなかった会議の文字起こしが残っていれば、新しいノートにする（ほかのノートには触れない）。
    func recoverLeftover(journal: MeetingJournal = .standard) {
        guard let (started, utterances) = journal.leftover() else { return }
        defer { journal.finish() }
        guard !utterances.isEmpty else { return }
        let text = Self.title(started) + "（途中で終わった分）\n\n" + MeetingTranscript.section(utterances, after: "")
        let target = EditorController.uniqueURL(in: store.folder, stem: EditorController.timestamp(started))
        do {
            try Data(text.utf8).write(to: target, options: .withoutOverwriting)
            store.reload()
        } catch {
            NSLog("残っていた文字起こしを書き出せませんでした: \(error)")
        }
    }

    private func alert(_ title: String, _ text: String, settings: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if settings != nil { alert.addButton(withTitle: "設定を開く") }
        if alert.runModal() == .alertSecondButtonReturn, let settings, let url = URL(string: settings) {
            NSWorkspace.shared.open(url)
        }
    }
}
