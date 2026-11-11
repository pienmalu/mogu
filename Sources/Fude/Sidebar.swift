import SwiftUI

/// 左の一覧。上に検索、下に日付でまとめたノート。
/// 選択の色はシステムの強調色ではなく、紙と墨の色にする（朱はカーソルと赤字のためにとっておく）。
/// キーボード：検索欄で ↑↓ で選び、Enter で本文へ。Esc で検索を消す。
struct Sidebar: View {
    @ObservedObject var store: NoteStore
    let onNew: () -> Void
    let onOpenFirst: () -> Void
    let onChooseFolder: () -> Void
    let onTrash: (URL) -> Void
    @FocusState private var searching: Bool

    private let theme = Theme.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(NoteStore.sections(store.visible, now: Date()), id: \.title) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: theme.inkSecondary))
                                .padding(.horizontal, 10)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            ForEach(section.notes) { note in
                                NoteRow(note: note, selected: store.selection == note.url, today: section.isToday)
                                    .id(note.url)
                                    .onTapGesture { store.selection = note.url }
                                    .contextMenu {
                                        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                                        Divider()
                                        Button("ゴミ箱に入れる") { onTrash(note.url) }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .onChange(of: store.selection) { _, url in
                    if let url { proxy.scrollTo(url) }
                }
            }
            .overlay { emptyState }
            footer
        }
        .onReceive(store.focusSearch) { searching = true }
    }

    // MARK: - 部品

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.inkFaint))
                TextField("探す", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searching)
                    .onSubmit(onOpenFirst)
                    .onExitCommand { store.query = ""; searching = false }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if !store.query.isEmpty {
                    Button { store.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: theme.inkFaint))
                    }
                    .buttonStyle(.plain)
                    .help("検索を消す（Esc）")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: theme.wash)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: searching ? theme.rule : .clear), lineWidth: 1))

            Button(action: onNew) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: theme.inkSecondary))
            .help("新しいメモ（⌘N）")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var emptyState: some View {
        if store.visible.isEmpty {
            VStack(spacing: 6) {
                if store.query.isEmpty {
                    Text("まだメモはありません")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(nsColor: theme.ink))
                    Text("\(GlobalHotKey.defaultLabel) でいつでも書けます")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: theme.inkSecondary))
                        .fixedSize()
                } else {
                    Text("「\(store.query)」を含むメモはありません")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(nsColor: theme.inkSecondary))
                        .multilineTextAlignment(.center)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
    }

    private var footer: some View {
        Button(action: onChooseFolder) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(store.folder.lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Text("\(store.notes.count)件")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: theme.inkSecondary))
            .padding(.horizontal, 20)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("保存先を変える（いま：\(store.folder.path)）")
    }

    /// 検索欄から ↑↓ で選ぶ。
    private func move(_ step: Int) {
        let list = store.visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.url == store.selection }
        let next = current.map { max(0, min(list.count - 1, $0 + step)) } ?? (step > 0 ? 0 : list.count - 1)
        store.selection = list[next].url
    }
}

private struct NoteRow: View {
    let note: NoteSummary
    let selected: Bool
    let today: Bool
    @State private var hovering = false

    private let theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: theme.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.dateText(note.modified, today: today))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: theme.inkSecondary))
            }
            if !note.snippet.isEmpty {
                Text(note.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: theme.inkSecondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: selected ? theme.selectedRow : hovering ? theme.wash : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// 今日のまとまりでは時刻、ほかは月日（去年より前なら年も）。
    static func dateText(_ date: Date, today: Bool) -> String {
        if today { return date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }
}
