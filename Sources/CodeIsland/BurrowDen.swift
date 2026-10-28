import SwiftUI
import CodeIslandCore

// MARK: - Words

/// How long ago, in the den's voice: "刚刚", "3 分钟", "2 小时".
enum BurrowTime {
    static func since(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let l10n = L10n.shared
        if seconds < 60 { return l10n["burrow_time_now"] }
        if seconds < 3600 { return String(format: l10n["burrow_time_min"], Int(seconds / 60)) }
        return String(format: l10n["burrow_time_hour"], Int(seconds / 3600))
    }

    /// The time a den row shows, only where it tells you something: how long
    /// it has waited on you, rested, or since it failed. A working row has
    /// none — it would always say "just now".
    static func row(_ status: SessionCardStatus, since date: Date, now: Date = Date()) -> String? {
        let l10n = L10n.shared
        let ago = since(date, now: now)
        let fresh = now.timeIntervalSince(date) < 60
        switch status {
        case .working, .thinking: return nil
        case .needsYou: return fresh ? ago : String(format: l10n["burrow_time_waited"], ago)
        case .done, .idle, .stopped: return fresh ? ago : String(format: l10n["burrow_time_rested"], ago)
        case .error: return fresh ? ago : String(format: l10n["burrow_time_ago"], ago)
        }
    }
}

/// The words after a conversation's title in the den: what it is doing.
enum BurrowActivity {
    struct Line: Equatable {
        let text: String
        /// A shell command, set in monospace.
        var command = false
        /// The command itself when the line says it in everyday words: the
        /// row's tooltip.
        var raw: String? = nil
    }

    /// A row's tooltip: the whole title, the project it runs in, then the
    /// command itself or the last prompt — what tells two alike rows apart
    /// (design/v20 review).
    static func help(for session: SessionSnapshot, line: Line) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = session.cwd.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        return [session.burrowName, folder, line.raw ?? session.lastUserPrompt]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func line(for session: SessionSnapshot, pendingTool: String?, pendingInput: [String: Any]?) -> Line {
        let l10n = L10n.shared
        switch SessionCardStatus(session) {
        case .needsYou:
            if let tool = pendingTool {
                if let command = BurrowApprovalDanger.command(tool: tool, toolInput: pendingInput) {
                    // In everyday words, for people who don't read shell (design/v20).
                    if let gist = CommandGist.of(command) {
                        return Line(text: CommandGist.wants(gist), raw: command)
                    }
                    return Line(text: command, command: true)
                }
                return Line(text: ApprovalCopy.title(tool: tool, toolInput: pendingInput))
            }
            return Line(text: l10n["burrow_what_question"])
        case .working:
            let tool = session.currentTool.map { ToolNameDisplay.compact($0) } ?? ""
            let detail = session.toolDescription ?? ""
            let sign = BurrowPetSign.tool(session.currentTool)
            if sign == .shell, !detail.isEmpty {
                return shell(detail)
            }
            // The row's sign already says what kind of tool it is.
            let signed = sign.map { $0 != .other } ?? false
            let text = (signed && !detail.isEmpty) ? detail : [tool, detail].filter { !$0.isEmpty }.joined(separator: " ")
            return Line(text: text.isEmpty ? l10n["burrow_what_thinking"] : text)
        case .thinking:
            // Between steps Codex says what it is about to do; that beats
            // "thinking…" for the minutes a long turn spends reasoning.
            if let note = session.liveCodexOutput, !note.isEmpty {
                return Line(text: String(IslandMarkdownInline.preview(note, singleLine: true).characters))
            }
            return Line(text: l10n["burrow_what_thinking"])
        case .done:
            if let reply = session.lastAssistantMessage, !reply.isEmpty {
                return Line(text: String(IslandMarkdownInline.preview(reply, singleLine: true).characters))
            }
            return Line(text: session.lastUserPrompt ?? l10n["burrow_what_idle"])
        case .idle:
            return Line(text: l10n["burrow_what_idle"])
        case .stopped:
            return Line(text: l10n["burrow_what_stopped"])
        case .error:
            return Line(text: l10n["burrow_what_error"])
        }
    }

