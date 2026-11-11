import AppKit

/// アプリと同じ経路（LLMServer）で推敲を試す。使い方: ./tools/try-rewrite.sh [e2b|e4b] < 下書き.txt
@main
enum TryRewriteMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("e4b") { RewriteModel.current = .e4b } else { RewriteModel.current = .e2b }
        let draft = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let server = LLMServer(home: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let start = Date()
        var first: TimeInterval?
        do {
            let output = try await server.rewrite(draft) { _ in
                if first == nil { first = Date().timeIntervalSince(start) }
            }
            let total = Date().timeIntervalSince(start)
            print(RewritePrompt.clean(output, original: draft))
            FileHandle.standardError.write(Data(String(format: "[%@] 最初の文字まで %.1f 秒・全体 %.1f 秒\n",
                                                       RewriteModel.current == .e2b ? "E2B" : "E4B", first ?? 0, total).utf8))
        } catch {
            FileHandle.standardError.write(Data("失敗: \(error.localizedDescription)\n".utf8))
        }
        server.stop()
    }
}
