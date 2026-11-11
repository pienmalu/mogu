import Foundation

/// 箇条書きの続きを決める（純粋な関数）。
enum ListContinuation {
    enum Action: Equatable {
        case none
        case insert(String)  // 次の行の頭に入れる記号
        case endList         // 記号だけの行なら、記号を消して箇条書きを抜ける
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d{1,3})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    static func action(forLineBeforeCursor line: String) -> Action {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return .none }
        if m.range.length == ns.length { return .endList }
        let indent = ns.substring(with: m.range(at: 1))
        let space = ns.substring(with: m.range(at: 5))
        var marker = ns.substring(with: m.range(at: 2))
        if m.range(at: 3).location != NSNotFound, let number = Int(ns.substring(with: m.range(at: 3))) {
            marker = "\(number + 1)" + ns.substring(with: m.range(at: 4))
        }
        let box = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
        return .insert(indent + marker + space + box)
    }
}
