import SwiftUI
import CodeIslandCore

/// Where the pets are while the island is collapsed, and how big it is.
/// Pure numbers, so the feel can be tuned and tested without a window.
///
/// The collapsed island never goes below the menu bar: the windows under it
/// are always yours. The pets stand beside the notch, in the menu bar's own
/// band, each one whole. One that needs you stands in the night light: a
/// warm glow at its feet.
enum BurrowLipMetrics {
    /// One pet's place beside the notch: its 24pt frame and room for the
    /// laptop at its side while it works (the drawing is 30pt wide then).
    static let petSlot: CGFloat = 32
    /// Room left between the outermost pet and the island's edge.
    static let earPad: CGFloat = 4
    /// Room for "+N" when more pets are home than fit.
    static let overflowSlot: CGFloat = 18
    /// At most this many pets show; the rest are "+N".
    static let maxPets = 4
    /// The collapsed island's bottom corners: the notch's own.
    static let bottomRadius: CGFloat = 10

    /// The night light is on only for a pet that needs you.
    static func isLit(_ state: PetState) -> Bool { state == .attention }

    /// Pets left and right of the notch, alternating in the den's order:
    /// the first is just left of the notch, the second just right, and so on.
    static func sides<T>(_ pets: [T]) -> (left: [T], right: [T]) {
        var left: [T] = [], right: [T] = []
        for (i, pet) in pets.enumerated() {
            if i % 2 == 0 { left.append(pet) } else { right.append(pet) }
        }
        return (left, right)
    }

    /// One side's width — the fuller side's, so the notch stays centred.
    static func earWidth(pets: Int, hasOverflow: Bool) -> CGFloat {
        guard pets > 0 || hasOverflow else { return 0 }
        return CGFloat((pets + 1) / 2) * petSlot + earPad + (hasOverflow ? overflowSlot : 0)
    }

    /// One side's width for pets standing `left` and `right` of the notch.
    static func earWidth(left: Int, right: Int, hasOverflow: Bool) -> CGFloat {
        guard left + right > 0 || hasOverflow else { return 0 }
        return CGFloat(max(left, right)) * petSlot + earPad + (hasOverflow ? overflowSlot : 0)
    }

    static func width(notchWidth: CGFloat, left: Int, right: Int, hasOverflow: Bool) -> CGFloat {
        notchWidth + 2 * earWidth(left: left, right: right, hasOverflow: hasOverflow)
    }

    /// The collapsed island: the notch and its two ears.
    static func width(notchWidth: CGFloat, pets: Int, hasOverflow: Bool) -> CGFloat {
        notchWidth + 2 * earWidth(pets: pets, hasOverflow: hasOverflow)
    }

    /// Top of a pet's 24pt frame beside the notch: feet near the bottom of
    /// the menu bar's band. Sprite row r is drawn 1.5·r below the frame's
    /// top (PixelPetView).
    static func earOffset(rows: PeekRows, bandHeight: CGFloat) -> CGFloat {
        bandHeight - CGFloat(rows.bodyBottom + 1) * Burrow.petCell - 2
    }
}

/// Rows of a sprite that peeking cares about.
struct PeekRows: Equatable {
    let bodyTop: Int
    let eyeBottom: Int
    let bodyBottom: Int

    init(bodyTop: Int, eyeBottom: Int, bodyBottom: Int) {
        self.bodyTop = bodyTop
        self.eyeBottom = eyeBottom
        self.bodyBottom = bodyBottom
    }

    init(_ sprite: PetSprite) {
        self.init(bodyTop: sprite.bodyTop, eyeBottom: sprite.eyeBottom, bodyBottom: sprite.bodyBottom)
    }

    /// The rows of the pet a source gets; nil for an agent without a pet of
    /// its own, which takes no place beside the notch.
    static func forSource(_ source: String) -> PeekRows? {
        PetSpecies.of(source: source).map { PeekRows($0.sprite) }
    }
}

extension PetSpecies {
    /// The pet an agent source gets, nil when it has none of its own.
    static func of(source: String) -> PetSpecies? {
        bySource[SessionSnapshot.normalizedSupportedSource(source) ?? source]
    }
}

