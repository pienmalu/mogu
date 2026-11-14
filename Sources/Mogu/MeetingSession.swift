import AVFoundation
import Combine
import Foundation

/// 会議1回分。音を録り、文字にし、確定した発言をためる。画面（MeetingBar）はこれを見る。
@MainActor
final class MeetingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        /// 止めたあと、残りの発言が確定するのを待っている。
        case finishing
        /// 要約を作っている（中身は、いま何をしているか）。
        case summarizing(String)
        /// 要約はできたが、ノートが開かれていないので、入れるのを待っている。
        case ready
        /// 少しの間だけ出す知らせ。
        case notice(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var started: Date?
    /// 直近の音の大きさ（0〜1）。右が新しい。
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: MeetingSession.levelCount)
    /// いま聞こえている文。
    @Published private(set) var caption = ""

    static let levelCount = 5

    /// 議事録を書き込むノート。
    var noteURL: URL?
    /// できあがって、ノートに入れるのを待っている要約。
    var pendingSummary: String?
    private(set) var utterances: [Utterance] = []

    private let files: SpeechFiles
    private let journal: MeetingJournal
    private var audio: MeetingAudio?
    private var levelTimer: Timer?
    private var noticeTimer: Timer?

    init(files: SpeechFiles, journal: MeetingJournal = .standard) {
        self.files = files
        self.journal = journal
    }

    var isRecording: Bool { phase == .recording }
    /// 新しい会議を始められるか（前の会議の後始末が済んでいるか）。
    var isBusy: Bool {
        switch phase {
        case .idle, .notice: false
        default: true
        }
    }

    func start(noteURL: URL?) throws {
        let now = Date()
        let audio = MeetingAudio(files: files, started: now)
        audio.onUtterance = { [weak self] utterance in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.add(utterance) } }
        }
        audio.onCaption = { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.caption = text } }
        }
        audio.onFailure = { [weak self] message in
            NSLog("議事録: %@", message)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.caption = message } }
        }
        try audio.start()
        self.audio = audio
        self.noteURL = noteURL
        utterances = []
        pendingSummary = nil
        caption = ""
        started = now
        journal.begin(started: now)
        noticeTimer?.invalidate()
        phase = .recording
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let audio = self.audio else { return }
                self.levels = Array(self.levels.dropFirst()) + [audio.takeLevel()]
            }
        }
    }

    /// 録るのをやめ、残りの発言が確定するのを待って、全部の発言を返す。
    func stop() async -> [Utterance] {
        guard phase == .recording, let audio else { return utterances }
        phase = .finishing
        levelTimer?.invalidate()
        levels = Array(repeating: 0, count: Self.levelCount)
        await audio.finish()
        // 最後の発言は、読み取りのスレッドからメインへ渡される途中かもしれない。1拍おいて受け取る。
        try? await Task.sleep(nanoseconds: 50_000_000)
        self.audio = nil
        caption = ""
        return utterances
    }

    /// ノートに書き終えたら呼ぶ（落ちたときのための控えを消す）。
    func transcriptSaved() {
        journal.finish()
    }

    func finish() {
        started = nil
        phase = .idle
    }

    /// 知らせを数秒だけ出して、消す。
    func notify(_ message: String) {
        started = nil
        phase = .notice(message)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .notice = self.phase else { return }
                self.phase = .idle
            }
        }
    }

    /// 見た目の確認用（tools/Render.swift）。録らずに、画面に出す状態だけを作る。
    func preview(_ phase: Phase, elapsed: TimeInterval = 0, levels: [Float] = [], caption: String = "") {
        started = Date().addingTimeInterval(-elapsed)
        self.levels = levels.isEmpty ? self.levels : levels
        self.caption = caption
        self.phase = phase
    }

    private func add(_ utterance: Utterance) {
        utterances.append(utterance)
        journal.append(utterance)
    }

    static func askForMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

/// 音の取り口と文字起こしをつなぐ。音のスレッドと読み取りのスレッドから使うので、状態は lock で守る。
///
/// - マイクの音は、始めたときから文字にする（自分）。
/// - Mac から出る音は、初めて聞こえたときに、もう1つの文字起こしを始める（相手）。対面の会議では動かさない。
/// - スピーカーから出た相手の声をマイクが拾うと、同じ発言が2回書かれる。
///   そのため、Mac から音が出ている間は、マイクの音を無音に替える。
final class MeetingAudio: @unchecked Sendable {
    var onUtterance: ((Utterance) -> Void)?
    var onCaption: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Mac から出る音が、この大きさ（0〜1）を超えたら「相手が話している」とみなす。
    static let otherThreshold: Float = 0.2
    /// 相手の声が止んでから、マイクを戻すまで（秒）。部屋の響きを拾わないように少し待つ。
    static let otherHold: TimeInterval = 0.35
    /// 相手の文字起こしを始めるとき、さかのぼって渡す音の長さ（秒）。言い始めを落とさないように。
    static let preroll: TimeInterval = 1

