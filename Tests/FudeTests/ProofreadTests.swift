import XCTest

final class ProofreadTests: XCTestCase {
    private func rebuild(_ pieces: [Proofread.Piece]) -> (String, String) {
        pieces.reduce(into: ("", "")) { result, piece in
            switch piece {
            case .same(let t): result.0 += t; result.1 += t
            case .deleted(let t): result.0 += t
            case .inserted(let t): result.1 += t
            }
        }
    }

    func testRoundTrips() {
        let pairs = [
            ("先生にいわれたこと", "先生から言われたこと"),
            ("サンプル数たりない。もう少しあつめたほうがいい", "サンプル数が足りない。もう少し集める必要がある。"),
            ("", "新しい"),
            ("消える", ""),
            ("同じ\n文", "同じ\n文"),
        ]
        for (old, new) in pairs {
            let (a, b) = rebuild(Proofread.diff(old, new))
            XCTAssertEqual(a, old)
            XCTAssertEqual(b, new)
        }
    }

    func testShortMatchesAreMerged() {
        // 「あつめたほうがいい」→「集める必要がある」は、細切れにせず一つの赤字にまとまる
        let pieces = Proofread.diff("もう少しあつめたほうがいい", "もう少し集める必要がある")
        XCTAssertEqual(pieces.first, .same("もう少し"))
        XCTAssertLessThanOrEqual(pieces.count, 3, "\(pieces)")
    }

    func testKanjiWordsAreKept() {
        let pieces = Proofread.diff("きょうのゼミ、先生にいわれた", "今日のゼミで先生から言われた")
        XCTAssertTrue(pieces.contains(.same("先生")), "\(pieces)")
    }

    func testDeletionComesBeforeInsertion() {
        XCTAssertEqual(Proofread.diff("きょう", "今日"), [.deleted("きょう"), .inserted("今日")])
    }

    func testLongTextIsFastEnough() {
        let old = String(repeating: "実験のサンプル数たりない。もう少しあつめたほうがいい　あと統計の検定もちゃんとやれと\n", count: 110)
        let new = String(repeating: "実験のサンプル数が足りない。もう少し集める必要がある。また、統計の検定もきちんと行うこと。\n", count: 110)
        let start = Date()
        let pieces = Proofread.diff(old, new)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rebuild(pieces).1, new)
        XCTAssertLessThan(elapsed, 2.0, "5,000字の差分に \(elapsed) 秒")
        print("5,000字の差分: \(String(format: "%.2f", elapsed)) 秒")
    }
}
