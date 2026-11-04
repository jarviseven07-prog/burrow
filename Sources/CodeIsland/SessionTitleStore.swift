import Foundation
import CodeIslandCore

struct ResolvedSessionTitle: Sendable, Equatable {
    let title: String
    let source: SessionTitleSource
}

enum SessionTitleStore {
    static func supports(provider: String) -> Bool {
        switch provider {
        case "codex", "claude":
            return true
        default:
            return false
        }
    }

    static func title(for sessionId: String, provider: String, cwd: String? = nil,
                      claudeDesktopSessionId: String? = nil) -> ResolvedSessionTitle? {
        switch provider {
        case "codex":
            guard let title = codexThreadName(sessionId: sessionId) else { return nil }
            return ResolvedSessionTitle(title: title, source: .codexThreadName)
        case "claude":
            // A Code-tab session is known by the name Claude Desktop shows
            // for it; its folder is often a scratch workspace named by date.
            if let host = claudeDesktopSessionId,
               let title = ClaudeDesktopTitleCache.shared.title(hostSessionId: host) {
                return ResolvedSessionTitle(title: title, source: .claudeDesktopTitle)
            }
            return claudeTitle(sessionId: sessionId, cwd: cwd)
        default:
            return nil
        }
    }

    static func codexThreadName(sessionId: String) -> String? {
        // Each Codex root (CODEX_HOME / account) keeps its own thread index.
        for root in AppState.codexStateRoots() {
            let path = root + "/session_index.jsonl"
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let title = try? codexThreadName(sessionId: sessionId, indexContents: contents) {
                return title
            }
        }
        return nil
    }

    static func codexThreadName(sessionId: String, indexContents: String) throws -> String? {
        struct Entry: Decodable {
            let id: String
            let thread_name: String?
            let updated_at: String?
        }

        let decoder = JSONDecoder()
        let iso8601 = ISO8601DateFormatter()
        var latestMatch: (updatedAt: Date, title: String)?

        for line in indexContents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data),
                  entry.id == sessionId,
                  let rawTitle = entry.thread_name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty
            else {
                continue
            }

            let updatedAt = entry.updated_at.flatMap(iso8601.date(from:)) ?? .distantPast
            if let latestMatch, latestMatch.updatedAt > updatedAt {
                continue
            }