    /// A running shell tool's line: what the command does in everyday words
    /// when Burrow knows the program, else the agent's own description, else
    /// "运行 X"; the command itself only when there is nothing to say.
    /// `detail` is the command, or "description\nCommand:\ncommand".
    static func shell(_ detail: String) -> Line {
        let parts = detail.components(separatedBy: "\nCommand:\n")
        let command = parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : detail
        let gist = CommandGist.of(command)
        if let gist, gist.known { return Line(text: gist.text, raw: command) }
        // A description alone ("Run the tests", "运行测试"): no command starts
        // with a capitalised or Chinese word — but "DIR=… ./build.sh" does.
        let firstWord = detail.prefix { $0 != " " }
        let prose = parts.count == 1 && !firstWord.contains("=") && !firstWord.contains("/")
            && (firstWord.first.map { $0.isUppercase || !$0.isASCII } ?? false)
        if prose { return Line(text: detail) }
        let description = parts.count > 1 ? parts[0] : nil
        if let description, !description.isEmpty { return Line(text: description, raw: command) }
        if let gist { return Line(text: gist.text, raw: command) }
        return Line(text: command, command: true)
    }
}

// MARK: - Header

/// The den's top strip, level with the notch: who is home on the left,
/// sound / settings / quit on the right. Both sides stay clear of the
/// hardware notch in the middle.
struct BurrowDenHeader: View {
    let appState: AppState
    let notchWidth: CGFloat
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @StateObject private var quit: QuitConfirmation

    /// `quit` is injectable so a render test can show the armed state.
    init(appState: AppState, notchWidth: CGFloat, quit: QuitConfirmation = QuitConfirmation()) {
        self.appState = appState
        self.notchWidth = notchWidth
        _quit = StateObject(wrappedValue: quit)
    }

    private var leftLabel: String {
        let l10n = L10n.shared
        if appState.denShowsSettings { return l10n["burrow_back_title"] }
        switch appState.surface {
        case .approvalCard, .questionCard: return l10n["burrow_header_waiting"]
        default:
            // Pets are agents, and you can count them beside the notch; once
            // an agent has several conversations, the den counts those.
            let chats = appState.sessions.count
            guard chats > 0 else { return l10n["burrow_header_empty"] }
            let pets = Set(appState.sessions.values.map { BurrowResidents.agent(of: $0) }).count
            return chats > pets
                ? String(format: l10n["burrow_header_chats"], chats)
                : String(format: l10n["burrow_header_count"], pets)
        }
    }

    var body: some View {
        // Two equal sides around a gap exactly under the notch, so nothing
        // on either side can slide beneath it.
        HStack(spacing: 0) {
            Text(leftLabel)
                .font(Burrow.font(Burrow.Size.small, .semibold))
                .foregroundStyle(Burrow.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth > 0 ? notchWidth + 8 : 8)
            controls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }

    /// Sound, settings, quit. While quit asks "sure?", the confirm button
    /// stands alone, so the side never outgrows its half. On the den's back
    /// (its settings) only the way back is left.
    @ViewBuilder private var controls: some View {
        HStack(spacing: 2) {
            if appState.denShowsSettings {
                BurrowIconButton(systemName: "arrow.left", help: L10n.shared["burrow_back_return"]) {
                    withAnimation(BurrowFlip.animation) { appState.denShowsSettings = false }
                }
            } else {
                if !quit.isArmed {
                    BurrowIconButton(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                     help: L10n.shared["sound"]) { soundEnabled.toggle() }
                    BurrowIconButton(systemName: "gearshape.fill", help: L10n.shared["settings_title"]) {
                        withAnimation(BurrowFlip.animation) { appState.showSettings() }
                    }
                }
                if quit.isArmed {
                    Button { quit.press() } label: {
                        Text(L10n.shared["quit_confirm"])
                            .font(Burrow.font(10.5, .bold))
                            .foregroundStyle(Burrow.onInk)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(Burrow.ember))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.shared["quit_confirm_hint"])
                    .onHover { if !$0 { quit.cancel() } }
                } else {
                    BurrowIconButton(systemName: "power", help: L10n.shared["quit"]) { quit.press() }
                }
            }
        }
    }
}