/// Which sign a working pet shows above its laptop.
enum BurrowPetSign {
    /// Progress labels some agents report where a tool name would go.
    static let progressLabels: Set<String> = [
        "thinking", "reply", "progress", "fallback", "ack", "working", "context",
        "llm", "tool", "post", "waiting", "retry", "question",
    ]

    /// What a conversation is working on; nil unless it is working.
    static func of(_ session: SessionSnapshot) -> PetSign? {
        switch session.status {
        case .running: return tool(session.currentTool) ?? .thinking
        case .processing: return .thinking
        case .idle, .waitingApproval, .waitingQuestion: return nil
        }
    }

    /// A tool's kind — an MCP tool by its own name, not its server's — or
    /// nil for no tool or a progress label.
    static func tool(_ raw: String?) -> PetSign? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !progressLabels.contains(trimmed.lowercased()) else { return nil }
        let name = (trimmed.components(separatedBy: "__").last { !$0.isEmpty } ?? trimmed).lowercased()
        switch name {
        // Codex's own activity labels (HookEvent.activityLabel).
        case "running command": return .shell
        case "editing": return .edit
        case "reading", "searching": return .read
        case "using browser": return .web
        case "delegating": return .agent
        case "bash", "shell", "exec", "exec_command", "local_shell", "run_command",
             "run_terminal_cmd", "terminal", "powershell", "bashoutput", "runcommand":
            return .shell
        case "edit", "multiedit", "write", "notebookedit", "apply_patch", "write_file",
             "edit_file", "create_file", "str_replace_editor", "str_replace_based_edit_tool":
            return .edit
        case "read", "grep", "glob", "ls", "read_file", "list_dir", "list_directory",
             "search", "codebase_search", "find", "view", "notebookread":
            return .read
        case "webfetch", "websearch", "web_search", "fetch", "web_fetch":
            return .web
        case "agent", "task", "subagent", "spawn_agent":
            return .agent
        default:
            return .other
        }
    }

    /// How long a tool's sign stays up into the thinking after it.
    static let lingerSeconds: Double = 1.5
}

/// One pet in the burrow: one per agent, however many conversations it has
/// open. It shows the most pressing of them.
struct BurrowPeekPet: Identifiable, Equatable {
    let id: String          // BurrowResidents.heroId(agent:)
    let source: String
    /// The most pressing status among the agent's conversations.
    let status: AgentStatus
    let state: PetState
    let rows: PeekRows
    /// Conversations this agent has open.
    let sessionCount: Int
    /// The conversation whose reaction (celebrate, heart…) the pet plays.
    let reactionSessionId: String?
    /// A conversation with an approval waiting: a click on the lit pet opens it.
    let waitingSessionId: String?
    /// What the conversation it shows is working on, above its laptop.
    let sign: PetSign?
    /// A conversation with a question waiting: a click on the lit pet opens it.
    var questionSessionId: String? = nil
    /// A conversation's last turn failed since the den was last opened: an
    /// ember stays by the pet until you have looked.
    var failedUnseen = false
    /// A conversation's last turn finished since the den was last opened: a
    /// spark stays by the pet until you have looked.
    var doneUnseen = false
}

/// Who is in the burrow right now: one pet per agent.
@MainActor
enum BurrowResidents {
    /// The agent a conversation belongs to.
    static func agent(of session: SessionSnapshot) -> String {
        SessionSnapshot.normalizedSupportedSource(session.mascotSource) ?? session.mascotSource
    }

    /// The pet's id, shared by the burrow and its den group so it flies
    /// between them.
    static func heroId(agent: String) -> String { "agent:" + agent }

