import AppKit
import SwiftUI

/// 「/」で出すコマンド。行の種類を変えるか、文字を入れるか、アプリの機能を呼ぶ。
struct SlashCommand: Identifiable, Equatable {
    enum Action: Equatable {
        /// 行の頭の記号を、これに変える（見出し、箇条書きなど）。
        case block(String)
        case code, rule, date, time
        case meeting, rewrite
    }

    let title: String
    let symbol: String
    /// 右に薄く出す、Markdown での書き方。
    let hint: String
    /// 探すときの言葉（ローマ字と英語）。
    let keywords: [String]
    let action: Action
    var id: String { title }

    static let all: [SlashCommand] = [
        SlashCommand(title: "テキスト", symbol: "textformat", hint: "", keywords: ["text", "plain", "tekisuto"], action: .block("")),
        SlashCommand(title: "見出し 1", symbol: "1.square", hint: "#", keywords: ["h1", "heading", "midashi"], action: .block("# ")),
        SlashCommand(title: "見出し 2", symbol: "2.square", hint: "##", keywords: ["h2", "heading", "midashi"], action: .block("## ")),
        SlashCommand(title: "見出し 3", symbol: "3.square", hint: "###", keywords: ["h3", "heading", "midashi"], action: .block("### ")),
        SlashCommand(title: "ToDo", symbol: "checkmark.square", hint: "[]", keywords: ["todo", "task", "check", "yarukoto"], action: .block("- [ ] ")),
        SlashCommand(title: "箇条書き", symbol: "list.bullet", hint: "-", keywords: ["bullet", "list", "kajougaki"], action: .block("- ")),
        SlashCommand(title: "番号つきリスト", symbol: "list.number", hint: "1.", keywords: ["number", "ordered", "bangou"], action: .block("1. ")),
        SlashCommand(title: "引用", symbol: "text.quote", hint: ">", keywords: ["quote", "inyou"], action: .block("> ")),
        SlashCommand(title: "コード", symbol: "curlybraces", hint: "```", keywords: ["code", "ko-do"], action: .code),
        SlashCommand(title: "区切り線", symbol: "minus", hint: "---", keywords: ["divider", "rule", "hr", "kugiri", "sen"], action: .rule),
        SlashCommand(title: "今日の日付", symbol: "calendar", hint: "", keywords: ["date", "today", "hiduke", "kyou"], action: .date),
        SlashCommand(title: "いまの時刻", symbol: "clock", hint: "", keywords: ["time", "now", "jikoku", "ima"], action: .time),
        SlashCommand(title: "議事録を始める", symbol: "waveform", hint: "⌘R", keywords: ["meeting", "record", "gijiroku", "kaigi"], action: .meeting),
        SlashCommand(title: "推敲する", symbol: "sparkles", hint: "⌘J", keywords: ["rewrite", "ai", "suikou", "gemma"], action: .rewrite),
    ]

    /// 打った言葉で絞る。頭が合うものを先に、途中に含むものを後に。
    static func matching(_ query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        let starts = all.filter { c in c.title.lowercased().hasPrefix(q) || c.keywords.contains { $0.hasPrefix(q) } }
        let contains = all.filter { c in !starts.contains(c) && (c.title.lowercased().contains(q) || c.keywords.contains { $0.contains(q) }) }
        return starts + contains
    }

    /// メニューを開く文字。日本語入力のままでも開けるように、全角の「／」と「；」でも開く。
    static let triggers: Set<Character> = ["/", "／", "；"]
}

@MainActor
final class SlashMenuModel: ObservableObject {
    @Published var items: [SlashCommand] = SlashCommand.all
    @Published var selected = 0
}

/// 「/」のメニューの出し入れ。本文のカーソルの下に小さな板を出す（キーの受け手は本文のまま）。
@MainActor
final class SlashMenu {
    static let rowHeight: CGFloat = 30
    static let width: CGFloat = 236
    static let maxRows = 8

    private unowned let textView: MarkdownTextView
    private let model = SlashMenuModel()
    private var panel: FloatingPanel?
    /// 「/」の位置。出ていなければ nil。
    private var trigger: Int?
    /// 文字を入れる以外のコマンド（議事録、推敲）は、アプリに任せる。
    var onAction: ((SlashCommand.Action) -> Void)?

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    var isOpen: Bool { trigger != nil }

    /// 本文が変わるたびに呼ぶ。「/」を打った直後なら開き、続きの文字で絞り、当てはまるものがなくなれば閉じる。
    func textChanged() {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return close() }
        let caret = selection.location