// MARK: - The den (session list)

/// The open burrow: one block per agent, its pet standing on the left with
/// its name under it (design/v19), two lines per conversation (design/v20).
/// The pet is the one beside the notch; it flies here when the den opens.
struct BurrowDen: View {
    let appState: AppState
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @ObservedObject private var reactions = PetReactionCenter.shared
    @ObservedObject private var animationGate = MascotAnimationGate.shared
    @State private var orderFreeze = SessionOrderFreeze()
    @State private var thawTask: Task<Void, Never>?

    /// Conversations in the den's priority, each agent's kept together.
    private var liveOrder: [String] {
        BurrowResidents.grouped(appState.sessionListOrder(), appState: appState).flatMap(\.ids)
    }

    var body: some View {
        let ids = orderFreeze.apply(liveOrder)
        let pets = Dictionary(
            BurrowResidents.agents(appState: appState, reactions: reactions, animating: !animationGate.isIdleSettled)
                .map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let groups = BurrowResidents.grouped(ids, appState: appState)
        VStack(alignment: .leading, spacing: 2) {
            if ids.isEmpty {
                Text(L10n.shared["burrow_empty_body"])
                    .font(Burrow.font(Burrow.Size.body))
                    .foregroundStyle(Burrow.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                let blocks = VStack(alignment: .leading, spacing: BurrowDenMetrics.blockSpacing) {
                    ForEach(groups, id: \.agent) { group in
                        BurrowAgentBlock(appState: appState, ids: group.ids,
                                         pet: pets[BurrowResidents.heroId(agent: group.agent)])
                    }
                }
                // The den never grows taller than five of the old two-line rows.
                let cap = CGFloat(maxVisibleSessions) * 54
                if BurrowDenMetrics.height(rows: groups.map(\.ids.count)) > cap {
                    ScrollView(.vertical) { blocks }
                        .frame(height: cap)
                        .scrollIndicators(.never)
                } else {
                    blocks
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 12)
        // While the pointer is over the den its rows hold still, so a click
        // lands on the row it was aimed at.
        .onHover { inside in
            thawTask?.cancel()
            if inside {
                orderFreeze.freeze(liveOrder)
            } else {
                thawTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: SessionOrderFreeze.releaseDelay)
                    guard !Task.isCancelled else { return }
                    withAnimation(Burrow.settle) { orderFreeze.thaw() }
                }
            }
        }
    }
}

/// The den's sizes, so its height can be known before it is laid out.
enum BurrowDenMetrics {
    /// Two lines: the title and its time, then what it is doing (design/v20).
    static let rowHeight: CGFloat = 36
    /// Both lines are one size, bold (design/v20: Jarvis wanted them alike
    /// and a little bigger); the second line is told apart by its colour.
    static let textSize: CGFloat = 13
    /// The pet and its name plate.
    static let petColumn: CGFloat = 56
    static let petBlockHeight: CGFloat = 44
    static let blockPadding: CGFloat = 4
    static let blockSpacing: CGFloat = 2

    static func blockHeight(rows: Int) -> CGFloat {
        max(CGFloat(rows) * rowHeight, petBlockHeight) + 2 * blockPadding
    }

    /// All the blocks for agents with these many conversations each.
    static func height(rows: [Int]) -> CGFloat {
        rows.map(blockHeight).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * blockSpacing
    }
}

/// One agent in the den: its pet and name on the left, its conversations
/// two lines each on the right.
struct BurrowAgentBlock: View {
    let appState: AppState
    let ids: [String]
    let pet: BurrowPeekPet?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 1) {
                if let pet {
                    MascotView(source: pet.source, status: pet.status, size: Burrow.petSize, sessionId: pet.reactionSessionId)
                        .frame(width: Burrow.petSize, height: Burrow.petSize)
                        .burrowNightLight(BurrowLipMetrics.isLit(pet.state), rows: pet.rows, size: Burrow.petSize)
                        .burrowHero(pet.id)
                        .frame(width: 30, height: 30)
                }
                if let session = ids.first.flatMap({ appState.sessions[$0] }) {
                    BurrowAgentName(source: session.mascotSource, label: session.sourceLabel)
                }
            }
            .frame(width: BurrowDenMetrics.petColumn)
            .padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(ids, id: \.self) { sid in
                    if let session = appState.sessions[sid] {
                        BurrowSessionRow(appState: appState, session: session, sessionId: sid)
                    }
                }
            }
        }
        .padding(.vertical, BurrowDenMetrics.blockPadding)
        .frame(minHeight: BurrowDenMetrics.blockHeight(rows: ids.count), alignment: .top)
    }
}

