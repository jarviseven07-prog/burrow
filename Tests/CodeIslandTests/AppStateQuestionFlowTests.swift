import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {
    private var savedSmartSuppress: Any?

    override func setUp() {
        super.setUp()
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        super.tearDown()
    }

    // MARK: - Multi-question answers

    func testAskUserQuestionMultiQuestionReturnsQuestionsAndAnswers() async throws {
        let appState = AppState()
        let questions = [
            question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            question(header: "输出风格", text: "你更喜欢我用哪种回答风格？", options: ["极简", "平衡"]),
        ]
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-1",
            questions: questions
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerQuestionMulti([
            (question: "你希望我接下来以哪种方式协作？", answer: "先给方案"),
            (question: "你更喜欢我用哪种回答风格？", answer: "平衡"),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let updatedInput = try extractUpdatedInput(from: responseData)
        let returnedQuestions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])
        XCTAssertEqual(returnedQuestions.count, questions.count)
        XCTAssertEqual(returnedQuestions[0]["question"] as? String, questions[0]["question"] as? String)
        XCTAssertEqual(returnedQuestions[1]["question"] as? String, questions[1]["question"] as? String)

        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我接下来以哪种方式协作？"] as? String, "先给方案")
        XCTAssertEqual(answers["你更喜欢我用哪种回答风格？"] as? String, "平衡")
    }

    func testStructuredAnswerDetailsPreserveMultiSelectAndCustomInput() async throws {
        let appState = AppState()
        var multiQuestion = question(
            header: "组合选择",
            text: "请选择多个选项，也可以补充自定义内容",
            options: ["Alpha, Beta", "Gamma"]
        )
        multiQuestion["multiSelect"] = true
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-structured",
            questions: [multiQuestion],
            source: "opencode"
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "请选择多个选项，也可以补充自定义内容",
                answer: "Alpha, Beta, Gamma, custom, value",
                selectedOptions: ["Alpha, Beta", "Gamma"],
                customInput: "custom, value"
            ),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let updatedInput = try extractUpdatedInput(from: responseData)
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: Any])
        XCTAssertEqual(answers["请选择多个选项，也可以补充自定义内容"] as? String, "Alpha, Beta, Gamma, custom, value")

        let details = try XCTUnwrap(updatedInput["_codeislandAnswerDetails"] as? [String: Any])
        let answerDetails = try XCTUnwrap(details["请选择多个选项，也可以补充自定义内容"] as? [String: Any])
        XCTAssertEqual(answerDetails["selectedOptions"] as? [String], ["Alpha, Beta", "Gamma"])
        XCTAssertEqual(answerDetails["customInput"] as? String, "custom, value")
    }

    func testMultiSelectWithoutOptionsPreservesFreeTextAsCustomInput() async throws {
        let appState = AppState()
        var freeTextQuestion = question(
            header: "补充说明",
            text: "请填写补充内容",
            options: []
        )
        freeTextQuestion["multiSelect"] = true
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-free-text-multi",
            questions: [freeTextQuestion],
            source: "opencode"
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "请填写补充内容",
                answer: "自由输入",
                selectedOptions: [],
                customInput: "自由输入"
            ),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let updatedInput = try extractUpdatedInput(from: responseData)
        let details = try XCTUnwrap(updatedInput["_codeislandAnswerDetails"] as? [String: Any])
        let answerDetails = try XCTUnwrap(details["请填写补充内容"] as? [String: Any])
        XCTAssertNil(answerDetails["selectedOptions"])
        XCTAssertEqual(answerDetails["customInput"] as? String, "自由输入")
    }

    /// #332: OpenCode answers multi-select questions with label arrays (v1
    /// `string[]`, v2 multiselect form field). The plugin can only rebuild
    /// them from the structured picks — the display string is ", "-joined.
    func testOpenCodeQuestionsCarryStructuredAnswerDetails() async throws {
        let appState = AppState()
        var multiQuestion = question(header: "Targets", text: "Which targets?", options: ["macOS, arm64", "iOS"])
        multiQuestion["multiSelect"] = true
        let event = try makeAskUserQuestionEvent(
            sessionId: "opencode-ses_multi",
            questions: [multiQuestion],
            source: "opencode"
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "Which targets?",
                answer: "macOS, arm64, iOS",
                selectedOptions: ["macOS, arm64", "iOS"],
                customInput: nil
            ),
        ])

        let updatedInput = try extractUpdatedInput(from: await awaitValue(of: responseTask))
        let details = try XCTUnwrap(updatedInput["_codeislandAnswerDetails"] as? [String: Any])
        let picks = try XCTUnwrap(details["Which targets?"] as? [String: Any])
        XCTAssertEqual(picks["selectedOptions"] as? [String], ["macOS, arm64", "iOS"])
    }

    func testQuestionBarFreeTextAnswerPreservesCustomInput() throws {
        let answer = try XCTUnwrap(
            makeQuestionBarFreeTextAnswer(question: "请填写补充内容", text: "自由输入")
        )

        XCTAssertEqual(answer.question, "请填写补充内容")
        XCTAssertEqual(answer.answer, "自由输入")
        XCTAssertEqual(answer.selectedOptions, [])
        XCTAssertEqual(answer.customInput, "自由输入")
        XCTAssertNil(makeQuestionBarFreeTextAnswer(question: "请填写补充内容", text: ""))
    }

    // MARK: - Single question

    func testAskUserQuestionSingleQuestionWorks() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-2",
            questions: [
                question(header: "语言偏好", text: "你希望我主要使用哪种语言回复？", options: ["中文", "英文"])
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "你希望我主要使用哪种语言回复？",
                answer: "中文",
                selectedOptions: ["中文"],
                customInput: nil
            ),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我主要使用哪种语言回复？"] as? String, "中文")
        let updatedInput = try extractUpdatedInput(from: responseData)
        XCTAssertNil(updatedInput["_codeislandAnswerDetails"])
    }

    func testAskUserQuestionOpensQuestionCardWhenSmartSuppressSeesGhosttyFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let sessionId = "s-smart-question"
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = "com.mitchellh.ghostty"
        appState.sessions[sessionId] = session
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: sessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the Ghostty-backed session frontmost")

        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "继续吗", text: "需要用户确认下一步吗？", options: ["继续", "停止"])
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)
        let surfaceAfterRequest = appState.surface

        appState.skipQuestion()
        _ = try await awaitValue(of: responseTask)

        XCTAssertEqual(
            surfaceAfterRequest,
            .questionCard(sessionId: sessionId),
            "AskUserQuestion must open its card even when Smart Suppress considers the Ghostty-backed terminal frontmost; otherwise OMP waits on CodeIsland while the native terminal dialog is blocked."
        )
    }

    /// Claude Desktop shows the question in its own conversation, and
    /// answering there ends the hook: with Claude in front, no card pops.
    func testAskUserQuestionStaysHiddenWhileClaudeDesktopIsFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let sessionId = "s-desktop-question"
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.anthropic.claudefordesktop"
        appState.sessions[sessionId] = session

        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "继续吗", text: "需要用户确认下一步吗？", options: ["继续", "停止"])
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .collapsed)

        appState.handlePeerDisconnect(sessionId: sessionId)
        _ = try await awaitValue(of: responseTask)
        XCTAssertTrue(appState.questionQueue.isEmpty, "answering in Claude Desktop drains the island's copy")
    }

    func testAskUserQuestionQueueOpensNextQuestionCardWhenSmartSuppressSeesGhosttyFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let frontmostBundleId = "com.mitchellh.ghostty"
        let firstSessionId = "s-smart-question-first"
        let secondSessionId = "s-smart-question-second"
        var firstSession = SessionSnapshot()
        firstSession.termApp = "Ghostty"
        firstSession.termBundleId = frontmostBundleId
        var secondSession = SessionSnapshot()
        secondSession.termApp = "Ghostty"
        secondSession.termBundleId = frontmostBundleId
        appState.sessions[firstSessionId] = firstSession
        appState.sessions[secondSessionId] = secondSession
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: firstSessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the first Ghostty-backed session frontmost")
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: secondSessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the second Ghostty-backed session frontmost")

        let firstEvent = try makeAskUserQuestionEvent(
            sessionId: firstSessionId,
            questions: [
                question(header: "第一步", text: "先处理第一个问题吗？", options: ["继续", "停止"])
            ]
        )
        let secondEvent = try makeAskUserQuestionEvent(
            sessionId: secondSessionId,
            questions: [
                question(header: "第二步", text: "现在处理第二个问题吗？", options: ["继续", "停止"])
            ]
        )

        let firstResponseTask = await startHookRequest { appState.handleAskUserQuestion(firstEvent, continuation: $0) }
        let secondResponseTask = await startHookRequest { appState.handleAskUserQuestion(secondEvent, continuation: $0) }
        let queueCountAfterEnqueue = appState.questionQueue.count

        appState.skipQuestion()
        _ = try await awaitValue(of: firstResponseTask)
        let queueCountAfterPromotingSecond = appState.questionQueue.count
        let surfaceAfterPromotingSecond = appState.surface

        appState.skipQuestion()
        _ = try await awaitValue(of: secondResponseTask)

        XCTAssertEqual(queueCountAfterEnqueue, 2)
        XCTAssertEqual(queueCountAfterPromotingSecond, 1)
        XCTAssertEqual(
            surfaceAfterPromotingSecond,
            .questionCard(sessionId: secondSessionId),
            "showNextPending must open the next AskUserQuestion card even when Smart Suppress considers that Ghostty-backed terminal frontmost; otherwise queued OMP questions remain hidden behind the compact badge."
        )
    }

    // MARK: - Skip returns deny

    func testSkipAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-skip",
            questions: [
                question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.skipQuestion()

        let responseData = try await awaitValue(of: responseTask)
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    // MARK: - Disconnect drains with deny

    func testDisconnectDuringAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        let sessionId = "s-disconnect"
        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.handlePeerDisconnect(sessionId: sessionId)

        let responseData = try await awaitValue(of: responseTask)
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    // MARK: - Permission queue does not overwrite

    func testTwoPermissionRequestsKeepFirstVisibleUntilHandled() async throws {
        let appState = AppState()
        let sessionId = "s-perm"

        let event1 = try makePermissionRequestEvent(
            sessionId: sessionId,
            description: "first approval",
            command: "echo 1"
        )
        let event2 = try makePermissionRequestEvent(
            sessionId: sessionId,
            description: "second approval",
            command: "echo 2"
        )

        let r1 = await startHookRequest { appState.handlePermissionRequest(event1, continuation: $0) }

        let r2 = await startHookRequest { appState.handlePermissionRequest(event2, continuation: $0) }

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.currentTool, "Bash")
        XCTAssertEqual(appState.toolDescription, "first approval\nCommand:\necho 1")

        appState.approvePermission()
        let response1 = try await awaitValue(of: r1)
        XCTAssertEqual(try extractPermissionBehavior(from: response1), "allow")

        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.toolDescription, "second approval\nCommand:\necho 2")

        appState.denyPermission()
        let response2 = try await awaitValue(of: r2)
        XCTAssertEqual(try extractPermissionBehavior(from: response2), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPermissionRequestKeepsSessionListSurfaceWhenAlreadyOpen() async throws {
        let appState = AppState()
        appState.surface = .sessionList

        let event = try makePermissionRequestEvent(
            sessionId: "s-list",
            description: "needs approval",
            command: "echo 1"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.surface, .sessionList)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.surface, .sessionList)
    }

    func testAnswerKeepsScalarAnswerKey() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-claude-answer-key",
            questions: [
                question(header: "确认", text: "继续执行吗？", options: ["继续", "停止"]),
            ],
            source: "claude"
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            (question: "继续执行吗？", answer: "继续"),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let updatedInput = try extractUpdatedInput(from: responseData)
        XCTAssertEqual(updatedInput["answer"] as? String, "继续")
    }

    // MARK: - Duplicate question text dedup

    func testDuplicateQuestionTextGetsDedupedKeys() async throws {
        // Answer keys are the question text (matching Claude Code's
        // `answers[question.question]` lookup). Two questions sharing the same
        // text get a suffixed key so each answer stays addressable.
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup",
            questions: [
                question(header: "偏好", text: "重复的问题", options: ["A", "B"]),
                question(header: "其他", text: "重复的问题", options: ["C", "D"]),
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            (question: "重复的问题", answer: "A"),
            (question: "重复的问题", answer: "D"),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["重复的问题"] as? String, "A")
        XCTAssertEqual(answers["重复的问题_2"] as? String, "D")
    }

    // MARK: - Answer key ignores header

    func testAnswerKeyUsesQuestionTextRegardlessOfHeader() async throws {
        // header used to be the answer key but no longer participates. Even
        // when header is nil or empty, the key stays the question text so
        // Claude Code's `answers[question.question]` lookup resolves.
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-nohdr",
            questions: [
                question(header: nil, text: "没有 header", options: ["A", "B"]),
                question(header: "", text: "空 header", options: ["C", "D"]),
            ]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestionMulti([
            (question: "没有 header", answer: "B"),
            (question: "空 header", answer: "C"),
        ])

        let responseData = try await awaitValue(of: responseTask)
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["没有 header"] as? String, "B")
        XCTAssertEqual(answers["空 header"] as? String, "C")
    }

    // MARK: - Direct answerQuestion blocked

    func testDirectAnswerQuestionIgnoredForAskUserQuestion() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-block",
            questions: [
                question(header: "Q1", text: "Question?", options: ["A", "B"]),
            ]
        )

        _ = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        appState.answerQuestion("A")
        XCTAssertEqual(appState.questionQueue.count, 1, "Queue should not be drained by direct answerQuestion")
    }

    // MARK: - Click-to-jump

    /// Clicking the question card focuses the asking terminal and — when
    /// Auto-Collapse After Jump is on — folds the notch. That fold must not be
    /// confused with Skip: the question stays queued and answerable, in the
    /// terminal or back on the card.
    func testCollapsingAQuestionCardAfterAJumpKeepsItAnswerable() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-jump",
            questions: [question(header: "Mode", text: "Pick one", options: ["A", "B"])]
        )

        let responseTask = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-jump"))

        // What a successful click-to-jump does to the panel.
        appState.surface = .collapsed

        XCTAssertEqual(appState.questionQueue.count, 1, "a jump must not dequeue the question")
        XCTAssertNotNil(appState.pendingQuestion(forSession: "s-jump"))

        appState.answerQuestionMulti([
            (question: "Pick one", answer: "A"),
        ])

        let answers = try extractAnswers(from: await awaitValue(of: responseTask))
        XCTAssertEqual(answers["Pick one"] as? String, "A")
    }

    // MARK: - Helpers

    private func makeAskUserQuestionEvent(
        sessionId: String,
        questions: [[String: Any]],
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": questions
            ]
        ]
        if let source {
            payload["_source"] = source
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStateQuestionFlowTests", code: 1)
        }
        return event
    }

    private func makePermissionRequestEvent(sessionId: String, description: String, command: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": [
                "command": command,
                "description": description,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStateQuestionFlowTests", code: 2)
        }
        return event
    }

    private func question(header: String?, text: String, options: [String], descriptions: [String]? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "question": text,
            "options": options.enumerated().map { index, option in
                ["label": option, "description": descriptions?[safe: index] ?? ""]
            }
        ]
        if let header {
            result["header"] = header
        }
        return result
    }

    private func extractUpdatedInput(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["updatedInput"] as? [String: Any])
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let updatedInput = try extractUpdatedInput(from: responseData)
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