    /// How pressing a status is, for picking what an agent's pet shows.
    static func urgency(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingApproval: return 4
        case .waitingQuestion: return 3
        case .running: return 2
        case .processing: return 1
        case .idle: return 0
        }
    }

    /// Conversation ids grouped by agent: groups in the order their first
    /// conversation appears in `ids` (the den's priority), each group keeping
    /// that order inside.
    static func grouped(_ ids: [String], appState: AppState) -> [(agent: String, ids: [String])] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for sid in ids {
            guard let session = appState.sessions[sid] else { continue }
            let key = agent(of: session)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(sid)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Every agent's pet, most pressing agent first.
    static func agents(appState: AppState, reactions: PetReactionCenter, animating: Bool) -> [BurrowPeekPet] {
        grouped(appState.sessionListOrder(), appState: appState).compactMap { group in
            let sessions = group.ids.compactMap { sid in appState.sessions[sid].map { (sid, $0) } }
            guard let first = sessions.first,
                  let rows = PeekRows.forSource(first.1.mascotSource) else { return nil }
            let status = sessions.map(\.1.status).max { urgency($0) < urgency($1) } ?? .idle
            // The first conversation (den order) in that status speaks for the pet.
            let shown = sessions.first { $0.1.status == status }
            // The latest reaction among its conversations.
            let reacting = sessions.map(\.0)
                .filter { reactions.state(forSession: $0) != nil }
                .max { (reactions.startDate(forSession: $0) ?? .distantPast) < (reactions.startDate(forSession: $1) ?? .distantPast) }
            let state = MascotView.petState(
                status: status,
                reaction: reacting.flatMap { reactions.state(forSession: $0) },
                animating: animating
            )
            return BurrowPeekPet(
                id: heroId(agent: group.agent),
                source: first.1.mascotSource,
                status: status,
                state: state,
                rows: rows,
                sessionCount: sessions.count,
                reactionSessionId: reacting,
                waitingSessionId: sessions.map(\.0).first { appState.pendingPermission(forSession: $0) != nil },
                sign: shown.flatMap { BurrowPetSign.of($0.1) },
                questionSessionId: sessions.map(\.0).first { appState.pendingQuestion(forSession: $0) != nil },
                failedUnseen: sessions.contains { BurrowEmber.isUnseen($0.1, denSeenAt: appState.denSeenAt) },
                doneUnseen: sessions.contains {
                    BurrowSpark.isUnseen($0.1, doneAt: appState.turnDoneAt[$0.0], seenAt: appState.denSeenAt)
                }
            )
        }
    }

    /// The pets beside the notch. Each agent keeps the side of the notch
    /// it first got for as long as it is home (`BurrowSideMemory`), so a
    /// pet never wanders across as statuses change or other agents come and
    /// go. Who shows on a side follows the den's priority (whoever needs you
    /// first); each side holds at most two, so the island never widens.
    static func pets(appState: AppState, reactions: PetReactionCenter, animating: Bool) -> BurrowLayout {
        let all = agents(appState: appState, reactions: reactions, animating: animating)
        var started: [String: Date] = [:]
        for session in appState.sessions.values {
            let id = heroId(agent: agent(of: session))
            started[id] = min(started[id] ?? .distantFuture, session.startTime)
        }
        return appState.burrowSides.arrange(all, started: { started[$0.id] ?? .distantPast })
    }

    /// The card a lit pet holds back — what a hover on it, a click or
    /// VoiceOver's press opens: its waiting approval, else its question.
    /// Nil when the pet is not lit or its card is already on screen.
    static func heldCard(for pet: BurrowPeekPet, surface: IslandSurface) -> BurrowHeldCard? {
        guard BurrowLipMetrics.isLit(pet.state) else { return nil }
        if let sid = pet.waitingSessionId {
            if case .approvalCard = surface { return nil }
            return .approval(sid)
        }
        if let sid = pet.questionSessionId {
            if case .questionCard = surface { return nil }
            return .question(sid)
        }
        return nil
    }

    /// A click or press on the burrow: the hovered lit pet's card first,
    /// then the first lit pet's.
    static func heldCard(pets: [BurrowPeekPet], preferring hoveredPetId: String?, surface: IslandSurface) -> BurrowHeldCard? {
        let hovered = pets.filter { $0.id == hoveredPetId }
        for pet in hovered + pets {
            if let card = heldCard(for: pet, surface: surface) { return card }
        }
        return nil
    }
}

