import AppKit
import SwiftUI

/// ⌘P で出す、ノートを探す窓。打った言葉をすべて含むノートを、新しい順に並べる。
@MainActor
final class QuickOpenModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case note(URL)
            /// 見つからなかったとき、その言葉で新しいメモを作る。
            case create(String)
        }

        let kind: Kind
        let title: String
        let detail: String
        let date: String
        var id: String {
            switch kind {
            case .note(let url): url.path
            case .create: "create"
            }
        }
    }

    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var rows: [Row] = []
    @Published var selected = 0

    static let maxRows = 7
    private var notes: [NoteSummary] = []

    func reset(notes: [NoteSummary]) {
        self.notes = notes
        query = ""
    }

    private func refresh() {
        rows = Self.search(notes, query: query)
        selected = 0
    }

    /// 言葉（空白区切り）をすべて含むノート。題に含むものを先に。言葉がなければ、最近のノート。
    static func search(_ notes: [NoteSummary], query: String) -> [Row] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return notes.prefix(maxRows).map { row($0, words: []) }
        }
        let hits = notes.filter { note in words.allSatisfy { note.searchText.contains($0) } }
        let inTitle = hits.filter { note in words.allSatisfy { note.title.lowercased().contains($0) } }
        let rest = hits.filter { !inTitle.contains($0) }
        var rows = (inTitle + rest).prefix(maxRows - 1).map { row($0, words: words) }
        let name = query.trimmingCharacters(in: .whitespaces)
        rows.append(Row(kind: .create(name), title: "「\(name)」で新しいメモを作る", detail: "", date: ""))
        return rows
    }

    private static func row(_ note: NoteSummary, words: [String]) -> Row {
        Row(kind: .note(note.url), title: note.title, detail: excerpt(note, words: words), date: NoteDate.short(note.modified))
    }

    /// 言葉が出てくる行。題に出てくるだけなら、ふつうの抜き書き。
    static func excerpt(_ note: NoteSummary, words: [String]) -> String {
        guard let word = words.first(where: { !note.title.lowercased().contains($0) }) else { return note.snippet }
        let text = note.searchText as NSString
        let found = text.range(of: word)
        guard found.location != NSNotFound else { return note.snippet }
        // 探すための文字は小文字にしてあるので、抜き書きも小文字のまま。前後を少し付ける
        let line = text.lineRange(for: found)
        let start = max(line.location, found.location - 16)
        let length = min(NSMaxRange(line) - start, 90)
        let piece = NoteFile.plain(text.substring(with: NSRange(location: start, length: length))).trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > line.location ? "…" : "") + piece
    }
}

@MainActor
final class QuickOpen {
    static let width: CGFloat = 520
    static let fieldHeight: CGFloat = 46
    static let rowHeight: CGFloat = 46

    private let model = QuickOpenModel()
    private var panel: FloatingPanel?
    private var watcher: Any?
    private weak var window: NSWindow?
    private let onOpen: (URL) -> Void
    private let onCreate: (String) -> Void

    init(onOpen: @escaping (URL) -> Void, onCreate: @escaping (String) -> Void) {
        self.onOpen = onOpen
        self.onCreate = onCreate
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(notes: [NoteSummary], over window: NSWindow, query: String = "") {
        if isOpen { return close() }
        self.window = window
        model.reset(notes: notes)
        if !query.isEmpty { model.query = query }
        if panel == nil {
            let panel = FloatingPanel(takesKey: true, content: QuickOpenView(model: model) { [weak self] in self?.choose($0) })
            panel.onKey = { [weak self] in self?.key($0) ?? false }
            panel.onResign = { [weak self] in self?.close() }
            self.panel = panel
        }
        layout()
        watcher = model.$rows.sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
    }

    func close() {
        guard isOpen else { return }
        watcher = nil
        panel?.dismiss()
        window?.makeKey()
    }

    /// 窓の上寄りの中央に置く。高さは、並べる行の数に合わせる。
    private func layout() {
        guard let panel, let window else { return }
        let height = Self.fieldHeight + (model.rows.isEmpty ? 0 : CGFloat(model.rows.count) * Self.rowHeight + 11)
        let frame = window.frame
        let width = min(Self.width, frame.width - 40)
        panel.show(NSRect(x: frame.midX - width / 2, y: frame.maxY - min(120, frame.height * 0.18) - height, width: width, height: height),
                   over: window)
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126:  // ↑
            if !model.rows.isEmpty { model.selected = (model.selected - 1 + model.rows.count) % model.rows.count }
        case 125:  // ↓
            if !model.rows.isEmpty { model.selected = (model.selected + 1) % model.rows.count }
        case 36, 76:  // Enter
            if model.rows.indices.contains(model.selected) { choose(model.rows[model.selected]) }
        case 53:  // Esc
            close()
        default:
            return false
        }
        return true
    }

    private func choose(_ row: QuickOpenModel.Row) {
        close()
        switch row.kind {
        case .note(let url): onOpen(url)
        case .create(let name): onCreate(name)
        }
    }
}

struct QuickOpenView: View {
    @ObservedObject var model: QuickOpenModel
    let onChoose: (QuickOpenModel.Row) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.tertiary)
                TextField("ノートを探す", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .frame(height: QuickOpen.fieldHeight)

            if !model.rows.isEmpty {
                Divider().opacity(0.6)
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row, selected: index == model.selected)
                            .onTapGesture { onChoose(row) }
                            .onHover { if $0 { model.selected = index } }
                    }
                }
                .padding(5)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PanelBorder())
        .onAppear { focused = true }
    }

    @ViewBuilder private func row(_ row: QuickOpenModel.Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if case .create = row.kind {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(row.detail.isEmpty ? " " : row.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(row.date)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: QuickOpen.rowHeight)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// 一覧に出す日付と、日付のまとまり。
enum NoteDate {
    /// 今日なら時刻、今年なら月日、それより前は年月日。
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    /// 一覧の見出し：今日、昨日、過去 7 日間、過去 30 日間、それより前は月ごと。
    static func group(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "今日" }
        if days == 1 { return "昨日" }
        if days <= 7 { return "過去 7 日間" }
        if days <= 30 { return "過去 30 日間" }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let sameYear = parts.year == calendar.component(.year, from: now)
        return sameYear ? "\(parts.month ?? 0)月" : "\(parts.year ?? 0)年\(parts.month ?? 0)月"
    }

    /// 新しい順に並んだノートを、見出しごとに分ける（順番は保つ）。
    static func sections(_ notes: [NoteSummary], now: Date = Date()) -> [(title: String, notes: [NoteSummary])] {
        var result: [(title: String, notes: [NoteSummary])] = []
        for note in notes {
            let title = group(note.modified, now: now)
            if result.last?.title == title {
                result[result.count - 1].notes.append(note)
            } else {
                result.append((title, [note]))
            }
        }
        return result
    }
}