/// The agent's name under its pet in the den, in the pet's own colours.
struct BurrowAgentName: View {
    let source: String
    let label: String

    /// "Google Antigravity" → "Antigravity": the plate is a pet's width.
    static func short(_ label: String) -> String {
        label.hasPrefix("Google ") ? String(label.dropFirst("Google ".count)) : label
    }

    var body: some View {
        let ink = (PetSpecies.of(source: source)?.ink ?? [0x9B958D]).map { Color(petRGB: $0) }
        Text(Self.short(label))
            .font(Burrow.font(9.5, .heavy))
            .foregroundStyle(LinearGradient(colors: ink.count > 1 ? ink : [ink[0], ink[0]], startPoint: .leading, endPoint: .trailing))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 2)
    }
}

struct BurrowSessionRow: View {
    let appState: AppState
    let session: SessionSnapshot
    let sessionId: String
    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump
    @State private var hovering = false

    private var status: SessionCardStatus { SessionCardStatus(session) }

    /// The turn finished since the look at the den before this one: its
    /// spark is the row's sign and what it said is lit.
    private var fresh: Bool {
        BurrowSpark.isUnseen(session, doneAt: appState.turnDoneAt[sessionId], seenAt: appState.denLookBefore)
    }

    var body: some View {
        let pending = appState.pendingPermission(forSession: sessionId)
        let line = BurrowActivity.line(for: session, pendingTool: pending?.event.toolName, pendingInput: pending?.event.toolInput)
        let fresh = fresh
        // The title on the first line; what it is doing has the whole second
        // line (design/v20: one line left it a word or two).
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                BurrowRowSign(kind: BurrowRowSign.Kind(status: status, sign: BurrowPetSign.of(session), fresh: fresh))
                    .frame(width: 14, height: 12)
                Text(session.burrowName)
                    .font(Burrow.font(BurrowDenMetrics.textSize, .bold))
                    .foregroundStyle(!fresh && (status == .idle || status == .done || status == .stopped) ? Burrow.ink.opacity(0.8) : Burrow.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let time = BurrowTime.row(status, since: session.lastActivity) {
                    Text(time)
                        .font(Burrow.font(10, status == .needsYou ? .bold : .regular))
                        .foregroundStyle(status == .needsYou ? Burrow.amber : fresh ? Burrow.ink : Burrow.dim)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: 18)
            Text(line.text)
                .font(line.command ? Burrow.mono(BurrowDenMetrics.textSize - 1, .bold) : Burrow.font(BurrowDenMetrics.textSize, .bold))
                .foregroundStyle(status == .needsYou || fresh ? Burrow.ink : status == .error ? Burrow.ember : Burrow.dim)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 20)
                .frame(height: 18, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: BurrowDenMetrics.rowHeight, maxHeight: BurrowDenMetrics.rowHeight, alignment: .leading)
        .background(
            ZStack {
                // The one that needs you is lit by its pet's night light.
                if status == .needsYou {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(RadialGradient(colors: [Burrow.amber.opacity(0.16), Burrow.amber.opacity(0)],
                                             center: UnitPoint(x: 0.03, y: 0.5), startRadius: 0, endRadius: 120))
                }
                RoundedRectangle(cornerRadius: 10).fill(hovering ? Burrow.hover : .clear)
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .onTapGesture { open() }
        .help(BurrowActivity.help(for: session, line: line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([session.sourceLabel, session.burrowName, status.label, line.text].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    /// A row that needs you opens its card; any other row jumps to the
    /// agent's window.
    private func open() {
        if appState.pendingPermission(forSession: sessionId) != nil {
            appState.reopenPermissionCard(sessionId: sessionId)
            return
        }
        if appState.pendingQuestion(forSession: sessionId) != nil {
            appState.openPendingQuestionCard(sessionId: sessionId)
            return
        }
        TerminalActivator.activate(session: session, sessionId: sessionId)
        guard autoCollapseAfterSessionJump else { return }
        withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
    }
}

/// The small sign at the start of a den row — the same pixels a pet shows
/// above its laptop beside the notch, so the den and the notch say "running
/// a command" the same way. A row that needs you has a small lamp, one that
/// failed an ember, one that finished since you last looked a spark; a
/// resting row has nothing.
struct BurrowRowSign: View {
    enum Kind: Equatable {
        case sign(PetSign)
        case lamp
        case ember
        case spark
        case none

        init(status: SessionCardStatus, sign: PetSign?, fresh: Bool = false) {
            switch status {
            case .needsYou: self = .lamp
            case .error: self = .ember
            case .working, .thinking: self = sign.map { .sign($0) } ?? .none
            case .done: self = fresh ? .spark : .none
            case .idle, .stopped: self = .none
            }
        }
    }

    let kind: Kind

    var body: some View {
        let cell = Burrow.petCell
        switch kind {
        case .none:
            Color.clear
        case .lamp:
            MascotTimeline(interval: 0.1, staticTime: BurrowNightLight.period / 4) { t in
                let breath = 0.5 - 0.5 * cos(2 * .pi * t / BurrowNightLight.period)
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .radialGradient(Gradient(colors: [Burrow.amber.opacity(0.35 + 0.25 * breath), Burrow.amber.opacity(0)]),
                                                   center: c, startRadius: 0, endRadius: 7))
                    ctx.fill(Path(CGRect(x: c.x - cell, y: c.y - cell, width: 2 * cell, height: 2 * cell)), with: .color(Burrow.amber))
                }
            }
        case .spark:
            BurrowSpark(still: true)
        case .ember:
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(x: size.width / 2 - cell, y: size.height / 2 - cell, width: 2 * cell, height: 2 * cell)),
                         with: .color(Burrow.ember))
            }
        case .sign(let sign):
            Canvas { ctx, size in
                let rows = sign.pixelRows
                let w = CGFloat(rows.first?.count ?? 0) * cell, h = CGFloat(rows.count) * cell
                let x0 = ((size.width - w) / 2 / 0.5).rounded() * 0.5, y0 = ((size.height - h) / 2 / 0.5).rounded() * 0.5
                for (j, row) in rows.enumerated() {
                    for (i, rgb) in row.enumerated() {
                        guard let rgb else { continue }
                        ctx.fill(Path(CGRect(x: x0 + CGFloat(i) * cell, y: y0 + CGFloat(j) * cell, width: cell, height: cell)),
                                 with: .color(Color(petRGB: rgb)))
                    }
                }
            }
        }
    }
}

// MARK: - Cards

/// The top of every card: the pet beside what it wants, at the size it has
/// beside the notch and in the den — no bigger than it needs to be
/// (design/v20: Jarvis wants the information, not a big card). Its pose
/// follows the session (attention while it waits on you).
struct BurrowCardStage: View {
    let session: SessionSnapshot?
    let sessionId: String
    let title: String
    let subtitle: String
    /// The pet stands in its night light: the card is waiting on you.
    var lit = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        let source = session?.mascotSource ?? "claude"
        HStack(alignment: .center, spacing: 8) {
            MascotView(source: source,
                       status: session?.status ?? .idle,
                       size: Burrow.petSize,
                       sessionId: sessionId)
                .frame(width: Burrow.petSize, height: Burrow.petSize)
                .burrowNightLight(lit, rows: PeekRows.forSource(source) ?? PeekRows(bodyTop: 5, eyeBottom: 8, bodyBottom: 14), size: Burrow.petSize)
                .frame(width: 30, height: 30)
                // Room above for the pet's "!", hearts and confetti.
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Burrow.font(13, .bold))
                    .foregroundStyle(Burrow.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(Burrow.font(Burrow.Size.caption))
                    .foregroundStyle(Burrow.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// Session context for a card subtitle: "Claude · CodeIsland · 已等 12 秒".
enum BurrowCardSubtitle {
    /// Under an approval card's title (the conversation): the agent and what
    /// it asks for, "OpenCode · Bash 请求运行命令".
    static func approval(session: SessionSnapshot?, ask: String, queue: String?) -> String {
        var parts: [String] = []
        if let session { parts.append(session.sourceLabel); parts.append(ask) }
        if let queue { parts.append(queue) }
        return parts.joined(separator: " · ")
    }

    static func text(session: SessionSnapshot?, extra: String? = nil) -> String {
        var parts: [String] = []
        if let session {
            parts.append(session.sourceLabel)
            parts.append(session.displayName)
        }
        if let extra { parts.append(extra) }
        return parts.joined(separator: " · ")
    }
}

/// "Antigravity 想运行一条命令": the pet holds up the command like a sign.
struct BurrowApprovalCard: View {
    let tool: String
    let toolInput: [String: Any]?
    let queuePosition: Int
    let queueTotal: Int
    let session: SessionSnapshot?
    let sessionId: String
    let appState: AppState
    var alwaysSavesRule = false
    let onAllow: () -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void
    let onDismiss: () -> Void

    @State private var shake: CGFloat = 0
    @State private var jumpTask: Task<Void, Never>?
    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump


    var body: some View {
        let queue = NotchCardQueueLabel.text(position: queuePosition, total: queueTotal)
        let command = BurrowApprovalDanger.command(tool: tool, toolInput: toolInput)
        let danger = command.map(DangerousCommand.matches(in:)) ?? []
        // The conversation is the title; what the agent asks for is the
        // command itself, the biggest words on the card (design/v19). Under
        // the title, what the command does in everyday words (design/v20).
        let ask = command.flatMap { CommandGist.of($0) }.map { CommandGist.wants($0) }
            ?? ApprovalCopy.title(tool: tool, toolInput: toolInput)
        VStack(alignment: .leading, spacing: 8) {
            BurrowCardStage(
                session: session,
                sessionId: sessionId,
                title: session?.burrowName ?? ask,
                subtitle: BurrowCardSubtitle.approval(session: session, ask: ask, queue: queue),
                lit: true,
                onTap: jump
            )
            if toolInput != nil {
                VStack(alignment: .leading, spacing: 5) {
                    PanelFittedScrollArea(minimumHeight: 30) {
                        Group {
                            if let command {
                                BurrowCommandText(command: command, danger: danger,
                                                  description: toolInput?["description"] as? String)
                            } else {
                                ApprovalToolDetailView(tool: tool, toolInput: toolInput)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(RoundedRectangle(cornerRadius: Burrow.wellRadius).fill(Burrow.well))
                    .overlay(RoundedRectangle(cornerRadius: Burrow.wellRadius).strokeBorder(Burrow.wellEdge, lineWidth: 1))
                    if let first = danger.first {
                        Text(BurrowApprovalDanger.reason(first.kind))
                            .font(Burrow.font(Burrow.Size.caption))
                            .foregroundStyle(Burrow.ember)
                            .padding(.horizontal, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Three answers and no "always allow" (design/v20 review: one
            // choice fewer to understand). A command that can't be undone has
            // no filled default either.
            HStack(spacing: 8) { Spacer(minLength: 0); buttons(dangerous: !danger.isEmpty) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .offset(x: shake)
        .onDisappear { jumpTask?.cancel() }
    }

    @ViewBuilder private func buttons(dangerous: Bool) -> some View {
        BurrowButton(label: L10n.shared["card_hide"], quiet: true, help: L10n.shared["dismiss_card_hint"], action: onDismiss)
        BurrowButton(label: L10n.shared["card_deny"], hint: CardShortcutHint.text(for: .deny), action: onDeny)
        BurrowButton(label: L10n.shared["card_allow_once"], hint: CardShortcutHint.text(for: .approve),
                     primary: !dangerous, destructive: dangerous, action: onAllow)
    }

    private func jump() {
        jumpTask?.cancel()
        jumpTask = startNotchCardJump(
            kind: .approval, session: session, sessionId: sessionId, appState: appState,
            autoCollapseAfterJump: autoCollapseAfterSessionJump, shakeOffset: $shake
        )
    }
}

/// The shell command an approval card is for, and which of its words can't
/// be taken back.
enum BurrowApprovalDanger {
    /// The command of a shell tool's approval; nil for any other tool.
    static func command(tool: String, toolInput: [String: Any]?) -> String? {
        guard ApprovalCopy.action(for: tool) == .command else { return nil }
        if let command = toolInput?["command"] as? String { return command }
        if let command = toolInput?["cmd"] as? String { return command }
        if let parts = toolInput?["command"] as? [String] { return parts.joined(separator: " ") }
        return nil
    }

    static func matches(tool: String, toolInput: [String: Any]?) -> [DangerousCommand.Match] {
        command(tool: tool, toolInput: toolInput).map(DangerousCommand.matches(in:)) ?? []
    }

    /// One line under the command: why its red words are red.
    static func reason(_ kind: DangerousCommand.Kind) -> String {
        L10n.shared["danger_" + kind.rawValue]
    }
}

/// The command on an approval card: the card's biggest words, in monospace,
/// its dangerous words in ember with a dotted underline.
struct BurrowCommandText: View {
    let command: String
    let danger: [DangerousCommand.Match]
    var description: String? = nil
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize

    /// Follows Content Font Size like the rest of the card; 12.5pt at the default.
    private var type: NotchCardTypography { NotchCardTypography(contentFontSize: contentFontSize) }

    var attributed: AttributedString {
        var text = AttributedString(command)
        text.foregroundColor = Burrow.ink
        for match in danger {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: text),
                  let upper = AttributedString.Index(match.range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = Burrow.ember
            text[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: Burrow.ember)
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributed)
                .font(Burrow.mono(type.body + 1.5, .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let description, !description.isEmpty {
                Text(description)
                    .font(Burrow.font(type.secondary))
                    .foregroundStyle(Burrow.dim)
            }
        }
    }
}

/// A turn finished (or failed): the pet hops out with the news.
struct BurrowDoneCard: View {
    let appState: AppState
    let sessionId: String
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize

    var body: some View {
        let session = appState.sessions[sessionId]
        let failed = session?.lastTurnFailed == true
        let name = session?.sourceLabel ?? "Agent"
        VStack(alignment: .leading, spacing: 8) {
            BurrowCardStage(
                session: session,
                sessionId: sessionId,
                title: String(format: L10n.shared[failed ? "burrow_fail_title" : "burrow_done_title"], name),
                subtitle: BurrowCardSubtitle.text(session: session, extra: session.map { BurrowTime.since($0.lastActivity) }),
                onTap: jump
            )
            if let reply = session?.lastAssistantMessage, !reply.isEmpty {
                AssistantReplyText(text: reply, fontSize: CGFloat(contentFontSize) + 1, lineLimit: nil, isCompletionReply: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                BurrowButton(label: L10n.shared["burrow_done_ok"]) { close() }
                if session != nil {
                    BurrowButton(label: L10n.shared["burrow_done_jump"], primary: true) { jump() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func close() {
        appState.cancelCompletionQueue()
        withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
    }

    private func jump() {
        guard let session = appState.sessions[sessionId] else { return }
        TerminalActivator.activate(session: session, sessionId: sessionId)
        close()
    }
}
