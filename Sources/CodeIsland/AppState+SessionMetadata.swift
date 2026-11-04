import Foundation
import CodeIslandCore

/// Where one subagent's own model/effort is being looked for.
struct SubagentModelRead {
    /// Reads started so far; they stop at `AppState.subagentModelReadMaxAttempts`.
    var attempts = 0
    var retryAt: Date = .distantPast
    var inFlight = false
    /// The Claude subagent's transcript once found, so a retry skips the search.
    var transcriptPath: String?
}

/// Transcript-derived session metadata that hooks don't carry: a subagent's
/// own model / reasoning effort. (The session recap and the main thread's
/// model ride the transcript tailer — see `applyTranscriptDelta`.)
extension AppState {
    /// First wait before re-reading a subagent transcript that has no
    /// assistant turn yet (SubagentStart fires before the first one is
    /// written); it doubles on every miss, up to the cap.
    nonisolated static let subagentModelReadRetryInterval: TimeInterval = 2
    nonisolated static let subagentModelReadMaxRetryInterval: TimeInterval = 60
    /// A subagent whose transcript still names no model after this many reads
    /// (about three minutes of hooks) stays unlabeled rather than costing a
    /// file search on every hook for as long as it runs.
    nonisolated static let subagentModelReadMaxAttempts = 8

    /// Where a subagent's own model is recorded.
    enum SubagentModelSource: Sendable {
        /// A Claude subagent's own transcript, next to the parent's.
        case claude(parentTranscriptPath: String, agentId: String, knownPath: String?)
        /// A Codex child thread's own rollout.
        case codexRollout(path: String)
    }

    /// Give a subagent its own model/effort, read from the child's transcript.
    ///
    /// Claude Code hooks never say which model a subagent runs, and Codex child
    /// hooks carry the model but not the effort. Borrowing the parent's values
    /// would mislabel every Task that runs on a different model, so the child's
    /// own transcript is the source. The read runs off the main actor; a
    /// successful one is cached per agent id because Codex recreates the
    /// SubagentState on every child turn.
    func maybeBackfillSubagentModel(sessionId: String, agentId: String, event: HookEvent) {
        guard let session = sessions[sessionId],
              let subagent = session.subagents[agentId] else { return }

        if let cached = subagentModelObservations[sessionId]?[agentId] {
            applySubagentModel(cached, sessionId: sessionId, agentId: agentId)
            return
        }
        guard subagent.model == nil || subagent.reasoningEffort == nil else { return }
        var read = subagentModelReads[sessionId]?[agentId] ?? SubagentModelRead()
        guard !read.inFlight,
              read.attempts < Self.subagentModelReadMaxAttempts,
              read.retryAt <= Date() else { return }

        let source: SubagentModelSource
        switch SessionSnapshot.normalizedSupportedSource(session.source) {
        case "claude":
            guard let parentPath = session.transcriptPath else { return }
            // SubagentStop names the child's transcript; other hooks don't.
            let hinted = (event.rawJSON["agent_transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            source = .claude(
                parentTranscriptPath: parentPath,
                agentId: agentId,
                knownPath: read.transcriptPath ?? hinted
            )
        case "codex":
            // Child-thread hooks carry the child's own rollout path.
            guard let childPath = event.rawJSON["transcript_path"] as? String,
                  !childPath.isEmpty, childPath != session.transcriptPath else { return }
            source = .codexRollout(path: childPath)
        default:
            // No child transcript to read; a model on the child's own hooks
            // (recordSubagentModel in the reducer) is all there is.
            read.attempts = Self.subagentModelReadMaxAttempts
            subagentModelReads[sessionId, default: [:]][agentId] = read
            return
        }

        read.attempts += 1
        read.inFlight = true
        subagentModelReads[sessionId, default: [:]][agentId] = read
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.readSubagentModel(from: source)
            await self?.finishSubagentModelRead(
                sessionId: sessionId,
                agentId: agentId,
                observation: result.observation,
                transcriptPath: result.transcriptPath
            )
        }
    }

