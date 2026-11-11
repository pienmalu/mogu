import AppKit
import XCTest

/// 保存まわり。すべて一時フォルダの中だけで試す。
@MainActor
final class EditorTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        folder = tmp.appendingPathComponent("fude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
    }

    private func type(_ editor: EditorController, _ text: String) {
        editor.textView.string = text
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
    }

    func testBlankNewNoteIsNotWritten() {
        let editor = EditorController(folder: folder)
        editor.newNote()
        type(editor, "  \n\n")
        editor.save()
        XCTAssertEqual(files(), [])
    }

    func testNewNoteIsWrittenOnce() throws {
        let editor = EditorController(folder: folder)
        editor.newNote()
        type(editor, "# はじめて\n書いた")
        editor.save()
        XCTAssertEqual(files().count, 1)
        let url = try XCTUnwrap(editor.url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# はじめて\n書いた")
        type(editor, "# はじめて\n書いた\n足した")
        editor.save()
        XCTAssertEqual(files().count, 1, "2回目は同じファイルに書く")
    }

    func testOpeningDoesNotTouchFile() throws {
        let url = folder.appendingPathComponent("既存.md")
        try Data("---\nk: v\n---\n本文\r\n".utf8).write(to: url)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let editor = EditorController(folder: folder)
        editor.open(url)
        editor.save()
        editor.newNote()
        XCTAssertEqual(EditorController.modificationDate(url), old, "開いて閉じただけなら更新日時は変わらない")
    }

    func testEditKeepsFrontmatter() throws {
        let url = folder.appendingPathComponent("既存.md")
        try Data("---\nk: v\n---\n本文\n".utf8).write(to: url)
        let editor = EditorController(folder: folder)
        editor.open(url)
        XCTAssertEqual(editor.textView.string, "本文\n")
        type(editor, "直した本文\n")
        editor.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\nk: v\n---\n直した本文\n")
    }

    func testEmptyingExistingNoteDoesNotDeleteIt() throws {
        let url = folder.appendingPathComponent("消さない.md")
        try Data("中身".utf8).write(to: url)
        let editor = EditorController(folder: folder)
        editor.open(url)
        type(editor, "")
        editor.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testExternalChangeIsNotOverwritten() throws {
        let url = folder.appendingPathComponent("共有.md")
        try Data("最初".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let editor = EditorController(folder: folder)
        editor.open(url)
        type(editor, "こちらの編集")
        try Data("よそでの編集".utf8).write(to: url)  // 開いている間にほかのアプリが書いた
        editor.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "よそでの編集")
        XCTAssertEqual(files(), ["共有 の競合コピー.md", "共有.md"])
    }

    func testCleanEditorFollowsExternalChange() throws {
        let url = folder.appendingPathComponent("追従.md")
        try Data("最初".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let editor = EditorController(folder: folder)
        editor.open(url)
        try Data("よそでの編集".utf8).write(to: url)
        editor.reloadIfChangedOnDisk()
        XCTAssertEqual(editor.textView.string, "よそでの編集")
    }

    func testCopyIsPlainMarkdown() {
        let editor = EditorController(folder: folder)
        editor.newNote()
        type(editor, "# 見出し\n**太字**と`コード`")
        editor.textView.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fude-test-\(UUID().uuidString)"))
        XCTAssertTrue(editor.textView.writeSelection(to: pasteboard, types: editor.textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "# 見出し\n**太字**と`コード`")
        XCTAssertNil(pasteboard.data(forType: .rtf), "書式つきの形では渡さない")
        pasteboard.releaseGlobally()
    }

    func testStylingDoesNotChangeText() {
        let editor = EditorController(folder: folder)
        editor.newNote()
        let text = "# 見出し\n- [x] 済み\n> 引用\n```\ncode\n```\n[リンク](https://example.com)"
        type(editor, text)
        XCTAssertEqual(editor.textView.string, text)
        XCTAssertFalse(editor.textView.undoManager?.canUndo ?? false, "装飾は Undo に積まない")
    }
}

@MainActor
final class EditorConflictTests: XCTestCase {
    func testTouchedButSameBodyIsNotConflict() throws {
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let folder = tmp.appendingPathComponent("fude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("同期.md")
        try Data("本文".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let editor = EditorController(folder: folder)
        editor.open(url)
        editor.textView.string = "本文に足した"
        // 同期ツールが日時だけ変えた（frontmatter も足した）
        try Data("---\nsynced: true\n---\n本文".utf8).write(to: url)
        editor.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["同期.md"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\nsynced: true\n---\n本文に足した")
    }
}

/// 日本語の変換中は、装飾も保存もしない（変換中の下線と範囲が保たれ、確定できる）。
@MainActor
final class ComposingTests: XCTestCase {
    func testComposingIsNotDisturbed() throws {
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let folder = tmp.appendingPathComponent("fude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = EditorController(folder: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.newNote()
        let view = editor.textView
        view.string = "## 見出し\n"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let marked = view.markedRange()
        let underline = view.textStorage!.attribute(.underlineStyle, at: marked.location, effectiveRange: nil) as? Int
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        editor.save()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.textStorage!.attribute(.underlineStyle, at: marked.location, effectiveRange: nil) as? Int, underline,
                       "変換中の下線が消えない")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "変換中は保存しない")
        view.insertText("日本", replacementRange: marked)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "## 見出し\n日本")
    }
}
