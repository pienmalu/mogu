import Foundation

/// 文字起こしに使うファイルの場所。setup.sh が vendor/ と models/ に置く。
struct SpeechFiles {
    let speech: URL
    let model: URL
    let vad: URL

    init(home: URL) {
        speech = home.appendingPathComponent("vendor/speech")
        model = home.appendingPathComponent("models/haas-ja-v1.0-q8_0.gguf")
        vad = home.appendingPathComponent("models/silero-vad.gguf")
    }

    var isAvailable: Bool {
        [speech, model, vad].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum TranscriberEvent: Equatable {
    /// 話し始めた。ms は、流し始めてからの時間。
    case started(id: String, ms: Int)
    /// 話している途中の文字（続きの分だけ）。
    case delta(id: String, text: String)
    /// 言い終えて確定した文。
    case completed(id: String, text: String)
    /// 動かせなかった、または途中で止まった。
    case failed(String)
}

/// Mac の中の speech.cpp で、音を文字にする。音は外に出ない。
///
/// `speech asr Haas --vad Silero --format json -` を1つ動かし続け、標準入力へ音を流す。
/// speech.cpp が話している区間を見つけ、途中の文字と確定した文を JSON で1行ずつ返す。
final class Transcriber: @unchecked Sendable {
    /// 読み取りのスレッドから呼ばれる。
    var onEvent: ((TranscriberEvent) -> Void)?

    private let files: SpeechFiles
    private let writer = DispatchQueue(label: "mogu.transcriber.writer")
    private var process: Process?
    private var input: FileHandle?
    private var finishing = false
    /// 結果を最後まで読み終えたら合図する。
    private let drained = DispatchSemaphore(value: 0)

    /// 動いている様子（うまく文字にならないときに、どこで止まっているかを見分けるため）。
    struct Stats: Equatable {
        /// 渡されたが、まだ speech.cpp に書けていない音。増え続けるなら、speech.cpp が音を読んでいない。
        var pendingBytes = 0
        /// speech.cpp が終わっていて、捨てた音。
        var droppedBytes = 0
        /// speech.cpp から返ってきた行（話し始め、途中の文字、確定した文）の数。
        var events = 0
    }
    private let statsLock = NSLock()
    private var stats = Stats()

    /// 前に呼んでからの様子。待っている音だけは、いまの量。
    func takeStats() -> Stats {
        statsLock.withLock {
            defer { stats.droppedBytes = 0; stats.events = 0 }
            return stats
        }
    }

    init(files: SpeechFiles) {
        self.files = files
    }

    /// この長さ（ミリ秒）黙ったら、発言を区切る。短いと「はい」のような切れ端が増える。
    static let silenceMs = 700

    static func arguments(files: SpeechFiles) -> [String] {
        // 1つの区切りは speech.cpp の既定の最長 10 秒のまま（Haas は長い区間で文を落とすことがある）。
        ["asr", files.model.path, "--vad", files.vad.path, "--min-silence-duration-ms", String(silenceMs),
         "--rate", String(Resampler.sampleRate), "--format", "json", "-"]
    }

    func start() {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = files.speech
        process.arguments = Self.arguments(files: files)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let unexpected = self.writer.sync { !self.finishing && self.process === finished }
            if unexpected { self.onEvent?(.failed("speech.cpp が止まりました（終了コード \(finished.terminationStatus)）")) }
        }
        // 結果とログは読み続ける（読まずにいるとパイプが詰まり、speech が止まるため）。
        Self.readLines(output.fileHandleForReading, onLine: { [weak self] line in
            guard let self, let event = Self.parse(line) else { return }
            self.statsLock.withLock { self.stats.events += 1 }
            self.onEvent?(event)
        }, onEnd: { [weak self] in self?.drained.signal() })
        Self.readLines(errors.fileHandleForReading, onLine: { line in
            if line.hasPrefix("speech:") { NSLog("%@", line) }
        }, onEnd: {})
        do {
            try process.run()
        } catch {
            drained.signal()
            onEvent?(.failed("speech.cpp を起動できません（\(error.localizedDescription)）"))
            return
        }
        writer.sync {
            self.process = process
            self.input = input.fileHandleForWriting
        }
    }

    /// 16 kHz・16 bit・モノラルの音を渡す。どのスレッドから呼んでもよい。
    /// speech.cpp の準備（初回は十数秒かかることがある）が済む前の音も、ここで順に待たせておくので落ちない。
    func append(_ pcm: Data) {
        statsLock.withLock { stats.pendingBytes += pcm.count }
        writer.async { [self] in
            defer { statsLock.withLock { stats.pendingBytes -= pcm.count } }
            guard let input else {
                statsLock.withLock { stats.droppedBytes += pcm.count }
                return
            }
            do {
                try input.write(contentsOf: pcm)
            } catch {
                self.input = nil  // speech が先に終わった。terminationHandler が知らせる
            }
        }
    }

    /// 音を流し終える。残りの発言が確定するまで待つ（長くても timeout 秒）。
    func finish(timeout: TimeInterval = 30) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.async { [self] in
                finishing = true
                try? input?.close()  // 入力の終わりを知らせると、speech は残りを書いて終わる
                input = nil
                let process = process
                DispatchQueue.global().async { [self] in
                    if process != nil, drained.wait(timeout: .now() + timeout) == .timedOut {
                        process?.terminate()
                    }
                    continuation.resume()
                }
            }
        }
    }

    /// すぐに止める（結果は待たない）。
    func cancel() {
        writer.sync {
            finishing = true
            try? input?.close()
            input = nil
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
    }

    /// speech.cpp が書く1行（OpenAI の Realtime API と同じ形）を解釈する。扱わない種類は nil。
    static func parse(_ line: String) -> TranscriberEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let id = json["item_id"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            return .started(id: id, ms: json["audio_start_ms"] as? Int ?? 0)
        case "conversation.item.input_audio_transcription.delta":
            return .delta(id: id, text: json["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(id: id, text: json["transcript"] as? String ?? "")
        default:
            return nil  // 1つの発言を認識できなかっただけ（.failed）なら、続ける
        }
    }

    private static func readLines(_ handle: FileHandle, onLine: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        DispatchQueue.global().async {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { onLine(line) }
                }
            }
            onEnd()
        }
    }
}