    func finishSubagentModelRead(
        sessionId: String,
        agentId: String,
        observation: ModelObservation?,
        transcriptPath: String?
    ) {
        // Gone with its session (removeSession drops the reads).
        guard var read = subagentModelReads[sessionId]?[agentId] else { return }
        read.inFlight = false
        read.transcriptPath = transcriptPath ?? read.transcriptPath
        guard let observation else {
            let backoff = Self.subagentModelReadRetryInterval * pow(2, Double(max(0, read.attempts - 1)))
            read.retryAt = Date().addingTimeInterval(min(backoff, Self.subagentModelReadMaxRetryInterval))
            subagentModelReads[sessionId]?[agentId] = read
            return
        }
        subagentModelObservations[sessionId, default: [:]][agentId] = observation
        subagentModelReads[sessionId]?.removeValue(forKey: agentId)
        applySubagentModel(observation, sessionId: sessionId, agentId: agentId)
    }

    private func applySubagentModel(_ observation: ModelObservation, sessionId: String, agentId: String) {
        guard var subagent = sessions[sessionId]?.subagents[agentId] else { return }
        // A model the child's own hook reported is at least as current as the
        // cached transcript read, so only fill gaps.
        let model = subagent.model ?? observation.model
        let effort = subagent.reasoningEffort ?? observation.effort
        guard model != subagent.model || effort != subagent.reasoningEffort else { return }
        subagent.model = model
        subagent.reasoningEffort = effort
        sessions[sessionId]?.subagents[agentId] = subagent
    }

    /// Read a subagent's model/effort. Blocking file I/O: off the main actor.
    nonisolated static func readSubagentModel(
        from source: SubagentModelSource
    ) -> (observation: ModelObservation?, transcriptPath: String?) {
        switch source {
        case let .claude(parentTranscriptPath, agentId, knownPath):
            let path = knownPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? claudeSubagentTranscriptPath(parentTranscriptPath: parentTranscriptPath, agentId: agentId)
            return (path.flatMap { readClaudeSubagentModel(atPath: $0) }, path)
        case let .codexRollout(path):
            return (ModelObservation.latestCodexTurnContext(path: path), nil)
        }
    }

    /// Newest model/effort in a Claude subagent's transcript.
    nonisolated static func readClaudeSubagentModel(
        parentTranscriptPath: String,
        agentId: String,
        maxBytes: Int = 64 * 1024
    ) -> ModelObservation? {
        claudeSubagentTranscriptPath(parentTranscriptPath: parentTranscriptPath, agentId: agentId)
            .flatMap { readClaudeSubagentModel(atPath: $0, maxBytes: maxBytes) }
    }

    nonisolated static func readClaudeSubagentModel(atPath path: String, maxBytes: Int = 64 * 1024) -> ModelObservation? {
        readTranscriptTailData(path: path, maxBytes: maxBytes).flatMap(ModelObservation.latestInClaudeTranscript)
    }