/// A card a lit pet holds back.
enum BurrowHeldCard: Equatable {
    case approval(String)
    case question(String)
}

/// What stands where beside the notch: each side from the notch outward.
struct BurrowLayout: Equatable {
    var left: [BurrowPeekPet]
    var right: [BurrowPeekPet]
    var overflow: Int

    /// Every pet shown, alternating sides from the notch outward.
    var pets: [BurrowPeekPet] {
        var out: [BurrowPeekPet] = []
        for i in 0..<max(left.count, right.count) {
            if i < left.count { out.append(left[i]) }
            if i < right.count { out.append(right[i]) }
        }
        return out
    }
}

/// Which side of the notch each agent lives on. An agent keeps the side
/// it first got while it is home; a newcomer takes the side with fewer
/// agents (left on a tie). Only when departures leave one side two or more
/// agents heavier does one move across — one the island is not showing if
/// there is one, else the newest — because uneven sides would widen the
/// island.
@MainActor
final class BurrowSideMemory {
    enum Side: Equatable { case left, right }

    private(set) var sides: [String: Side] = [:]

    /// `pets` in priority order (den order) → what stands where.
    func arrange(_ pets: [BurrowPeekPet], started: (BurrowPeekPet) -> Date) -> BurrowLayout {
        let present = Set(pets.map(\.id))
        sides = sides.filter { present.contains($0.key) }
        let priority = Dictionary(uniqueKeysWithValues: pets.enumerated().map { ($1.id, $0) })
        let byStart = pets.sorted { a, b in
            let sa = started(a), sb = started(b)
            return sa != sb ? sa < sb : a.id < b.id
        }
        func members(_ side: Side) -> [BurrowPeekPet] { byStart.filter { sides[$0.id] == side } }
        for pet in byStart where sides[pet.id] == nil {
            sides[pet.id] = members(.left).count <= members(.right).count ? .left : .right
        }
        let perSide = BurrowLipMetrics.maxPets / 2
        // The side's pets the island shows: its most pressing two.
        func shown(_ side: Side) -> [BurrowPeekPet] {
            let keep = Set(members(side).sorted { priority[$0.id]! < priority[$1.id]! }.prefix(perSide).map(\.id))
            return members(side).filter { keep.contains($0.id) }
        }
        while true {
            let l = members(.left), r = members(.right)
            guard abs(l.count - r.count) >= 2 else { break }
            let heavy: Side = l.count > r.count ? .left : .right
            let visible = Set(shown(heavy).map(\.id))
            let hidden = members(heavy).filter { !visible.contains($0.id) }
            guard let mover = hidden.last ?? members(heavy).last else { break }
            sides[mover.id] = heavy == .left ? .right : .left
        }
        let left = shown(.left), right = shown(.right)
        return BurrowLayout(left: left, right: right, overflow: pets.count - left.count - right.count)
    }
}

/// The collapsed burrow: pets standing on both sides of the notch.
struct BurrowLip: View {
    let layout: BurrowLayout
    let notchWidth: CGFloat
    let bandHeight: CGFloat
    /// The pet under the pointer: hovering a lit pet opens its card, not the den.
    var hoveredPetId: Binding<String?> = .constant(nil)

    private var pets: [BurrowPeekPet] { layout.pets }
    private var overflow: Int { layout.overflow }