            latestMatch = (updatedAt, rawTitle)
        }

        return latestMatch?.title
    }

    static func claudeTitle(sessionId: String, cwd: String?) -> ResolvedSessionTitle? {
        guard let cwd else { return nil }

        let projectDir = cwd.claudeProjectDirEncoded()
        // The transcript sits under whichever config dir (account) ran it.
        guard let path = ClaudeConfigPaths.transcriptPath(projectDir: projectDir, sessionId: sessionId) else {
            return nil
        }
        return ClaudeTranscriptTitleCache.shared.title(path: path)
    }

    /// The title in a transcript's first and last pieces: a custom title
    /// (the user's) before an AI one, the tail's before the head's. The
    /// pieces are decoded leniently (health check #5): a cut through a
    /// multi-byte character only spoils the cut line, which never parses
    /// anyway, instead of the whole piece.
    static func claudeTitle(head: Data, tail: Data) -> ResolvedSessionTitle? {
        resolved(claudeTitles(head: head, tail: tail))
    }

    static func claudeTitles(head: Data, tail: Data) -> (custom: String?, ai: String?) {
        let pieces = claudeTitlePieces(head: head, tail: tail)
        return (pieces.tail.custom ?? pieces.head.custom, pieces.tail.ai ?? pieces.head.ai)
    }

    /// Each piece's latest titles, kept apart: the head is the oldest part
    /// of the file, so a title found there is older than any found before.
    static func claudeTitlePieces(head: Data, tail: Data)
        -> (head: (custom: String?, ai: String?), tail: (custom: String?, ai: String?)) {
        (latestClaudeTitles(in: String(decoding: head, as: UTF8.self)),
         latestClaudeTitles(in: String(decoding: tail, as: UTF8.self)))
    }

    static func resolved(_ titles: (custom: String?, ai: String?)) -> ResolvedSessionTitle? {
        if let custom = titles.custom { return ResolvedSessionTitle(title: custom, source: .claudeCustomTitle) }
        if let ai = titles.ai { return ResolvedSessionTitle(title: ai, source: .claudeAiTitle) }
        return nil
    }

    private static func latestClaudeTitles(in contents: String) -> (custom: String?, ai: String?) {
        var latestCustomTitle: String?
        var latestAiTitle: String?

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }

            switch type {
            case "custom-title":
                if let title = trimmedTitle(json["customTitle"]) {
                    latestCustomTitle = title
                }
            case "ai-title":
                if let title = trimmedTitle(json["aiTitle"]) {
                    latestAiTitle = title
                }
            default:
                continue
            }
        }

        return (latestCustomTitle, latestAiTitle)
    }

    private static func trimmedTitle(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Titles read from Claude transcripts (health check #5). Every hook event
/// asks, on the main thread, so a file that has not changed is not read
/// again. A transcript only grows: a title found once is kept while the
/// title line is out of both pieces read, until a newer one turns up or the
/// file shrinks (a new file under the same name).
final class ClaudeTranscriptTitleCache: @unchecked Sendable {
    static let shared = ClaudeTranscriptTitleCache()

    private struct Entry {
        var size: UInt64
        var modified: Date?
        var custom: String?
        var ai: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let window: Int

    /// `window`: how much of the head and of the tail is read.
    init(window: Int = 64 * 1024) { self.window = window }

    func title(path: String) -> ResolvedSessionTitle? {
        lock.lock(); defer { lock.unlock() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            entries[path] = nil
            return nil
        }
        let modified = attributes[.modificationDate] as? Date
        let known = entries[path]
        if let known, known.size == size, known.modified == modified {
            return SessionTitleStore.resolved((known.custom, known.ai))
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let piece = UInt64(window)
        let head = (try? handle.read(upToCount: window)) ?? Data()
        var tail = head
        if size > piece, (try? handle.seek(toOffset: size - piece)) != nil {
            tail = (try? handle.readToEnd()) ?? Data()
        }
        let found = SessionTitleStore.claudeTitlePieces(head: head, tail: tail)
        let kept = known.flatMap { $0.size <= size ? $0 : nil }
        if entries.count > 512 { entries.removeAll() }
        // Newest first: the tail, then what was found before (from a tail
        // or head that is at least as new as this head), then the head.
        let entry = Entry(size: size, modified: modified,
                          custom: found.tail.custom ?? kept?.custom ?? found.head.custom,
                          ai: found.tail.ai ?? kept?.ai ?? found.head.ai)
        entries[path] = entry
        return SessionTitleStore.resolved((entry.custom, entry.ai))
    }
}

/// Claude Desktop's Code-tab session titles. The record is a few hundred KB
/// and hooks fire many times a second, so each session's file is looked at
/// at most every 30s and parsed only when it changed.
final class ClaudeDesktopTitleCache: @unchecked Sendable {
    static let shared = ClaudeDesktopTitleCache()

    private struct Entry {
        var path: String?
        var modified: Date?
        var title: String?
        var checkedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let recheckInterval: TimeInterval
    private let supportDirectory: String
    private let now: () -> Date

    init(supportDirectory: String = NSHomeDirectory() + "/Library/Application Support/Claude",
         recheckInterval: TimeInterval = 30,
         now: @escaping () -> Date = Date.init) {
        self.supportDirectory = supportDirectory
        self.recheckInterval = recheckInterval
        self.now = now
    }

    func title(hostSessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        if let entry = entries[hostSessionId], time.timeIntervalSince(entry.checkedAt) < recheckInterval {
            return entry.title
        }
        var entry = entries[hostSessionId] ?? Entry(checkedAt: time)
        entry.checkedAt = time
        if entry.path == nil || !FileManager.default.fileExists(atPath: entry.path!) {
            entry.path = ClaudeDesktopCodeSession.recordPath(hostSessionId: hostSessionId,
                                                            supportDirectory: supportDirectory)
        }
        guard let path = entry.path else {
            entry.title = nil
            entries[hostSessionId] = entry
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if modified == nil || modified != entry.modified {
            entry.modified = modified
            entry.title = FileManager.default.contents(atPath: path).flatMap(ClaudeDesktopCodeSession.title(fromRecord:))
        }
        entries[hostSessionId] = entry
        return entry.title
    }
}