    /// A Claude subagent's transcript file. Plain subagents sit at
    /// `<session>/subagents/agent-<id>.jsonl`; grouped runs nest them one or
    /// two directories deeper — workflow agents live at
    /// `subagents/workflows/wf_<run>/agent-<id>.jsonl`.
    nonisolated static func claudeSubagentTranscriptPath(parentTranscriptPath: String, agentId: String) -> String? {
        guard let defaultPath = SubagentState.claudeTranscriptPath(
            parentTranscriptPath: parentTranscriptPath,
            agentId: agentId
        ) else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultPath) { return defaultPath }
        let subagentsDir = (defaultPath as NSString).deletingLastPathComponent
        let fileName = (defaultPath as NSString).lastPathComponent
        func subdirectories(of dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
                .map { "\(dir)/\($0)" }
        }
        for group in subdirectories(of: subagentsDir) {
            let candidate = "\(group)/\(fileName)"
            if fm.fileExists(atPath: candidate) { return candidate }
            for run in subdirectories(of: group) {
                let nested = "\(run)/\(fileName)"
                if fm.fileExists(atPath: nested) { return nested }
            }
        }
        return nil
    }

    /// Where a Claude turn stands by its transcript. Claude writes a line only
    /// when a message is complete, so while the model thinks or streams a long
    /// tool call (a whole file for Write) nothing reaches the hooks or the file
    /// for minutes. The last message line still tells: a tool result or a
    /// `tool_use` stop means the turn is open; `end_turn`, an API error or an
    /// interrupt marker (Esc never fires Stop) means it is over.
    enum ClaudeTranscriptTurn: Equatable { case open, ended }

    /// Silence longer than this settles even a transcript that reads open — a
    /// crash mid-stream leaves the last line a tool result forever.
    nonisolated static let claudeSilentTurnCeiling: TimeInterval = 30 * 60

    /// The turn by the transcript's last line that says, read back from the
    /// end a piece at a time (health check #9). Claude Code writes its own
    /// bookkeeping after every request — `api-request-blob` lines of up to
    /// ~300 KB and more — so a fixed 64 KB tail often held no message at
    /// all, and a working turn fell back to the five-minute rule. Bookkeeping
    /// lines are skipped without parsing. Nil when the file is missing or
    /// holds no message; `.open` when `budget` bytes hold none, so a turn
    /// too busy to tell still gets the 30-minute ceiling, not five minutes.
    /// An unchanged file is not read again.
    nonisolated static func claudeTranscriptTurn(atPath path: String?, budget: Int = 8 * 1024 * 1024) -> ClaudeTranscriptTurn? {
        guard let path, !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if let known = ClaudeTurnCache.shared.turn(path: path, size: size) { return known }
        let turn = claudeTranscriptTurn(size: size, budget: budget) { offset, length in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: length)
        }
        ClaudeTurnCache.shared.store(turn, path: path, size: size)
        return turn
    }

    /// `read(offset, length)` gives the file's bytes; lines are judged last
    /// first, each piece read joined to the cut line it ends in.
    nonisolated static func claudeTranscriptTurn(size: UInt64, piece: Int = 64 * 1024, budget: Int,
                                                 read: (UInt64, Int) -> Data?) -> ClaudeTranscriptTurn? {
        switch lastClaudeLine(size: size, piece: piece, budget: budget, read: read, judge: claudeTurn(line:)) {
        case .found(let turn): return turn
        case .none: return nil
        case .budgetSpent: return .open
        }
    }

    /// The tool a Claude turn is running, by its transcript: a `tool_use`
    /// in this turn that no `tool_result` has answered yet. Nil for anything
    /// else, a missing file, or no answer within `budget`.
    nonisolated static func claudePendingTool(atPath path: String?, budget: Int = 8 * 1024 * 1024) -> String? {
        guard let path, !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var answered = Set<String>()
        let found = lastClaudeLine(size: size, budget: budget, read: { offset, length in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: length)
        }, judge: { claudePendingTool(line: $0, answered: &answered) })
        guard case .found(let tool) = found else { return nil }
        return tool
    }

    /// What one line says about a running tool, read last first:
    /// `.some(name)` for a tool call nothing has answered, `.some(nil)` where
    /// the search ends (the prompt that began the turn, an interrupt, a
    /// finished reply), nil to read on. Parallel calls are one line each and
    /// are answered as each one finishes, so results seen on the way are
    /// kept in `answered` (review of #14).
    private nonisolated static func claudePendingTool(line: Data.SubSequence,
                                                      answered: inout Set<String>) -> String?? {
        guard let turn = claudeTurn(line: line),
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        if turn == .ended { return .some(nil) }
        let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch object["type"] as? String {
        case "user":
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            guard !results.isEmpty else { return .some(nil) }
            for result in results {
                if let id = result["tool_use_id"] as? String { answered.insert(id) }
            }
            return nil
        case "assistant":
            for call in blocks.reversed() where call["type"] as? String == "tool_use" {
                if let id = call["id"] as? String, answered.contains(id) { continue }
                return .some(call["name"] as? String ?? "Tool")
            }
            return nil
        default:
            return nil
        }
    }

    enum BackwardScan<T> { case found(T), none, budgetSpent }

    /// The last line `judge` has an answer for, read back from the end.
    nonisolated static func lastClaudeLine<T>(size: UInt64, piece: Int = 64 * 1024, budget: Int,
                                              read: (UInt64, Int) -> Data?,
                                              judge: (Data.SubSequence) -> T?) -> BackwardScan<T> {
        var start = size
        var pending = Data()
        var spent = 0
        while start > 0 {
            guard spent < budget else { return .budgetSpent }
            let length = Int(min(UInt64(piece), start))
            start -= UInt64(length)
            guard let data = read(start, length), data.count == length else { return .none }
            spent += length
            pending = data + pending
            // Before the first newline is the end of a line that starts in
            // an earlier piece — unless this piece starts the file.
            let firstComplete: Data.Index
            if start == 0 {
                firstComplete = pending.startIndex
            } else if let newline = pending.firstIndex(of: 0x0A) {
                firstComplete = pending.index(after: newline)
            } else {
                continue
            }
            for line in pending[firstComplete...].split(separator: 0x0A).reversed() {
                if let answer = judge(line) { return .found(answer) }
            }
            pending = start == 0 ? Data() : Data(pending[..<pending.index(before: firstComplete)])
        }
        return .none
    }

    nonisolated static func claudeTranscriptTurn(tail: Data) -> ClaudeTranscriptTurn? {
        // The first line of a tail read may be cut mid-record; it fails to parse and is skipped.
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            if let turn = claudeTurn(line: line) { return turn }
        }
        return nil
    }

    /// What one line says about the turn; nil for a line that says nothing
    /// (bookkeeping, a side chain, a meta message, a cut line).
    private nonisolated static func claudeTurn(line: Data.SubSequence) -> ClaudeTranscriptTurn? {
        if isClaudeBookkeepingLine(line) { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["isSidechain"] as? Bool != true,
              object["isMeta"] as? Bool != true else { return nil }
        let message = object["message"] as? [String: Any]
        switch object["type"] as? String {
        case "assistant":
            if object["isApiErrorMessage"] as? Bool == true { return .ended }
            switch message?["stop_reason"] as? String {
            case "end_turn", "stop_sequence", "refusal": return .ended
            default: return .open
            }
        case "user":
            let texts: [String]
            if let text = message?["content"] as? String {
                texts = [text]
            } else if let blocks = message?["content"] as? [[String: Any]] {
                texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            } else {
                texts = []
            }
            return texts.contains { $0.hasPrefix("[Request interrupted") } ? .ended : .open
        default:
            return nil
        }
    }

    /// Claude Code's bookkeeping lines start with their type
    /// (`{"type":"api-request-blob",…`); messages start with `parentUuid`.
    /// Told apart from the first bytes, so a 300 KB blob is never parsed.
    nonisolated static func isClaudeBookkeepingLine(_ line: Data.SubSequence) -> Bool {
        let prefix = Data(#"{"type":""#.utf8)
        guard line.starts(with: prefix) else { return false }
        let rest = line.dropFirst(prefix.count)
        return !rest.starts(with: Data(#"user""#.utf8)) && !rest.starts(with: Data(#"assistant""#.utf8))
    }

    private nonisolated static func readTranscriptTailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}

/// The last answer `claudeTranscriptTurn(atPath:)` gave per transcript and
/// the size it was read at. The sweep asks every three seconds about a turn
/// that is silent — a file that has not changed.
final class ClaudeTurnCache: @unchecked Sendable {
    static let shared = ClaudeTurnCache()
    private let lock = NSLock()
    private var entries: [String: (size: UInt64, turn: AppState.ClaudeTranscriptTurn?)] = [:]

    func turn(path: String, size: UInt64) -> AppState.ClaudeTranscriptTurn?? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], entry.size == size else { return nil }
        return .some(entry.turn)
    }

    func store(_ turn: AppState.ClaudeTranscriptTurn?, path: String, size: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if entries.count > 256 { entries.removeAll() }
        entries[path] = (size, turn)
    }
}
