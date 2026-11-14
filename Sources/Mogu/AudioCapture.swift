import AVFoundation
import AudioToolbox
import CoreAudio

/// 議事録のための音の取り口。マイク（自分の声）と、Mac から出る音（オンライン会議の相手の声）。
/// どちらも speech.cpp に渡す形（16 kHz・16 bit・モノラル）にして渡す。音は Mac の外に出ない。
protocol AudioSource: AnyObject {
    /// 変換した音と、その大きさ（0〜1）。音のスレッドから呼ばれる。
    var onAudio: ((Data, Float) -> Void)? { get set }
    func start() throws
    func stop()
}

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 続けて届く音を 16 kHz・16 bit・モノラルに変える（変換の途中の状態を、次の音へ引き継ぐ）。
final class Resampler {
    static let sampleRate = 16000
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                      channels: 1, interleaved: true)!

    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from source: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: Self.format) else { return nil }
        converter.downmix = true  // 2 ch 以上なら、片方を捨てずに混ぜる
        inputFormat = source
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Float)? {
        let ratio = Self.format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard buffer.frameLength > 0,
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handedOver {
                status.pointee = .noDataNow  // 次の音が来るまで待つ
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        let count = Int(output.frameLength)
        return (Data(bytes: samples, count: count * MemoryLayout<Int16>.size), Self.level(samples, count))
    }

    /// 音の大きさ。RMS を dB にし、-55〜-10 dB を 0〜1 に割り当てる。
    static func level(_ samples: UnsafePointer<Int16>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / Float(Int16.max)
            sum += s * s
        }
        let decibels = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
        return min(max((decibels + 55) / 45, 0), 1)
    }
}

/// マイク。差し替え（AirPods をつないだ、など）があったら、新しい入力で録り直す。
final class MicCapture: AudioSource {
    var onAudio: ((Data, Float) -> Void)?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw AudioFailure(message: "マイクが見つかりません") }
        guard let resampler = Resampler(from: source) else { throw AudioFailure(message: "マイクの音を変換できません") }
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            guard let (pcm, level) = resampler.convert(buffer) else { return }
            self?.onAudio?(pcm, level)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioFailure(message: "マイクを使えません（\(error.localizedDescription)）")
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            try? self?.start()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    deinit { stop() }
}

/// Mac から出る音。Core Audio の process tap で取る（macOS 14.2 以降。初回は「システム音声の録音」の許可を求められる）。
/// 出力先を変えたら（スピーカーからイヤホンへ、など）、取り直す。
@available(macOS 14.2, *)
final class SystemAudioCapture: AudioSource {
    var onAudio: ((Data, Float) -> Void)?

    private let queue = DispatchQueue(label: "mogu.system-audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private static var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        stop()
        try createTap()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardownTap()
            do { try self.createTap() } catch { NSLog("Mac の音を取り直せませんでした: \(error.localizedDescription)") }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, .main, listener) == noErr {
            outputListener = listener
        }
    }

    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, .main, outputListener)
        }
        outputListener = nil
        teardownTap()
    }

    deinit { stop() }

    private func createTap() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check("tap の作成", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        try getProperty(tapID, kAudioTapPropertyFormat, &format, step: "tap の形式")
        guard let inputFormat = AVAudioFormat(streamDescription: &format), let resampler = Resampler(from: inputFormat) else {
            throw AudioFailure(message: "Mac の音を変換できません")
        }
        self.resampler = resampler

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mogu Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("集約デバイスの作成", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
        try check("IOProc の作成", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let resampler = self.resampler,
                  let buffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, bufferListNoCopy: input, deallocator: nil),
                  let (pcm, level) = resampler.convert(buffer) else { return }
            self.onAudio?(pcm, level)
        })
        try check("音の開始", AudioDeviceStart(aggregateID, procID))
    }

    private func teardownTap() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync { resampler = nil }  // IOProc は止めたあとなので、音のスレッドとぶつからない
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &deviceID, step: "出力先")
        var uid: Unmanaged<CFString>?
        try getProperty(deviceID, kAudioDevicePropertyDeviceUID, &uid, step: "出力先の名前")
        guard let uid else { throw AudioFailure(message: "音の出力先がわかりません") }
        return uid.takeRetainedValue() as String
    }

    private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T, step: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        try check(step, status)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw AudioFailure(message: "Mac の音を取れません（\(step): \(status)）") }
    }
}
