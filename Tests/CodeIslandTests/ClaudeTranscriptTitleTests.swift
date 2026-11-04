import XCTest
@testable import CodeIsland

/// Health check 2026-11-04 #5: the title was read from a transcript's first
/// and last 64 KB as strict UTF-8, so a cut through a Chinese character
/// anywhere in either piece lost the title — for good when the head was
/// cut, on and off when the tail was. 29 of 245 real transcripts with a
/// title read none.
final class ClaudeTranscriptTitleTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testAHeadCutThroughAChineseCharacterStillHasItsTitle() {
        // The piece ends two bytes into 测 (three bytes in UTF-8).
        let data = Data((line(["type": "custom-title", "customTitle": "修复额度条"]) + "\n"
            + #"{"type":"user","message":{"content":"继续写"#).utf8) + Data("测".utf8).prefix(2)
        XCTAssertNil(String(data: data, encoding: .utf8), "the old strict decoding gave up here")
        XCTAssertEqual(SessionTitleStore.claudeTitle(head: data, tail: Data())?.title, "修复额度条")
    }

    func testATailCutThroughAChineseCharacterStillHasItsTitle() {
        // The piece starts on the last byte of 中.
        let data = Data("中".utf8).suffix(1) + Data((#"文开头"}}"# + "\n"
            + line(["type": "ai-title", "aiTitle": "整理体检报告"]) + "\n").utf8)
        XCTAssertNil(String(data: data, encoding: .utf8))
        let resolved = SessionTitleStore.claudeTitle(head: Data(), tail: data)
        XCTAssertEqual(resolved?.title, "整理体检报告")
        XCTAssertEqual(resolved?.source, .claudeAiTitle)
    }

    func testACustomTitleBeatsTheAiOne() {
        let head = line(["type": "ai-title", "aiTitle": "AI 起的名"])
        let tail = line(["type": "custom-title", "customTitle": "我起的名"])
        XCTAssertEqual(SessionTitleStore.claudeTitle(head: Data(head.utf8), tail: Data(tail.utf8))?.source, .claudeCustomTitle)
    }

    /// A transcript only grows; a title once found stays when the title
    /// line has scrolled out of both pieces, and the file is not read again
    /// while it has not changed.
    func testATitleOnceFoundStaysWhileTheFileGrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ClaudeTranscriptTitleCache(window: 64)
        let filler = line(["type": "user", "message": ["content": "很长的一段话"]]) + "\n"
        try (filler + line(["type": "custom-title", "customTitle": "体检修复"]) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.title(path: url.path)?.title, "体检修复", "in the last 64 bytes")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: filler, count: 20).utf8))
        try handle.close()
        XCTAssertEqual(cache.title(path: url.path)?.title, "体检修复", "out of both 64-byte pieces now")

        try (line(["type": "user", "message": ["content": "新文件"]]) + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(cache.title(path: url.path), "a shorter file is a new one")
        XCTAssertNil(cache.title(path: "/nonexistent/transcript.jsonl"))
    }

    /// Renamed after the first title, which stays in the head: once the new
    /// title has scrolled out of the tail, the head's older one must not
    /// win back (review of #5).
    func testAnOldTitleInTheHeadDoesNotWinBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ClaudeTranscriptTitleCache(window: 64)
        let filler = line(["type": "user", "message": ["content": "很长的一段话"]]) + "\n"
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try (line(["type": "custom-title", "customTitle": "旧名字"]) + "\n" + String(repeating: filler, count: 3))
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.title(path: url.path)?.title, "旧名字", "from the head")
        try append(line(["type": "custom-title", "customTitle": "新名字"]) + "\n")
        XCTAssertEqual(cache.title(path: url.path)?.title, "新名字")
        try append(String(repeating: filler, count: 5))
        XCTAssertEqual(cache.title(path: url.path)?.title, "新名字", "not the head's 旧名字")
    }
}