        if trigger == nil {
            guard caret > 0, let before = text.substring(with: NSRange(location: caret - 1, length: 1)).first,
                  SlashCommand.triggers.contains(before) else { return }
            // 行頭か、空白のあとだけ（「11/14」や URL では開かない）。コードの中でも開かない
            let lineStart = text.paragraphRange(for: NSRange(location: caret - 1, length: 0)).location
            let afterSpace = caret - 1 > lineStart && [" ", "　", "\t"].contains(text.substring(with: NSRange(location: caret - 2, length: 1)))
            guard caret - 1 == lineStart || afterSpace,
                  textView.textStorage?.attribute(.moguBlock, at: caret - 1, effectiveRange: nil) as? String != "code" else { return }
            trigger = caret - 1
        }
        guard let trigger, trigger < caret, caret <= text.length else { return close() }
        let query = text.substring(with: NSRange(location: trigger + 1, length: caret - trigger - 1))
        let items = SlashCommand.matching(query)
        guard !items.isEmpty, !query.contains(where: { $0.isWhitespace }) else { return close() }
        model.items = items
        model.selected = min(model.selected, items.count - 1)
        show()
    }

    /// カーソルが「/」より前や別の行に動いたら閉じる。
    func selectionChanged() {
        guard let trigger else { return }
        let selection = textView.selectedRange()
        let line = (textView.string as NSString).paragraphRange(for: NSRange(location: min(trigger, (textView.string as NSString).length), length: 0))
        if selection.length > 0 || selection.location <= trigger || selection.location > NSMaxRange(line) { close() }
    }

    /// 開いている間のキー。扱ったら true。
    func handle(_ selector: Selector) -> Bool {
        guard isOpen else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.selected = (model.selected - 1 + model.items.count) % model.items.count
        case #selector(NSResponder.moveDown(_:)):
            model.selected = (model.selected + 1) % model.items.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            choose(model.items[model.selected])
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    func close() {
        trigger = nil
        model.selected = 0
        panel?.dismiss()
    }

    private func show() {
        guard let trigger, let window = textView.window else { return }
        if panel == nil {
            panel = FloatingPanel(takesKey: false, content: SlashMenuView(model: model) { [weak self] in self?.choose($0) })
        }
        let rows = min(model.items.count, Self.maxRows)
        let size = NSSize(width: Self.width, height: CGFloat(rows) * Self.rowHeight + 10)
        // 「/」の真下に出す。画面の下に収まらなければ、上に出す
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: trigger, length: 1), actualRange: nil)
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - size.height - 6)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY + 8 { origin.y = anchor.maxY + 6 }
        panel?.show(NSRect(origin: origin, size: size), over: window)
    }

    /// 「/」と絞り込みの文字を消してから、コマンドを行う。
    private func choose(_ command: SlashCommand) {
        guard let trigger else { return }
        let caret = textView.selectedRange().location
        close()
        textView.apply(Formatting.Edit(range: NSRange(location: trigger, length: max(0, caret - trigger)), text: "",
                                       selection: NSRange(location: trigger, length: 0)))
        let text = textView.string as NSString
        let line = text.paragraphRange(for: NSRange(location: trigger, length: 0))
        let atLineStart = text.substring(with: NSRange(location: line.location, length: trigger - line.location))
            .allSatisfy { $0 == " " || $0 == "\t" }
        switch command.action {
        case .block(let prefix):
            textView.apply(Formatting.setBlock(text, selection: NSRange(location: trigger, length: 0), prefix: prefix))
        case .code:
            let lead = atLineStart ? "" : "\n"
            insert(lead + "```\n\n```", caretOffset: (lead as NSString).length + 4)
        case .rule:
            insert((atLineStart ? "" : "\n") + "---\n")
        case .date:
            insert(Self.stamp("yyyy-MM-dd"))
        case .time:
            insert(Self.stamp("HH:mm"))
        case .meeting, .rewrite:
            onAction?(command.action)
        }
    }

    private func insert(_ text: String, caretOffset: Int? = nil) {
        let at = textView.selectedRange().location
        textView.apply(Formatting.Edit(range: NSRange(location: at, length: 0), text: text,
                                       selection: NSRange(location: at + (caretOffset ?? (text as NSString).length), length: 0)))
    }

    private static func stamp(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }
}

struct SlashMenuView: View {
    @ObservedObject var model: SlashMenuModel
    let onChoose: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, command in
                        row(command, selected: index == model.selected)
                            .id(command.id)
                            .onTapGesture { onChoose(command) }
                            .onHover { if $0 { model.selected = index } }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selected) { _, new in
                if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
            }
        }
        .modifier(PanelBorder())
    }

    private func row(_ command: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: command.symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(command.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Text(command.hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: SlashMenu.rowHeight)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
