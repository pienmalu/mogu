import Foundation

/// 元の文と推敲後の文の違いを、校正の赤字の形にする（削った文字・足した文字・そのままの文字）。
enum Proofread {
    enum Piece: Equatable {
        case same(String)
        case deleted(String)
        case inserted(String)
    }

    /// 1文字ずつの差分をとり、読める単位にまとめる。
    static func diff(_ old: String, _ new: String) -> [Piece] {
        let a = Array(old)
        let b = Array(new)
        let change = b.difference(from: a)
        var removed = Set<Int>()
        var added = Set<Int>()
        for item in change {
            switch item {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var pieces: [Piece] = []
        var i = 0
        var j = 0
        func push(_ piece: Piece) {
            switch (pieces.last, piece) {
            case (.same(let x)?, .same(let y)): pieces[pieces.count - 1] = .same(x + y)
            case (.deleted(let x)?, .deleted(let y)): pieces[pieces.count - 1] = .deleted(x + y)
            case (.inserted(let x)?, .inserted(let y)): pieces[pieces.count - 1] = .inserted(x + y)
            default: pieces.append(piece)
            }
        }
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                push(.deleted(String(a[i])))
                i += 1
            } else if j < b.count, added.contains(j) {
                push(.inserted(String(b[j])))
                j += 1
            } else {
                push(.same(String(a[i])))
                i += 1
                j += 1
            }
        }
        return coalesce(pieces)
    }

    /// 変更に挟まれた短い一致（2字以下・改行を含まない）は、前後の変更に含めて一つの赤字にする。
    /// 「あつめた→集めた」のように細切れになるのを防ぐ。
    static func coalesce(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        var deleted = ""
        var inserted = ""
        var pendingSame = ""   // まとめるかどうか、次を見て決める短い一致

        func flushChange() {
            if !deleted.isEmpty { result.append(.deleted(deleted)) }
            if !inserted.isEmpty { result.append(.inserted(inserted)) }
            deleted = ""
            inserted = ""
        }

        for piece in pieces {
            switch piece {
            case .deleted(let text):
                deleted += pendingSame + text
                inserted += pendingSame
                pendingSame = ""
            case .inserted(let text):
                deleted += pendingSame
                inserted += pendingSame + text
                pendingSame = ""
            case .same(let text):
                if !pendingSame.isEmpty {  // 2つ続いた一致はまとめない
                    flushChange()
                    result.append(.same(pendingSame))
                    pendingSame = ""
                }
                let inChange = !deleted.isEmpty || !inserted.isEmpty
                if inChange, isFiller(text) {
                    pendingSame = text
                } else {
                    flushChange()
                    result.append(.same(text))
                }
            }
        }
        flushChange()
        if !pendingSame.isEmpty { result.append(.same(pendingSame)) }
        // 「削った文字」と「足した文字」が同じになったもの（まとめた結果）は一致に戻す
        return result.reduce(into: []) { list, piece in
            if case .same(let text) = piece, case .same(let previous)? = list.last {
                list[list.count - 1] = .same(previous + text)
            } else {
                list.append(piece)
            }
        }
    }

    /// まとめてよい短い一致：1字か、漢字を含まない2字（「先生」のような語は残す）。改行は含めない。
    static func isFiller(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        if text.count == 1 { return true }
        guard text.count == 2 else { return false }
        return !text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// 変わった字数（削った字と足した字の多い方の合計）。
    static func changedCount(_ pieces: [Piece]) -> Int {
        var count = 0
        var pendingDeleted = 0
        for piece in pieces {
            switch piece {
            case .deleted(let text): pendingDeleted = text.count
            case .inserted(let text): count += max(text.count, pendingDeleted); pendingDeleted = 0
            case .same: count += pendingDeleted; pendingDeleted = 0
            }
        }
        return count + pendingDeleted
    }
}
