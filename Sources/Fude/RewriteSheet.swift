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

/// 推敲の結果を「朱入れ」（元の文に赤字を入れた形）と「清書」で見せる。
struct RewriteSheet: View {
    enum Mode: Hashable { case marks, clean }

    @ObservedObject var session: RewriteSession
    let onAccept: (String) -> Void
    let onClose: () -> Void
    @State private var mode: Mode = .marks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let theme = Theme.shared
    private var ink: Color { Color(nsColor: theme.ink) }
    private var secondary: Color { Color(nsColor: theme.inkSecondary) }
    private var shu: Color { Color(nsColor: theme.shu) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                page
                    .font(Font(theme.bodyFont))
                    .lineSpacing(theme.lineHeight - theme.fontSize - 4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .id(session.phase == .done ? "done" : "draft")
                    .transition(.opacity)
            }
            .frame(minHeight: 180, maxHeight: 460)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: theme.paper)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: theme.rule)))
            footer
        }
        .padding(20)
        .frame(width: 620)
        .background(Color(nsColor: theme.wash))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: session.phase)
    }

    // MARK: - 部品

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("推敲")
                .font(Font(theme.headingFont(2)).weight(.heavy))
                .foregroundStyle(ink)
            Text(RewriteModel.current == .e2b ? "Gemma 4 E2B" : "Gemma 4 E4B")
                .font(.system(size: 11))
                .foregroundStyle(secondary)
            Spacer()
            if session.phase == .done {
                Picker("", selection: $mode) {
                    Text("朱入れ").tag(Mode.marks)
                    Text("清書").tag(Mode.clean)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("朱入れ：元の文に赤字を入れて見る　清書：直した後の文だけを見る")
            } else {
                status
            }
        }
    }

    /// 紙の上に出す文。
    @ViewBuilder private var page: some View {
        switch session.phase {
        case .starting, .failed:
            Text(session.original).foregroundStyle(secondary)  // 赤字を待つ下書き
        case .writing:
            Text(session.result).foregroundStyle(ink)
        case .done:
            if mode == .marks {
                Text(marked)
            } else {
                Text(session.result).foregroundStyle(ink)
            }
        }
    }

    /// 赤字：削った字は朱の取り消し線、足した字は朱で下線。色だけに頼らない。
    private var marked: AttributedString {
        var text = AttributedString()
        for piece in session.pieces {
            switch piece {
            case .same(let s):
                var part = AttributedString(s)
                part.foregroundColor = ink
                text += part
            case .deleted(let s):
                var part = AttributedString(s)
                part.foregroundColor = secondary
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: shu)
                text += part
            case .inserted(let s):
                var part = AttributedString(s)
                part.foregroundColor = shu
                part.underlineStyle = Text.LineStyle(pattern: .solid, color: shu)
                text += part
            }
        }
        return text
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            note
            Spacer(minLength: 12)
            Button("やめる") {
                session.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            if session.phase == .done || isFailed {
                Button("もう一度") { session.start() }
            }
            // 主ボタンは墨（システムの強調色にすると、朱の赤字とぶつかる）
            Button("置き換える") { onAccept(session.result) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(ink)
                .disabled(session.phase != .done)
        }
        .controlSize(.large)
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    /// 左下の一言：書き終えたら直した量、失敗したら理由と次の手。
    @ViewBuilder private var note: some View {
        switch session.phase {
        case .done:
            let count = session.pieces.filter { if case .same = $0 { false } else { true } }.count
            Text(count == 0 ? "直すところはありませんでした" : "\(Proofread.changedCount(session.pieces))字を直しました。置き換えても ⌘Z で戻せます")
                .font(.system(size: 11.5))
                .foregroundStyle(secondary)
        case .failed(let message):
            Label { Text(message) } icon: { Image(systemName: "exclamationmark.circle") }
                .font(.system(size: 12))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(session.phase == .starting ? "モデルを起こしています" : "書いています")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(secondary)
    }
}
