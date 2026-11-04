import Foundation
import CodeIslandCore

struct PermissionRequest {
    /// Identity of this one request. A session asks again and again — and
    /// its subagents can each have one queued — so the card on screen tells
    /// requests apart by this, not by session. A
    /// replay of the same request keeps it (`mergeDuplicatePermissionRequest`).
    let id: UUID
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>
    /// The tool call this request is about. Claude Code's and Codex's
    /// PermissionRequest carry no tool_use_id, so it is usually the id of the
    /// call's own PreToolUse, found by `AppState.correlatedToolUseId(for:)`.
    /// Only that call's own events answer the request.
    let toolUseId: String?
    /// The hook socket waiting for this answer (HookServer). When it closes,
    /// only this request goes — not the agent's others (health check #6).
    let connectionId: UUID?

    init(
        id: UUID = UUID(),
        event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        toolUseId: String? = nil,
        connectionId: UUID? = nil
    ) {
        self.id = id
        self.event = event
        self.continuation = continuation
        self.toolUseId = toolUseId ?? event.toolUseId
        self.connectionId = connectionId
    }
}

struct AskUserQuestionItem {
    let payload: QuestionPayload
    let answerKey: String
    let multiSelect: Bool
}

struct AskUserQuestionAnswer {
    let question: String
    let answer: String
    let selectedOptions: [String]
    let customInput: String?
}

struct AskUserQuestionState {
    let items: [AskUserQuestionItem]
    var answers: [String: String]

    var canConfirm: Bool {
        items.allSatisfy { answers[$0.answerKey] != nil }
    }

    /// Whether `submitted` is a complete answer set for exactly these items:
    /// one answer per question, in item order. Answers are mapped onto items
    /// by position, so a set collected for a different request would otherwise
    /// be delivered against this request's questions. (#333)
    func accepts(_ submitted: [AskUserQuestionAnswer]) -> Bool {
        submitted.count == items.count
            && zip(submitted, items).allSatisfy { $0.question == $1.payload.question }
    }

    mutating func select(questionIndex: Int, option: String) {
        guard items.indices.contains(questionIndex) else { return }
        answers[items[questionIndex].answerKey] = option
    }
}

/// How a queued question gets resolved once the user answers (or it is drained).
///
/// Hook-originated questions are answered by resuming a JSON `CheckedContinuation`
/// the bridge socket is awaiting. Codex app-server questions instead reach us as a
/// server->client JSON-RPC *request*, so they are answered by writing a JSON-RPC
/// *response* back over the running `codex app-server` client. The two paths are
/// mutually exclusive — exactly one is used per request.
enum QuestionResolution {
    /// Resume the awaiting hook bridge with the serialized hook response.
    case hook(CheckedContinuation<Data, Never>)
    /// Reply to a Codex app-server `item/tool/requestUserInput` request.
    /// `answersByKey` maps each question's answerKey to the chosen answer
    /// string(s); `nil` means the user skipped / the request was abandoned.
    case codexAppServer((_ answersByKey: [String: [String]]?) -> Void)

    /// Resume a hook continuation; no-op for app-server resolutions.
    func resumeHook(returning data: Data) {
        if case .hook(let continuation) = self {
            continuation.resume(returning: data)
        }
    }
}

struct QuestionRequest {
    /// Identity of this one request. A session id does not name a card on its
    /// own — the same session asks again later, and its subagents can each
    /// have a question queued — so the question card is keyed by this, and no
    /// answer state outlives the request it was collected for. (#333)
    let id = UUID()
    let event: HookEvent
    let question: QuestionPayload
    let resolution: QuestionResolution
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool
    var askUserQuestionState: AskUserQuestionState?
    /// The hook socket waiting for this answer, as for `PermissionRequest`.
    var connectionId: UUID?

    init(
        event: HookEvent,
        question: QuestionPayload,
        resolution: QuestionResolution,
        isFromPermission: Bool = false,
        askUserQuestionState: AskUserQuestionState? = nil
    ) {
        self.event = event
        self.question = askUserQuestionState?.items.first?.payload ?? question
        self.resolution = resolution
        self.isFromPermission = isFromPermission
        self.askUserQuestionState = askUserQuestionState
    }

    /// Back-compat convenience for hook-originated questions.
    init(
        event: HookEvent,
        question: QuestionPayload,
        continuation: CheckedContinuation<Data, Never>,
        isFromPermission: Bool = false,
        askUserQuestionState: AskUserQuestionState? = nil
    ) {
        self.init(
            event: event,
            question: question,
            resolution: .hook(continuation),
            isFromPermission: isFromPermission,
            askUserQuestionState: askUserQuestionState
        )
    }

    /// True when this question must be answered via the Codex app-server client
    /// rather than a hook continuation.
    var isCodexAppServer: Bool {
        if case .codexAppServer = resolution { return true }
        return false
    }

    /// Deliver answers to a Codex app-server question (no-op for hook questions).
    func resolveCodexAppServer(_ answersByKey: [String: [String]]?) {
        if case .codexAppServer(let reply) = resolution {
            reply(answersByKey)
        }
    }
}
