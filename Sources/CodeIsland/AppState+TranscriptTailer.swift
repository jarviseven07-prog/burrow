import Foundation
import CodeIslandCore

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path

        // Backfill messages from the transcript file so recentMessages is populated
        let messages: [ChatMessage]
        if sessions[sessionId]?.source == "codex" {
            messages = Self.readRecentFromCodexTranscript(path: path).1
        } else {
            messages = Self.readRecentFromTranscript(path: path).1
        }
        if !messages.isEmpty, var session = sessions[sessionId] {
            session.recentMessages = messages
            if let lastUser = messages.last(where: { $0.isUser }) {
                session.lastUserPrompt = lastUser.text
            }
            if let lastAssistant = messages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = lastAssistant.text
            }
            sessions[sessionId] = session
        }

        // Recap + model/effort from the transcript tail, by the same rules as
        // live deltas. Authoritative for the recap, so a persisted one that a
        // newer prompt superseded while nobody was watching is dropped here.
        // Its end offset is where the tailer and the checklist backfill pick
        // up, so a line written meanwhile (the prompt that makes this recap
        // stale, Codex's last update_plan) is read by exactly one of them.
        let tailScan = JSONLTailer.scanTailForAttach(path: path)
        if let tailScan,
           var session = sessions[sessionId],
           session.applyTranscriptBackfill(tailScan.delta) {
            sessions[sessionId] = session
        }

        if sessions[sessionId]?.source == "codex",
           let turnStatus = Self.latestCodexTurnStatus(path: path),
           var session = sessions[sessionId] {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                if session.source == "codex" {
                    session.liveCodexOutput = nil
                }
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
            }
            if let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                session.lastActivity = modifiedAt
            }
            sessions[sessionId] = session
        }

        // Checklist history is rebuilt off the main actor from the bytes the
        // tailer will not see: everything before the tailer's start offset.
        let attachOffset = tailScan?.endOffset ?? Self.transcriptFileSize(path)
        let attachmentToken = transcriptTailer.attach(
            sessionId: sessionId,
            filePath: path,
            initialOffset: attachOffset
        )
        attachedTranscriptTokens[sessionId] = attachmentToken
        startAgentTaskBackfill(
            sessionId: sessionId,
            path: path,
            endOffset: attachOffset,
            attachmentToken: attachmentToken,
            // A long Codex turn's output often pushes its turn_context out of
            // the tail window; look further back, off the main actor.
            searchCodexModel: sessions[sessionId]?.source == "codex" && tailScan?.delta.modelObservation == nil
        )
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        attachedTranscriptTokens.removeValue(forKey: sessionId)
        pendingAgentTaskBackfills.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        if let attachmentToken = delta.attachmentToken {
            guard attachedTranscriptTokens[delta.sessionId] == attachmentToken,
                  attachedTranscriptPaths[delta.sessionId] == delta.filePath else {
                return
            }
        }
        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false

        if delta.hasActivity {
            session.lastActivity = Date()
            mutated = true
        }

        if let turnStatus = delta.turnStatus {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                if session.source == "codex" {
                    session.liveCodexOutput = nil
                }
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
            }
            // A status-only event is still activity. This matters for a long Codex
            // turn whose transcript has not emitted a message yet.
            session.lastActivity = Date()
            mutated = true
        }

        if let prompt = delta.lastUserPrompt {
            let normalizedIncoming = prompt
            let normalizedCurrent = session.lastUserPrompt.flatMap {
                $0
            }
            if normalizedCurrent != normalizedIncoming {
                session.lastUserPrompt = normalizedIncoming
                let lastUserText = session.recentMessages.last(where: { $0.isUser })?.text
                let lastNormalized = lastUserText.flatMap {
                    $0
                }
                if lastNormalized != normalizedIncoming {
                    session.addRecentMessage(ChatMessage(isUser: true, text: normalizedIncoming))
                }
                mutated = true
            }
        }
        if let reply = delta.lastAssistantMessage {
            let normalizedIncoming = reply
            let normalizedCurrent = session.lastAssistantMessage.flatMap {
                $0
            }
            if normalizedCurrent != normalizedIncoming {
                session.lastAssistantMessage = normalizedIncoming
                let lastAssistantText = session.recentMessages.last(where: { !$0.isUser })?.text
                let lastNormalized = lastAssistantText.flatMap {
                    $0
                }
                if lastNormalized != normalizedIncoming {
                    session.addRecentMessage(ChatMessage(isUser: false, text: normalizedIncoming))
                }
                mutated = true
            }
            if session.source == "codex", session.liveCodexOutput != normalizedIncoming {
                session.liveCodexOutput = normalizedIncoming
                mutated = true
            }
        }

        // Checklist progress from the transcript: the only channel for Codex
        // update_plan, and the backstop when a Claude hook is missed. A
        // replaced file re-read from its start is history, rebuilt the way an
        // attach backfill is — not replayed as news (a plan finished long ago
        // would flash "all done").
        if delta.replaysWholeFile {
            if replayAgentTaskHistory(delta.taskEvents, sessionId: delta.sessionId, to: &session) {
                mutated = true
            }
        } else if !delta.taskEvents.isEmpty,
           applyAgentTaskTranscriptEvents(delta.taskEvents, sessionId: delta.sessionId, to: &session) {
            mutated = true
        }

        // Recap + model/effort label. Written back without bumping lastActivity:
        // a recap arrives minutes after the turn ended and is not activity.
        let metadataChanged = session.applyTranscriptMetadata(from: delta)
        if delta.modelObservation != nil {
            // Newer than anything the attach-time search can still turn up.
            pendingAgentTaskBackfills[delta.sessionId]?.sawLiveModelObservation = true
        }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        } else if metadataChanged {
            sessions[delta.sessionId] = session
            scheduleSave()
        }
    }
}
