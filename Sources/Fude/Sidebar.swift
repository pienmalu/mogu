import SwiftUI

/// 左の一覧。上に検索、下にノートの列。
struct Sidebar: View {
    @ObservedObject var store: NoteStore
    let onNew: () -> Void
    let onOpenFirst: () -> Void
    let onChooseFolder: () -> Void
    let onTrash: (URL) -> Void
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11, weight: .medium))
                    TextField("検索", text: $store.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($searching)
                        .onSubmit(onOpenFirst)
                        .onExitCommand { store.query = ""; searching = false }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新しいメモ（⌘N）")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 6)

            List(selection: $store.selection) {
                ForEach(store.visible) { note in
                    NoteRow(note: note)
                        .tag(note.url)
                        .contextMenu {
                            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                            Divider()
                            Button("ゴミ箱に入れる") { onTrash(note.url) }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.visible.isEmpty {
                    Text(store.query.isEmpty ? "メモはまだありません" : "見つかりません")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: onChooseFolder) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(store.folder.lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Text("\(store.notes.count)")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("保存先を変える：\(store.folder.path)")
        }
        .onReceive(store.focusSearch) { searching = true }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.dateText(note.modified))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(note.snippet)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
        }
        .padding(.vertical, 3)
    }

    /// 今日なら時刻、今年なら月日、それより前は年月日。
    static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }
}
