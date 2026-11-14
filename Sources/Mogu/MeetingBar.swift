import SwiftUI

/// 本文の下に浮かぶ、議事録の小さなバー。録っている間だけ出る。
struct MeetingBar: View {
    @ObservedObject var session: MeetingSession
    let onStop: () -> Void
    let onCancelSummary: () -> Void
    let onInsert: () -> Void

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                EmptyView()
            case .recording:
                capsule { recording }
            case .finishing:
                capsule { working("残りを文字にしています") }
            case .summarizing(let step):
                capsule {
                    working(step)
                    iconButton("xmark", help: "要約をやめる（文字起こしは残ります）", action: onCancelSummary)
                }
            case .ready:
                capsule {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text("要約ができました")
                    Button("ノートに入れる", action: onInsert)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 4)
                }
            case .notice(let message):
                capsule { Text(message).foregroundStyle(.secondary) }
            }
        }
        .font(.system(size: 12))
        .padding(.bottom, 18)
        .padding(.horizontal, 20)  // 影が切れないように
        .padding(.top, 12)
        .animation(.snappy(duration: 0.28), value: session.phase)
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 36)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var recording: some View {
        RecordingDot()
        if let started = session.started {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(MeetingTranscript.clock(context.date.timeIntervalSince(started)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        LevelBars(levels: session.levels)
        Text(session.caption.isEmpty ? "聞いています" : session.caption)
            .foregroundStyle(session.caption.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
            .truncationMode(.head)  // 長い文は、いま話している終わりの方を見せる
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: session.caption.count < 24, vertical: false)
        Button(action: onStop) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).frame(width: 7, height: 7)
                Text("終える")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("議事録を終える（⌘R）")
    }

    @ViewBuilder private func working(_ text: String) -> some View {
        ProgressView().controlSize(.small).scaleEffect(0.8)
        Text(text).foregroundStyle(.secondary).padding(.trailing, 6)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 録っているしるし。ゆっくり明滅する赤い点。
private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// 音の大きさ。声が入っていることが、ひと目でわかるように。
private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: 3 + CGFloat(level) * 11)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.12), value: levels)
    }
}
