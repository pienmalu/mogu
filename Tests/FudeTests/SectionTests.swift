import XCTest

@MainActor
final class SectionTests: XCTestCase {
    private func note(_ name: String, _ date: Date) -> NoteSummary {
        NoteSummary(url: URL(fileURLWithPath: "/tmp/\(name).md"), title: name, snippet: "", modified: date, searchText: name)
    }

    func testGroupsByRecency() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        let day: TimeInterval = 86400
        let notes = [
            note("今朝", now.addingTimeInterval(-3600)),
            note("昨夜", now.addingTimeInterval(-day * 0.6)),
            note("先週", now.addingTimeInterval(-day * 4)),
            note("先月", now.addingTimeInterval(-day * 25)),
            note("去年", calendar.date(from: DateComponents(year: 2025, month: 8, day: 1))!),
        ]
        let sections = NoteStore.sections(notes, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["今日", "昨日", "この7日", "10月", "2025年8月"])
        XCTAssertTrue(sections[0].isToday)
    }
}