    private let files: SpeechFiles
    private let started: Date
    private let lock = NSLock()
    private let mic = MicCapture()
    private var system: AudioSource?
    private let me: Transcriber
    private var other: Transcriber?
    private var otherOffset: TimeInterval = 0
    private var otherActiveUntil = Date.distantPast
    private var recent = Data()
    private var peak: Float = 0
    /// 発言ごとの、話し始めの時刻と、途中までの文字。
    private var starts: [String: TimeInterval] = [:]
    private var partial: [String: String] = [:]

    init(files: SpeechFiles, started: Date) {
        self.files = files
        self.started = started
        me = Transcriber(files: files)
    }

    func start() throws {
        me.onEvent = { [weak self] in self?.handle($0, speaker: .me, offset: 0) }
        me.start()
        mic.onAudio = { [weak self] pcm, level in self?.fromMic(pcm, level) }
        do {
            try mic.start()
        } catch {
            me.cancel()  // 先に起動した文字起こしを残さない
            throw error
        }
        if #available(macOS 14.2, *) {
            let system = SystemAudioCapture()
            system.onAudio = { [weak self] pcm, level in self?.fromSystem(pcm, level) }
            do {
                try system.start()
                self.system = system
            } catch {
                onFailure?(error.localizedDescription)  // 取れなくても、マイクだけで続ける
            }
        }
    }

    /// 音を止め、残りの発言が確定するまで待つ。
    func finish() async {
        mic.stop()
        system?.stop()
        let other = lock.withLock { self.other }
        async let first: Void = me.finish()
        async let second: Void = other?.finish() ?? ()
        _ = await (first, second)
    }

    /// 前に呼んでからの、いちばん大きかった音（0〜1）。
    func takeLevel() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    private func fromMic(_ pcm: Data, _ level: Float) {
        let muted = lock.withLock {
            let muted = Date() < otherActiveUntil
            if !muted { peak = max(peak, level) }
            return muted
        }
        me.append(muted ? Data(count: pcm.count) : pcm)
    }

    private func fromSystem(_ pcm: Data, _ level: Float) {
        let audible = level > Self.otherThreshold
        let (transcriber, backlog): (Transcriber?, Data?) = lock.withLock {
            peak = max(peak, level)
            if audible { otherActiveUntil = Date().addingTimeInterval(Self.otherHold) }
            if let other { return (other, nil) }
            // まだ始めていない間は、直近の音だけ取っておく
            recent.append(pcm)
            let keep = Int(Self.preroll * Double(Resampler.sampleRate)) * 2
            if recent.count > keep { recent.removeFirst(recent.count - keep) }
            guard audible else { return (nil, nil) }
            let transcriber = Transcriber(files: files)
            other = transcriber
            otherOffset = max(0, Date().timeIntervalSince(started) - Double(recent.count / 2) / Double(Resampler.sampleRate))
            defer { recent = Data() }
            return (transcriber, recent)
        }
        guard let transcriber else { return }
        if let backlog {
            let offset = lock.withLock { otherOffset }
            transcriber.onEvent = { [weak self] in self?.handle($0, speaker: .other, offset: offset) }
            transcriber.start()
            transcriber.append(backlog)
        } else {
            transcriber.append(pcm)
        }
    }

    private func handle(_ event: TranscriberEvent, speaker: Speaker, offset: TimeInterval) {
        switch event {
        case .started(let id, let ms):
            lock.withLock { starts[id] = offset + Double(ms) / 1000 }
        case .delta(let id, let text):
            let soFar = lock.withLock {
                partial[id, default: ""] += text
                return partial[id] ?? ""
            }
            onCaption?(soFar)
        case .completed(let id, let text):
            let start = lock.withLock {
                partial[id] = nil
                return starts.removeValue(forKey: id) ?? Date().timeIntervalSince(started)
            }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onCaption?(text)
            onUtterance?(Utterance(start: start, speaker: speaker, text: text))
        case .failed(let message):
            onFailure?(message)
        }
    }
}
