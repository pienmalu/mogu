import AppKit

/// 録音（WAV）を、アプリと同じ経路（speech.cpp → 文字起こし → Gemma の要約）に流して、結果を書き出す。
/// 使い方: ./tools/try-meeting.sh 会議.wav [--no-summary]
@main
enum TryMeeting {
    @MainActor static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first(where: { !$0.hasPrefix("--") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("使い方: try-meeting.sh 会議.wav（16 kHz・16 bit・モノラルに変換したもの）")
            exit(1)
        }
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let files = SpeechFiles(home: home)
        guard files.isAvailable else {
            print("speech.cpp かモデルがありません。./scripts/setup.sh meeting を実行してください")
            exit(1)
        }

        let collected = Collected()
        let transcriber = Transcriber(files: files)
        transcriber.onEvent = { collected.handle($0) }
        let began = Date()
        transcriber.start()
        transcriber.append(data.dropFirst(44))  // WAV のヘッダを飛ばす
        await transcriber.finish(timeout: 600)
        let utterances = collected.utterances
        print(MeetingTranscript.section(utterances, after: ""))
        FileHandle.standardError.write(Data("文字起こし: \(utterances.count) 発言、\(String(format: "%.1f", Date().timeIntervalSince(began))) 秒\n".utf8))

        guard !args.contains("--no-summary"), !utterances.isEmpty else { return }
        let server = LLMServer(home: home)
        let start = Date()
        do {
            let summary = try await server.summarize(utterances, memo: "") { step in
                FileHandle.standardError.write(Data("\(step)\n".utf8))
            }
            print(summary)
            FileHandle.standardError.write(Data("要約: \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒\n".utf8))
        } catch {
            print("要約できませんでした: \(error.localizedDescription)")
        }
        server.stop()
    }
}

/// 読み取りのスレッドから届く発言をためる。
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: TimeInterval] = [:]
    private var items: [Utterance] = []

    var utterances: [Utterance] { lock.withLock { items } }

    func handle(_ event: TranscriberEvent) {
        lock.withLock {
            switch event {
            case .started(let id, let ms): starts[id] = Double(ms) / 1000
            case .completed(let id, let text): items.append(Utterance(start: starts[id] ?? 0, speaker: .me, text: text))
            case .failed(let message): FileHandle.standardError.write(Data("\(message)\n".utf8))
            case .delta: break
            }
        }
    }
}
