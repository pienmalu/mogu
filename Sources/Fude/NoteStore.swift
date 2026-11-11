import AppKit
import Combine

/// 一覧の1行。本文は検索のために小文字で持っておく。
struct NoteSummary: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let title: String
    let snippet: String
    let modified: Date
    let searchText: String
}

/// 保存先フォルダの .md を一覧にする。サブフォルダも見る（隠しフォルダは見ない）。
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var folder: URL
    @Published private(set) var notes: [NoteSummary] = []
    @Published var query = ""
    @Published var selection: URL?
    /// 検索欄に移る合図（⌘P）。
    let focusSearch = PassthroughSubject<Void, Never>()

    private var cache: [URL: NoteSummary] = [:]
    private var watcher: FolderWatcher?
    private var generation = 0

    static let folderKey = "folder"

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watch()
        reload()
    }

    /// 一覧のまとまり。
    struct Section: Equatable {
        let title: String
        let isToday: Bool
        let notes: [NoteSummary]
    }

    /// 更新日時で、今日・昨日・この7日・月ごと（去年より前は年も）にまとめる。notes は新しい順。
    nonisolated static func sections(_ notes: [NoteSummary], now: Date, calendar: Calendar = .current) -> [Section] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        var result: [Section] = []
        var titles: [String] = []
        var groups: [String: [NoteSummary]] = [:]
        for note in notes {
            let title: String
            if note.modified >= startOfToday {
                title = "今日"
            } else if note.modified >= startOfYesterday {
                title = "昨日"
            } else if note.modified >= startOfWeek {
                title = "この7日"
            } else if calendar.isDate(note.modified, equalTo: now, toGranularity: .year) {
                title = "\(calendar.component(.month, from: note.modified))月"
            } else {
                title = "\(calendar.component(.year, from: note.modified))年\(calendar.component(.month, from: note.modified))月"
            }
            if groups[title] == nil { titles.append(title) }
            groups[title, default: []].append(note)
        }
        for title in titles {
            result.append(Section(title: title, isToday: title == "今日", notes: groups[title]!))
        }
        return result
    }

    /// 検索語（空白区切り）をすべて含むノート。
    var visible: [NoteSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return notes }
        return notes.filter { note in words.allSatisfy { note.searchText.contains($0) } }
    }

    func setFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        cache = [:]
        notes = []
        selection = nil
        watch()
        reload()
    }

    /// 変わったファイルだけ読み直す。重い作業は裏で行う。
    func reload() {
        generation += 1
        let generation = generation
        let folder = folder
        let cache = cache
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = Self.scan(folder: folder, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    self.cache = Dictionary(uniqueKeysWithValues: scanned.map { ($0.url, $0) })
                    self.notes = scanned.sorted { $0.modified > $1.modified }
                }
            }
        }
    }

    nonisolated static func scan(folder: URL, cache: [URL: NoteSummary]) -> [NoteSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [NoteSummary] = []
        for case let url as URL in walker {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let url = url.standardizedFileURL
            if let hit = cache[url], hit.modified == modified {
                result.append(hit)
                continue
            }
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let file = NoteFile.parse(data) else { continue }
            let name = url.lastPathComponent
            result.append(NoteSummary(url: url,
                                      title: NoteFile.title(body: file.body, fileName: name),
                                      snippet: NoteFile.snippet(body: file.body, fileName: name),
                                      modified: modified,
                                      searchText: (name + "\n" + file.body).lowercased()))
        }
        return result
    }

    /// ゴミ箱へ移す（消さない。Finder から戻せる）。
    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            NSLog("ゴミ箱に移せませんでした: \(error)")
        }
        if selection == url { selection = nil }
        reload()
    }

    private func watch() {
        watcher = FolderWatcher(url: folder) { [weak self] in
            self?.reload()
            self?.onExternalChange?()
        }
    }

    /// フォルダの中身が変わったときに呼ぶ（開いているノートの読み直しに使う）。
    var onExternalChange: (() -> Void)?
}

/// FSEvents でフォルダ以下の変更を受け取る。
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
