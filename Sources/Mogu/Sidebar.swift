import SwiftUI

/// 左の一覧。上に3つの操作（探す、新しいメモ、議事録）、下に日付ごとのノート。
struct Sidebar: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var meeting: MeetingSession
    let onSearch: () -> Void
    let onNew: () -> Void
    let onMeeting: () -> Void
    let onChooseFolder: () -> Void
    let onTrash: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                ActionRow(symbol: "magnifyingglass", title: "探す", shortcut: "⌘P", action: onSearch)
                ActionRow(symbol: "square.and.pencil", title: "新しいメモ", shortcut: "⌘N", action: onNew)
                ActionRow(symbol: meeting.isRecording ? "stop.circle.fill" : "waveform",
                          title: meeting.isRecording ? "議事録を終える" : "議事録",
                          shortcut: "⌘R", tint: meeting.isRecording ? .red : nil, action: onMeeting)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)

            List(selection: $store.selection) {
                ForEach(NoteDate.sections(store.notes), id: \.title) { section in
                    Section {
                        ForEach(section.notes) { note in
                            NoteRow(note: note)
                                .tag(note.url)
                                .contextMenu {
                                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                                    Divider()
                                    Button("ゴミ箱に入れる") { onTrash(note.url) }
                                }
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 28)
            .overlay {
                if store.notes.isEmpty {
                    Text("メモはまだありません")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: onChooseFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(store.folder.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(store.notes.count)")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("保存先を変える：\(store.folder.path)")
        }
    }
}

/// 一覧の上の操作。マウスを乗せると、下地とショートカットが出る。
private struct ActionRow: View {
    let symbol: String
    let title: String
    let shortcut: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? .primary.opacity(0.85))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        HStack(spacing: 8) {
            Text(note.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(NoteDate.short(note.modified))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}
