import AppKit

/// 推敲に使うモデル。ファイルは setup.sh が models/ に置く。
enum RewriteModel: String, CaseIterable {
    case e2b = "gemma-4-E2B-it-Q4_K_M.gguf"
    case e4b = "gemma-4-E4B-it-Q4_K_M.gguf"

    var label: String {
        switch self {
        case .e2b: "Gemma 4 E2B（軽い・速い）"
        case .e4b: "Gemma 4 E4B（丁寧・やや重い）"
        }
    }

    static let settingKey = "rewriteModel"
    static var current: RewriteModel {
        get { UserDefaults.standard.string(forKey: settingKey).flatMap(RewriteModel.init) ?? .e4b }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: settingKey) }
    }
}

/// 推敲の頼み方（プロンプト）と、返ってきた文の後始末。ここは純粋な関数だけにしてテストする。
enum RewritePrompt {
    static let system = """
    あなたは日本語の文章を推敲する編集者です。ユーザーが渡すのは、メモ帳に書き殴った下書きです。
    次を守って、推敲した本文だけを返してください。
    - 書き手の言いたいことと事実は変えない。情報を足さない。削るのは重複だけ。
    - 誤字脱字、ねじれた文、わかりにくい語順を直し、読みやすい日本語にする。
    - 文体（だ・である／です・ます）は下書きの多い方にそろえる。
    - Markdown の記号（見出しの #、箇条書きの -、チェックボックス、リンク、コード）はそのまま残す。
    - 前置き、説明、感想、コードブロックでの囲みは書かない。推敲後の本文だけを出す。
    """

    static func requestBody(for draft: String, stream: Bool = true) -> [String: Any] {
        LLMServer.requestBody(system: system, user: draft, stream: stream)
    }

    /// 返ってきた文を、元の文と差し替えられる形にする。
    /// 全体を ``` で囲んできたら外す。前後の空白は元の文に合わせる。
    static func clean(_ output: String, original: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), !original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if !lines.isEmpty { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leading = String(original.prefix { $0.isWhitespace || $0.isNewline })
        let trailing = String(original.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return leading + text + trailing
    }
}

/// llama-server を、使うときだけ起動する。しばらく使わなければ止め、メモリを返す。
@MainActor
final class LLMServer {
    enum Failure: LocalizedError {
        case missing(String)
        case startFailed(String)
        case tooLong
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missing(let what): "\(what) がありません。ターミナルで ./scripts/setup.sh を実行してください。"
            case .startFailed(let why): "モデルを起動できませんでした（\(why)）"
            case .tooLong: "一度に推敲するには長すぎます。範囲を選んでから ⌘J を押してください。"
            case .server(let why): "モデルが答えられませんでした（\(why)）"
            }
        }
    }

    /// llama-server に渡す頼みの形。
    nonisolated static func requestBody(system: String, user: String, stream: Bool = true) -> [String: Any] {
        [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
            "stream": stream,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
    }

    /// 最後に使ってから止めるまで。
    static let idleLimit: TimeInterval = 5 * 60
    /// モデルに渡せる長さ（トークン）。推敲は入力と同じくらい書くので、下書きはこの半分弱まで。
    static let contextTokens = 16384
    /// 一度に推敲する下書きの上限（文字）。日本語はおおむね1文字1トークン強なので、余裕を見てこのくらい。
    static let maxDraftCharacters = 5000

    private var process: Process?
    private var port: Int = 0
    private var model: RewriteModel?
    private var idleTimer: Timer?
    /// health が ok を返した後だけ true（起動途中に次の推敲が来ても、待たずに投げないように）。
    private var ready = false
    private var starting: Task<URL, Error>?

    private let home: URL
    private var serverURL: URL { home.appendingPathComponent("vendor/llama/llama-server") }
    private func modelURL(_ model: RewriteModel) -> URL { home.appendingPathComponent("models").appendingPathComponent(model.rawValue) }

    /// 落ちたときに残ったサーバーを、次に起動したとき片付けるための記録。
    private var pidFile: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.haruka.mogu")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches.appendingPathComponent("llama-server.pid")
    }

    init(home: URL) {
        self.home = home
        killOrphan()
    }

    static func locateHome() -> URL {
        let path = Bundle.main.object(forInfoDictionaryKey: "MoguHome") as? String ?? ""
        return URL(fileURLWithPath: path.isEmpty || path.hasPrefix("__") ? FileManager.default.currentDirectoryPath : path)
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: serverURL.path)
            && FileManager.default.fileExists(atPath: modelURL(RewriteModel.current).path)
    }

    /// 起動していなければ起動し、受け付けられるまで待つ。返すのは API の入口。
    func endpoint() async throws -> URL {
        let wanted = RewriteModel.current
        if let process, process.isRunning, model == wanted, ready {
            touch()
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        if let starting, model == wanted {
            return try await starting.value  // 起動の途中なら、その完了を待つ
        }
        stop()
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else { throw Failure.missing("llama.cpp") }
        guard FileManager.default.fileExists(atPath: modelURL(wanted).path) else { throw Failure.missing(wanted.rawValue) }

        port = Self.freePort()
        let task = Process()
        task.executableURL = serverURL
        task.arguments = ["-m", modelURL(wanted).path, "--host", "127.0.0.1", "--port", "\(port)",
                          "-c", "\(Self.contextTokens)", "-ngl", "99", "--jinja", "--parallel", "1", "--no-webui"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw Failure.startFailed(error.localizedDescription)
        }
        process = task
        model = wanted
        try? "\(task.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let waiting = Task<URL, Error> {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                guard task.isRunning else { throw Failure.startFailed("llama-server が終了しました") }
                if let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("health")),
                   String(decoding: data, as: UTF8.self).contains("ok") {
                    return base
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            throw Failure.startFailed("時間内に応答がありませんでした")
        }
        starting = waiting
        do {
            let url = try await waiting.value
            starting = nil
            guard process === task else { throw Failure.startFailed("途中で止められました") }
            ready = true
            touch()
            return url
        } catch {
            starting = nil
            if process === task { stop() }
            throw error
        }
    }

    /// 推敲した文を少しずつ返す。
    /// onPartial はこのメインスレッドの上で、そのまま呼ぶ。
    func rewrite(_ draft: String, onPartial: @MainActor (String) -> Void) async throws -> String {
        guard draft.count <= Self.maxDraftCharacters else { throw Failure.tooLong }
        return try await chat(RewritePrompt.requestBody(for: draft), onPartial: onPartial)
    }

    /// モデルに頼み、答えを少しずつ返す（推敲と議事録の要約で使う）。body は llama-server の chat/completions の形。
    func chat(_ body: [String: Any], onPartial: @MainActor (String) -> Void = { _ in }) async throws -> String {
        let base = try await endpoint()
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw body.contains("context") || body.contains("exceed") ? Failure.tooLong : Failure.server("HTTP \(status)")
        }
        var output = ""
        var finish: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finish = reason }
            if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String {
                output += piece
                onPartial(output)
            }
        }
        touch()
        // 最後まで書き切ったときだけ使う（長さの上限で切れた文を、完成したものとして見せない）
        switch finish {
        case "stop": return output
        case "length": throw Failure.tooLong
        default: throw Failure.server("答えが途中で途切れました")
        }
    }

    func stop() {
        idleTimer?.invalidate()
        starting?.cancel()
        starting = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        model = nil
        ready = false
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// 前回アプリが落ちて、サーバーだけが残っていたら止める。
    private func killOrphan() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("llama-server") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// 空いている番号を OS に選ばせる。
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port == 0 ? 18411 : port
    }
}