    var body: some View {
        let left = layout.left, right = layout.right
        let ear = BurrowLipMetrics.earWidth(left: left.count, right: right.count, hasOverflow: overflow > 0)
        HStack(spacing: 0) {
            // Each ear clips its own night light: nothing is drawn under the
            // notch, where it could never be seen.
            leftEar(left, width: ear).clipped()
            Color.clear.frame(width: notchWidth)
            rightEar(right, width: ear).clipped()
        }
        .frame(height: bandHeight)
        .animation(Burrow.peek, value: pets.map(\.state))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.shared["burrow_a11y_pets"])
    }

    /// Left of the notch: pets lined up from the notch outward.
    private func leftEar(_ pets: [BurrowPeekPet], width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(pets.reversed()) { slot($0) }
        }
        .frame(width: width, height: bandHeight)
    }

    /// Right of the notch: pets from the notch outward, then "+N".
    private func rightEar(_ pets: [BurrowPeekPet], width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(pets) { slot($0) }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(Burrow.font(10, .semibold))
                    .foregroundStyle(Burrow.dim)
                    .frame(width: BurrowLipMetrics.overflowSlot)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: bandHeight)
    }

    /// A pet in its slot, feet near the bottom of the band.
    private func slot(_ pet: BurrowPeekPet) -> some View {
        petView(pet)
            // The night light flies with its pet into the den.
            .burrowNightLight(BurrowLipMetrics.isLit(pet.state), rows: pet.rows, size: Burrow.petSize)
            .overlay(alignment: .topLeading) {
                // A failure outweighs a finished turn: one mark at a time.
                if pet.failedUnseen, BurrowEmber.shows(on: pet.state) {
                    BurrowEmber().offset(x: BurrowEmber.x, y: BurrowEmber.y)
                } else if pet.doneUnseen, BurrowEmber.shows(on: pet.state) {
                    BurrowSpark().offset(x: BurrowSpark.x, y: BurrowSpark.y)
                }
            }
            .alignmentGuide(.top) { d in d[.top] - BurrowLipMetrics.earOffset(rows: pet.rows, bandHeight: bandHeight) }
            .burrowHero(pet.id)
            .frame(width: BurrowLipMetrics.petSlot, height: bandHeight, alignment: .top)
            // Two or more conversations: how many, in the pet's own colour,
            // above its head on its own side of the slot.
            .overlay(alignment: .topLeading) {
                if pet.sessionCount > 1 {
                    BurrowCountBadge(count: pet.sessionCount, ink: PetSpecies.of(source: pet.source)?.ink ?? [0x9B958D])
                        .padding(.leading, 1)
                        .padding(.top, 1)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredPetId.wrappedValue = pet.id
                } else if hoveredPetId.wrappedValue == pet.id {
                    hoveredPetId.wrappedValue = nil
                }
            }
    }

    private func petView(_ pet: BurrowPeekPet) -> some View {
        BurrowLipPet(pet: pet)
            .frame(width: Burrow.petSize, height: Burrow.petSize)
    }
}

/// A pet beside the notch with its sign. A tool's sign stays up through
/// the moment of thinking before the next tool instead of flickering.
private struct BurrowLipPet: View {
    let pet: BurrowPeekPet
    @State private var held: PetSign?

    var body: some View {
        MascotView(source: pet.source, status: pet.status, size: Burrow.petSize,
                   sessionId: pet.reactionSessionId,
                   sign: pet.sign == nil ? nil : (held ?? pet.sign))
            .task(id: pet.sign) {
                if PetSign.lingers(from: held, to: pet.sign) {
                    try? await Task.sleep(for: .seconds(BurrowPetSign.lingerSeconds))
                    guard !Task.isCancelled else { return }
                }
                held = pet.sign
            }
    }
}

/// The night light: a warm glow that breathes behind a pet that needs you,
/// slow as a sleeping breath — noticeable from the corner of your eye,
/// never a flashing alarm. It sits on a lit floor of pixels at the pet's
/// feet and nothing is drawn below that floor, so the island's own edge
/// never cuts it off (design/v19, A).
struct BurrowNightLight: View {
    static let period: Double = 2.4
    /// The pet's pixel size: 1.5 beside the notch and in the den, 3 on a card.
    let cell: CGFloat

    /// Points of glow above the floor, in pet pixels.
    static let glowCells: CGFloat = 12
    /// The floor's width in pet pixels: the pet's own width.
    static let floorCells = 16

    /// How bright floor pixel `i` (0 ..< floorCells) is: full under the pet,
    /// fading at its two ends.
    static func floorAlpha(_ i: Int) -> Double {
        let d = abs(Double(i) - Double(floorCells - 1) / 2)
        return d < 5 ? 1 : d < 7 ? 0.5 : 0.22
    }

