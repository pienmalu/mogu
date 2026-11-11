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
        phase = .starting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await server.rewrite(original) { [weak self] partial in
                    Task { @MainActor in
                        guard let self, !Task.isCancelled else { return }
                        self.phase = .writing
                        self.result = partial
                    }
                }
                guard !Task.isCancelled else { return }
                result = RewritePrompt.clean(output, original: original)
                phase = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failed("空の答えが返ってきました") : .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct RewriteSheet: View {
    @ObservedObject var session: RewriteSession
    let onAccept: (String) -> Void
    let onClose: () -> Void
    @State private var showOriginal = false

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
                Text(showOriginal ? session.original : (session.result.isEmpty ? " " : session.result))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(showOriginal ? .secondary : .primary)
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
                Toggle("元の文", isOn: $showOriginal)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
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
