import SwiftUI

/// 推敲1回分。結果は勝手に本文へ入れず、シートで見せてから置き換える。
@MainActor
final class RewriteSession: ObservableObject {
    enum Phase: Equatable {
        case starting, writing, done
        case failed(String)
    }

    @Published var phase: Phase = .starting
    @Published var result = ""
    /// 書き終えたあとの赤字（元の文との違い）。
    @Published var pieces: [Proofread.Piece] = []
    let original: String
    private let server: LLMServer
    private var task: Task<Void, Never>?

    init(original: String, server: LLMServer) {
        self.original = original
        self.server = server
    }

    func start() {
        task?.cancel()
        result = ""
        pieces = []
        phase = .starting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // 途中経過はこのタスクの中で同期的に届く。止めた後や完了後には何もしない
                let output = try await server.rewrite(original) { [weak self] partial in
                    guard let self, !Task.isCancelled else { return }
                    self.phase = .writing
                    self.result = partial
                }
                guard !Task.isCancelled else { return }
                let cleaned = RewritePrompt.clean(output, original: original)
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    phase = .failed("答えが空でした。もう一度試してください。")
                    return
                }
                let original = self.original
                let marks = await Task.detached(priority: .userInitiated) { Proofread.diff(original, cleaned) }.value
                guard !Task.isCancelled else { return }
                result = cleaned
                pieces = marks
                phase = .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// 推敲の結果を見せる。「変更点」は元の文との違い（削った字に取り消し線、足した字に下線）、「結果」は直した後の文だけ。
struct RewriteSheet: View {
    enum Mode: Hashable { case changes, result }

    @ObservedObject var session: RewriteSession
    let onAccept: (String) -> Void
    let onClose: () -> Void
    @State private var mode: Mode = .changes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("推敲")
                    .font(.system(size: 13, weight: .semibold))
                Text(RewriteModel.current == .e2b ? "E2B" : "E4B")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                status
            }

            ScrollView {
                content
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 140, maxHeight: 420)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            if case .failed(let message) = session.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    Text("変更点").tag(Mode.changes)
                    Text("結果").tag(Mode.result)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(session.phase != .done)
                Spacer()
                Button("やめる") {
                    session.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("もう一度") { session.start() }
                    .disabled(session.phase == .starting || session.phase == .writing)
                Button("置き換える") { onAccept(session.result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.phase != .done)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    @ViewBuilder private var content: some View {
        if session.phase == .done, mode == .changes {
            Text(changes)
        } else {
            Text(session.result.isEmpty ? " " : session.result)
        }
    }

    /// 元の文との違い。削った字は取り消し線、足した字は下線（色だけに頼らない）。
    private var changes: AttributedString {
        var text = AttributedString()
        for piece in session.pieces {
            switch piece {
            case .same(let s):
                text += AttributedString(s)
            case .deleted(let s):
                var part = AttributedString(s)
                part.foregroundColor = .secondary
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .red)
                text += part
            case .inserted(let s):
                var part = AttributedString(s)
                part.foregroundColor = .accentColor
                part.underlineStyle = Text.LineStyle(pattern: .solid, color: .accentColor)
                text += part
            }
        }
        return text
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .starting:
            Label { Text("モデルを起動中…") } icon: { ProgressView().controlSize(.small) }
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .writing:
            Label { Text("書いています…") } icon: { ProgressView().controlSize(.small) }
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .done:
            Text("⏎ で置き換え・⌘Z で戻せます")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        case .failed:
            EmptyView()
        }
    }
}
