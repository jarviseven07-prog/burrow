import SwiftUI
import CodeIslandCore

// MARK: - Preview Scenario System
//
// Usage: launch with --preview <scenario> to inject mock sessions for UI development.
//   e.g.  .build/debug/CodeIsland --preview approval
//   Add --collapsed to keep the bar collapsed instead of auto-expanding.
//
// Scenarios:
//   working     — single session actively running tools
//   approval    — session waiting for permission
//   question    — session with pending question
//   completion  — session just finished
//   multi       — 3 sessions in mixed states
//   busy        — heavy workload with subagents
//   claude      — Claude CLI single session
//   codex       — Codex CLI single session
//   opencode    — OpenCode single session
//   antigravity — Google Antigravity single session
//   allcli      — All CLIs running simultaneously

enum PreviewScenario: String, CaseIterable {
    case working
    case approval
    case question
    case completion
    case multi
    case busy
    // CLI-specific scenarios
    case claude
    case codex
    case opencode
    case antigravity
    case allcli
    // Special states
    case idle
    // Performance stress test
    case stress
}

@MainActor
enum DebugHarness {

    /// Check launch arguments for --preview flag, return scenario if found
    static func requestedScenario() -> PreviewScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--preview"), idx + 1 < args.count else { return nil }
        return PreviewScenario(rawValue: args[idx + 1])
    }

    /// `--collapsed`: skip the auto-expand so the compact bar can be inspected.
    static var keepsCollapsed: Bool {
        ProcessInfo.processInfo.arguments.contains("--collapsed")
    }

    /// Inject mock data into appState for the given scenario
    static func apply(_ scenario: PreviewScenario, to appState: AppState) {
        switch scenario {
        case .working:
            applyWorking(to: appState)
        case .approval:
            applyApproval(to: appState)
        case .question:
            applyQuestion(to: appState)
        case .completion:
            applyCompletion(to: appState)
        case .multi:
            applyMulti(to: appState)
        case .busy:
            applyBusy(to: appState)
        case .claude: applyClaude(to: appState)
        case .codex: applyCodex(to: appState)
        case .opencode: applyOpenCode(to: appState)
        case .antigravity: applyAntigravity(to: appState)
        case .allcli: applyAllCLI(to: appState)
        case .idle: applyIdle(to: appState)
        case .stress: applyStress(to: appState)
        }
    }

    // MARK: - Scenarios

    private static func applyWorking(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/Users/dev/my-project"
        s.model = "claude-sonnet-4-20250514"
        s.source = "claude"
        s.currentTool = "Edit"
        s.toolDescription = "src/components/App.tsx"
        s.lastUserPrompt = "Fix the login button styling"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Fix the login button styling"))
        s.recordTool("Read", description: "package.json", success: true, agentType: nil, maxHistory: 20)
        s.recordTool("Grep", description: "className.*login", success: true, agentType: nil, maxHistory: 20)
        s.termApp = "Apple_Terminal"

        state.sessions["preview-working"] = s
        state.activeSessionId = "preview-working"
    }

    private static func applyApproval(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .waitingApproval
        s.cwd = "/Users/dev/api-server"
        s.model = "claude-opus-4-20250514"
        s.source = "claude"
        s.currentTool = "Bash"
        s.toolDescription = "npm run test -- --coverage"
        s.lastUserPrompt = "Run the test suite"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Run the test suite"))
        s.termApp = "Apple_Terminal"

        state.sessions["preview-approval"] = s
        state.activeSessionId = "preview-approval"
        state.surface = .approvalCard(sessionId: "preview-approval")
    }

    private static func applyQuestion(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .waitingQuestion
        s.cwd = "/Users/dev/web-app"
        s.model = "claude-sonnet-4-20250514"
        s.source = "claude"
        s.lastUserPrompt = "Refactor the auth module"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Refactor the auth module"))

        state.sessions["preview-question"] = s
        state.activeSessionId = "preview-question"

        // Inject a mock question payload for UI preview
        state.previewQuestionPayload = QuestionPayload(
            question: "Which approach do you prefer?",
            options: ["Extract service class", "Use middleware pattern", "Inline helpers"],
            descriptions: [
                "Create a dedicated AuthService class with dependency injection",
                "Add Express-style middleware for auth checks",
                "Keep auth logic inline with helper functions"
            ]
        )
        state.surface = .questionCard(sessionId: "preview-question")
    }

    private static func applyCompletion(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .idle
        s.cwd = "/Users/dev/cli-tool"
        s.model = "claude-sonnet-4-20250514"
        s.source = "claude"
        s.lastUserPrompt = "Add --verbose flag"
        s.lastAssistantMessage = "Done. Added the --verbose flag to the CLI parser with short alias -v. It enables detailed logging output throughout the pipeline."
        s.addRecentMessage(ChatMessage(isUser: true, text: "Add --verbose flag"))
        s.addRecentMessage(ChatMessage(isUser: false, text: "Done. Added the --verbose flag to the CLI parser with short alias -v."))
        s.recordTool("Read", description: "src/cli.rs", success: true, agentType: nil, maxHistory: 20)
        s.recordTool("Edit", description: "src/cli.rs", success: true, agentType: nil, maxHistory: 20)
        s.recordTool("Edit", description: "src/logger.rs", success: true, agentType: nil, maxHistory: 20)
        s.recordTool("Bash", description: "cargo test", success: true, agentType: nil, maxHistory: 20)
        s.termApp = "Apple_Terminal"

        state.sessions["preview-completion"] = s
        state.activeSessionId = "preview-completion"
        state.surface = .completionCard(sessionId: "preview-completion")
    }

    private static func applyMulti(to state: AppState) {
        // Session 1: Claude working
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/Users/dev/frontend"
        s1.model = "claude-sonnet-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Write"
        s1.toolDescription = "src/pages/Dashboard.tsx"
        s1.lastUserPrompt = "Build the dashboard page"
        s1.addRecentMessage(ChatMessage(isUser: true, text: "Build the dashboard page"))
        s1.termApp = "Apple_Terminal"
        s1.gitBranch = "main"

        // Session 2: Codex idle, on a linked worktree branch
        var s2 = SessionSnapshot()
        s2.status = .idle
        s2.cwd = "/Users/dev/backend"
        s2.model = "o3"
        s2.source = "codex"
        s2.lastUserPrompt = "Optimize the query planner"
        s2.lastAssistantMessage = "Refactored the query planner to use a cost-based optimizer."
        s2.addRecentMessage(ChatMessage(isUser: true, text: "Optimize the query planner"))
        s2.addRecentMessage(ChatMessage(isUser: false, text: "Refactored the query planner."))
        s2.gitBranch = "feat/query-planner"
        s2.gitIsWorktree = true

        // Session 3: Antigravity thinking
        var s3 = SessionSnapshot()
        s3.status = .processing
        s3.cwd = "/Users/dev/mobile"
        s3.source = "google-antigravity"
        s3.lastUserPrompt = "Fix the scroll jank"
        s3.addRecentMessage(ChatMessage(isUser: true, text: "Fix the scroll jank"))

        state.sessions["preview-multi-1"] = s1
        state.sessions["preview-multi-2"] = s2
        state.sessions["preview-multi-3"] = s3
        state.activeSessionId = "preview-multi-1"
    }

    private static func applyBusy(to state: AppState) {
        // Main Claude session with subagents
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/Users/dev/monorepo"
        s1.model = "claude-opus-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Agent"
        s1.toolDescription = "general-purpose"
        s1.lastUserPrompt = "Migrate the entire codebase to TypeScript 5.5"
        s1.addRecentMessage(ChatMessage(isUser: true, text: "Migrate the entire codebase to TypeScript 5.5"))
        s1.subagents["agent-1"] = SubagentState(agentId: "agent-1", agentType: "general-purpose")
        s1.subagents["agent-2"] = SubagentState(agentId: "agent-2", agentType: "general-purpose")
        s1.subagents["agent-3"] = SubagentState(agentId: "agent-3", agentType: "Explore")
        // Mark one as completed
        s1.subagents["agent-3"]?.status = .idle
        s1.recordTool("Bash", description: "find . -name '*.ts'", success: true, agentType: nil, maxHistory: 20)
        s1.recordTool("Read", description: "tsconfig.json", success: true, agentType: nil, maxHistory: 20)
        s1.recordTool("Edit", description: "tsconfig.json", success: true, agentType: nil, maxHistory: 20)
        s1.recordTool("Bash", description: "tsc --noEmit", success: false, agentType: nil, maxHistory: 20)
        s1.recordTool("Edit", description: "src/index.ts", success: true, agentType: "general-purpose", maxHistory: 20)
        s1.termApp = "Apple_Terminal"

        // Antigravity session
        var s2 = SessionSnapshot()
        s2.status = .processing
        s2.cwd = "/Users/dev/data-pipeline"
        s2.model = "gemini-3-pro"
        s2.source = "google-antigravity"
        s2.lastUserPrompt = "Profile the ETL bottleneck"
        s2.addRecentMessage(ChatMessage(isUser: true, text: "Profile the ETL bottleneck"))

        // Codex session waiting approval
        var s3 = SessionSnapshot()
        s3.status = .waitingApproval
        s3.cwd = "/Users/dev/infra"
        s3.model = "o3"
        s3.source = "codex"
        s3.currentTool = "Bash"
        s3.toolDescription = "terraform apply"
        s3.lastUserPrompt = "Deploy the staging env"
        s3.addRecentMessage(ChatMessage(isUser: true, text: "Deploy the staging env"))

        state.sessions["preview-busy-1"] = s1
        state.sessions["preview-busy-2"] = s2
        state.sessions["preview-busy-3"] = s3
        state.activeSessionId = "preview-busy-1"
    }

    // MARK: - CLI-Specific Scenarios

    private static func applyClaude(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-claude"
        s.model = "claude-opus-4-20250514"
        s.source = "claude"
        s.currentTool = "Edit"
        s.toolDescription = "src/main.swift"
        s.lastUserPrompt = "Refactor the networking layer"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Refactor the networking layer"))
        s.addRecentMessage(ChatMessage(isUser: false, text: "I'll start by reading the current implementation..."))
        s.recordTool("Read", description: "src/Network.swift", success: true, agentType: nil, maxHistory: 20)
        s.recordTool("Grep", description: "URLSession", success: true, agentType: nil, maxHistory: 20)
        s.subagents["agent-1"] = SubagentState(agentId: "agent-1", agentType: "Explore")
        s.termApp = "Apple_Terminal"
        state.sessions["preview-claude"] = s
        state.activeSessionId = "preview-claude"
    }

    private static func applyCodex(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-codex"
        s.model = "o3"
        s.source = "codex"
        s.currentTool = "Bash"
        s.toolDescription = "npm test"
        s.lastUserPrompt = "Fix the failing unit tests"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Fix the failing unit tests"))
        s.termApp = "Terminal"
        state.sessions["preview-codex"] = s
        state.activeSessionId = "preview-codex"
    }

    private static func applyOpenCode(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-opencode"
        s.model = "gpt-4.1"
        s.source = "opencode"
        s.currentTool = "Bash"
        s.toolDescription = "npm test"
        s.lastUserPrompt = "Run the test suite"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Run the test suite"))
        s.termApp = "Apple_Terminal"
        state.sessions["preview-opencode"] = s
        state.activeSessionId = "preview-opencode"
    }

    private static func applyAntigravity(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .processing
        s.cwd = "/tmp/demo-antigravity"
        s.model = "gemini-3-pro"
        s.source = "google-antigravity"
        s.lastUserPrompt = "Review the PR"
        s.addRecentMessage(ChatMessage(isUser: true, text: "Review the PR"))
        state.sessions["preview-antigravity"] = s
        state.activeSessionId = "preview-antigravity"
    }

    private static func applyAllCLI(to state: AppState) {
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/tmp/demo-claude"
        s1.model = "claude-opus-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Agent"
        s1.toolDescription = "general-purpose"
        s1.lastUserPrompt = "Migrate to TypeScript"
        s1.addRecentMessage(ChatMessage(isUser: true, text: "Migrate to TypeScript"))
        s1.subagents["agent-1"] = SubagentState(agentId: "agent-1", agentType: "general-purpose")
        s1.termApp = "Apple_Terminal"

        var s2 = SessionSnapshot()
        s2.status = .running
        s2.cwd = "/tmp/demo-codex"
        s2.model = "o3"
        s2.source = "codex"
        s2.currentTool = "Bash"
        s2.toolDescription = "cargo build"
        s2.lastUserPrompt = "Build the Rust project"
        s2.addRecentMessage(ChatMessage(isUser: true, text: "Build the Rust project"))

        var s3 = SessionSnapshot()
        s3.status = .waitingApproval
        s3.cwd = "/tmp/demo-antigravity"
        s3.model = "gemini-3-pro"
        s3.source = "google-antigravity"
        s3.currentTool = "Bash"
        s3.toolDescription = "rm -rf node_modules"
        s3.lastUserPrompt = "Clean up dependencies"
        s3.addRecentMessage(ChatMessage(isUser: true, text: "Clean up dependencies"))

        var s4 = SessionSnapshot()
        s4.status = .running
        s4.cwd = "/tmp/demo-opencode"
        s4.model = "gpt-4.1"
        s4.source = "opencode"
        s4.currentTool = "Bash"
        s4.toolDescription = "npm test"
        s4.lastUserPrompt = "Run test suite"
        s4.addRecentMessage(ChatMessage(isUser: true, text: "Run test suite"))
        s4.termApp = "Apple_Terminal"

        state.sessions["preview-allcli-1"] = s1
        state.sessions["preview-allcli-2"] = s2
        state.sessions["preview-allcli-3"] = s3
        state.sessions["preview-allcli-4"] = s4
        state.activeSessionId = "preview-allcli-1"
        state.surface = .approvalCard(sessionId: "preview-allcli-3")
    }

    // MARK: - Idle (no sessions)

    private static func applyIdle(to state: AppState) {
        // Clear any discovered sessions, stop discovery, and block new events
        state.stopSessionDiscovery()
        state.sessions.removeAll()
        state.activeSessionId = nil
        state.surface = .collapsed
        // Continuously clear sessions to block hook events during preview
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if !state.sessions.isEmpty {
                    state.sessions.removeAll()
                    state.activeSessionId = nil
                    state.surface = .collapsed
                }
            }
        }
    }

    // MARK: - Stress Test (30 sessions)

    private static func applyStress(to state: AppState) {
        let sources = ["claude", "codex", "opencode", "google-antigravity"]
        let statuses: [AgentStatus] = [.running, .processing, .idle, .waitingApproval, .waitingQuestion]
        let tools = ["Edit", "Read", "Bash", "Write", "Grep", "Agent"]
        let projects = ["frontend", "backend", "api", "mobile", "infra", "docs", "cli", "sdk", "web", "core"]

        for i in 0..<30 {
            var s = SessionSnapshot()
            s.status = statuses[i % statuses.count]
            s.cwd = "/tmp/stress-\(projects[i % projects.count])-\(i)"
            s.model = i % 3 == 0 ? "claude-opus-4-20250514" : "claude-sonnet-4-20250514"
            s.source = sources[i % sources.count]
            s.lastUserPrompt = "Task #\(i): work on \(projects[i % projects.count])"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Task #\(i): work on \(projects[i % projects.count])"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Working on it. Reading files and analyzing the codebase..."))
            if s.status == .running || s.status == .processing {
                s.currentTool = tools[i % tools.count]
                s.toolDescription = "src/module\(i).swift"
            }
            for j in 0..<(i % 5) {
                s.recordTool(tools[j % tools.count], description: "file\(j).ts", success: j % 4 != 0, agentType: nil, maxHistory: 20)
            }
            if i % 7 == 0 {
                s.subagents["agent-\(i)-1"] = SubagentState(agentId: "agent-\(i)-1", agentType: "general-purpose")
            }
            s.termApp = "Apple_Terminal"
            s.lastActivity = Date().addingTimeInterval(Double(-i * 30))
            state.sessions["preview-stress-\(i)"] = s
        }
        state.activeSessionId = "preview-stress-0"
    }
}