    var body: some View {
        // A 2.4s breath needs no more than 10 frames a second.
        MascotTimeline(interval: 0.1, staticTime: Self.period / 4) { t in
            let breath = 0.5 - 0.5 * cos(2 * .pi * t / Self.period)
            Canvas { ctx, size in
                let floorY = size.height - cell
                let mid = size.width / 2
                let radius = 11.5 * cell
                ctx.fill(
                    Path(CGRect(x: 0, y: floorY - radius, width: size.width, height: radius)),
                    with: .radialGradient(
                        Gradient(colors: [Burrow.amber.opacity(0.42 + 0.3 * breath), Burrow.amber.opacity(0)]),
                        center: CGPoint(x: mid, y: floorY), startRadius: 0, endRadius: radius
                    )
                )
                let left = mid - CGFloat(Self.floorCells) / 2 * cell
                for i in 0..<Self.floorCells {
                    ctx.fill(
                        Path(CGRect(x: left + CGFloat(i) * cell, y: floorY, width: cell, height: cell)),
                        with: .color(Burrow.amber.opacity(Self.floorAlpha(i) * (0.7 + 0.3 * breath)))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The night light under a pet drawn `size` points tall (MascotView), its
    /// floor right under the pet's feet.
    func burrowNightLight(_ lit: Bool, rows: PeekRows, size: CGFloat) -> some View {
        let cell = size / 16
        let feet = CGFloat(rows.bodyBottom + 1) * cell
        return background(alignment: .top) {
            if lit {
                BurrowNightLight(cell: cell)
                    .frame(width: 24 * cell, height: (BurrowNightLight.glowCells + 1) * cell)
                    .offset(y: feet - BurrowNightLight.glowCells * cell)
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
            }
        }
    }
}

/// A pet whose conversation's last turn failed, and you have not opened the
/// den since: an ember by its head, glowing on and off, until you look.
struct BurrowEmber: View {
    /// Where it sits on the pet's 24pt frame: by the top right of its head,
    /// where the waiting "!" goes.
    static let x: CGFloat = 21.75
    static let y: CGFloat = -1.5

    /// The failure is newer than the last look at the den.
    static func isUnseen(_ session: SessionSnapshot, denSeenAt: Date) -> Bool {
        session.lastTurnFailed && session.status == .idle && session.lastActivity > denSeenAt
    }

    /// Only a resting pet wears it: one at work shows its sign there, one
    /// that needs you its "!", and a reaction plays out first.
    static func shows(on state: PetState) -> Bool { state == .idle || state == .sleep }

    var body: some View {
        MascotTimeline(interval: 0.6, staticTime: 0) { t in
            let flicker = CGFloat(Int(t / 0.6) % 2)
            let cell = Burrow.petCell
            Canvas { ctx, _ in
                ctx.fill(Path(CGRect(x: 0, y: 2.5 * cell, width: 2 * cell, height: 2 * cell)), with: .color(Burrow.ember))
                ctx.fill(Path(CGRect(x: flicker * cell, y: cell, width: cell, height: cell)), with: .color(Burrow.ember.opacity(0.45)))
            }
            .frame(width: 2 * cell, height: 4.5 * cell)
        }
        .offset(y: -2.5 * Burrow.petCell)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A pet whose conversation finished a turn you have not looked at: a warm
/// white spark by its head, where the ember goes, twinkling slower than an
/// ember flickers, until you open the den (design/v20, A). White is news,
/// ember is a failure, amber is "needs you".
struct BurrowSpark: View {
    /// The spark's 3x3 pet pixels on the pet's 24pt frame: centred where the
    /// ember sits.
    static let x: CGFloat = 21
    static let y: CGFloat = -3.75
    static let period: Double = 1.6

    /// The turn finished after the last look at the den, and the
    /// conversation has rested since (a new turn puts the spark out).
    static func isUnseen(_ session: SessionSnapshot, doneAt: Date?, seenAt: Date) -> Bool {
        guard let doneAt else { return false }
        return SessionCardStatus(session) == .done && doneAt > seenAt
    }

    /// The spark's pixels: a plus while it twinkles, else its bright centre.
    static func rows(twinkling: Bool) -> [String] {
        twinkling ? [".a.", "aba", ".a."] : ["...", ".b.", "..."]
    }

    /// In a den row's sign: the plus, still.
    var still = false

    var body: some View {
        MascotTimeline(interval: Self.period / 2, staticTime: Self.period / 2) { t in
            let twinkling = still || Int(t / (Self.period / 2)) % 2 == 1
            let cell = Burrow.petCell
            Canvas { ctx, _ in
                for (j, row) in Self.rows(twinkling: twinkling).enumerated() {
                    for (i, px) in row.enumerated() where px != "." {
                        ctx.fill(Path(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell)),
                                 with: .color(px == "b" ? Burrow.spark : Burrow.spark.opacity(0.5)))
                    }
                }
            }
            .frame(width: 3 * cell, height: 3 * cell)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How many conversations an agent has open, beside its pet: 3x5 pixel
/// digits in the pet's own colour, so the number reads as that pet's.
struct BurrowCountBadge: View {
    let count: Int
    /// The pet's colours, top row first (a gradient pet passes several).
    var ink: [UInt32] = [0x9B958D]

    static let digits: [Character: [String]] = [
        "0": ["111", "1.1", "1.1", "1.1", "111"], "1": [".1.", "11.", ".1.", ".1.", "111"],
        "2": ["111", "..1", "111", "1..", "111"], "3": ["111", "..1", "111", "..1", "111"],
        "4": ["1.1", "1.1", "111", "..1", "..1"], "5": ["111", "1..", "111", "..1", "111"],
        "6": ["111", "1..", "111", "1.1", "111"], "7": ["111", "..1", ".1.", ".1.", ".1."],
        "8": ["111", "1.1", "111", "1.1", "111"], "9": ["111", "1.1", "111", "..1", "111"],
    ]

    var body: some View {
        let cell = Burrow.petCell
        let text = Array(String(count))
        Canvas { ctx, _ in
            for (n, ch) in text.enumerated() {
                guard let rows = Self.digits[ch] else { continue }
                for (j, row) in rows.enumerated() {
                    let rgb = ink[min(j, ink.count - 1)]
                    for (i, px) in row.enumerated() where px == "1" {
                        let x = (CGFloat(n) * 4 + CGFloat(i)) * cell
                        ctx.fill(Path(CGRect(x: x, y: CGFloat(j) * cell, width: cell, height: cell)),
                                 with: .color(Color(petRGB: rgb)))
                    }
                }
            }
        }
        .frame(width: (CGFloat(text.count) * 4 - 1) * cell, height: 5 * cell)
        .accessibilityHidden(true)
    }
}

extension PetSpecies {
    /// The pet's own colours for things drawn in its name (its count, its
    /// name in the den): the body colour, or the bands of a gradient pet.
    var ink: [UInt32] {
        let p = sprite.palette
        switch self {
        case .antigravity: return ["B", "G", "H", "I", "I"].compactMap { p[$0] }
        default: return [p["B"] ?? 0x9B958D]
        }
    }
}

/// No agents at all: the burrow is empty but not gone — two sleepy eyes
/// glint now and then from beside the notch, in the menu bar's band, so you
/// know the island is still there.
struct BurrowEmptyLip: View {
    static let earWidth: CGFloat = 12
    let notchWidth: CGFloat
    let bandHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Still (animations gated off), it rests on an open-eyed frame:
            // t = 0 would be the blink.
            MascotTimeline(interval: 0.25, staticTime: 0.25) { t in
                let blink = Int(t / 0.25) % 24 == 0
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule()
                            .fill(Burrow.ink.opacity(0.32))
                            .frame(width: 2, height: blink ? 1 : 2.5)
                    }
                }
                .frame(width: Self.earWidth, height: bandHeight)
            }
            Color.clear.frame(width: notchWidth)
            Color.clear.frame(width: Self.earWidth)
        }
        .frame(height: bandHeight)
        .accessibilityHidden(true)
    }
}
