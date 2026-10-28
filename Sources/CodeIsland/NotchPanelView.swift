import SwiftUI
import CodeIslandCore

/// Shared bounds for the collapsed-width scale setting — keeps the settings
/// slider and the width math in lockstep. Percent of the (simulated) notch width.
enum NotchWidthScale {
    static let min = 50
    static let max = 150
    static let step = 1
}

enum NotchWidthMetrics {
    /// On notched displays the island can grow beyond the physical notch but never
    /// shrink under it — narrower would expose the bare hardware cutout (#268).
    static func effectiveNotchWidth(notchW: CGFloat, collapsedWidthScale: Int, hasNotch: Bool) -> CGFloat {
        let clampedScale = Swift.max(NotchWidthScale.min, Swift.min(collapsedWidthScale, NotchWidthScale.max))
        let scaled = notchW * CGFloat(clampedScale) / 100.0
        if hasNotch { return Swift.max(notchW, scaled) }
        return scaled
    }
}

// MARK: - Hover interaction state machine

/// Where the island is in its hover interaction. `prehover` is the immediate
/// lightweight acknowledgement (slight widen + scale) shown while the expand
/// delay is still running — a quick mouse pass-through only ever plays this
/// first stage and reverses, instead of popping the full panel open.
enum NotchHoverPhase {
    case collapsed
    case prehover
    case expanded
}

enum NotchHoverEvent {
    case mouseEntered
    case mouseExited
    case expandDelayElapsed
    case collapseDelayElapsed
}

enum NotchHoverInteraction {
    static let prehoverAnimationDuration: TimeInterval = 0.21
    static let expandDelay: TimeInterval = 0.5
    static let collapseDelay: TimeInterval = 0.5
    static let prehoverWidthDelta: CGFloat = 7
    static let prehoverScale: CGFloat = 1.004

    /// User-tunable range for `expandDelay` (Settings → Behavior). Below 0.1s
    /// every pass of the pointer toward the menu bar would pop the panel open;
    /// past 1s the island stops feeling like it responds to hover at all.
    static let expandDelayRange: ClosedRange<TimeInterval> = 0.1...1.0
    static let expandDelayStep: TimeInterval = 0.05

    /// The stored preference, clamped into `expandDelayRange`. A value written
    /// by hand (`defaults write`) or a corrupt one must never yield a zero or
    /// negative timer interval, so non-finite input falls back to the default.
    static func expandDelay(forSetting raw: Double) -> TimeInterval {
        guard raw.isFinite else { return expandDelay }
        return min(max(raw, expandDelayRange.lowerBound), expandDelayRange.upperBound)
    }

    /// Whether an elapsed hover delay may still open the session list. A card
    /// the island opened during the delay (an approval, or a question the user
    /// just clicked open) is waiting on the user; swapping it for the list
    /// would hide the one thing that needs an answer.
    static func hoverExpansionMayReplace(_ surface: IslandSurface) -> Bool {
        switch surface {
        case .approvalCard, .questionCard: return false
        default: return true
        }
    }

    /// Whether the burrow still knows which pet is under the pointer: only
    /// while it is collapsed and the pointer is on the island. Anything
    /// opening over the pets, or the pointer leaving, forgets it — a stale
    /// pet would open its card on the next hover anywhere.
    static func keepsHoveredPet(surface: IslandSurface, pointerOnIsland: Bool) -> Bool {
        pointerOnIsland && surface == .collapsed
    }

    static func nextPhase(from phase: NotchHoverPhase, event: NotchHoverEvent) -> NotchHoverPhase {
        switch (phase, event) {
        case (.collapsed, .mouseEntered):
            return .prehover
        case (.prehover, .mouseExited):
            return .collapsed
        case (.prehover, .expandDelayElapsed):
            return .expanded
        case (.expanded, .collapseDelayElapsed):
            return .collapsed
        default:
            return phase
        }
    }
}

enum ToolNameDisplay {
    static let compactMaxCharacters = 24
    static let compactMaxWidth: CGFloat = 120

    static func compact(_ tool: String, maxCharacters: Int = compactMaxCharacters) -> String {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 3, trimmed.count > maxCharacters else { return trimmed }

        let components = trimmed.components(separatedBy: "__")
        let meaningfulSuffix: String?
        if components.count > 1, let last = components.last, !last.isEmpty {
            meaningfulSuffix = last
        } else {
            meaningfulSuffix = nil
        }
        let minimumPrefixCount = max(1, min(4, maxCharacters - 4))
        let suffixBudget = max(1, maxCharacters - minimumPrefixCount - 3)
        let suffixCount = meaningfulSuffix.map { min($0.count, suffixBudget) } ?? max(4, maxCharacters / 2)
        let prefixCount = max(1, maxCharacters - suffixCount - 3)
        return "\(trimmed.prefix(prefixCount))...\(trimmed.suffix(suffixCount))"
    }
}

struct NotchPanelView: View {
    var appState: AppState
    let hasNotch: Bool
    let notchHeight: CGFloat
    let notchW: CGFloat
    let screenWidth: CGFloat
    /// Moves the island's silhouette in the panel window; without one (tests,
    /// screenshot harnesses) the view draws NotchPanelShape itself.
    var islandDriver: NotchIslandShapeDriver? = nil

    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.smartSuppress) private var smartSuppress = SettingsDefaults.smartSuppress
    @AppStorage(SettingsKey.hideWhenNoSession) private var hideWhenNoSession = SettingsDefaults.hideWhenNoSession
    @AppStorage(SettingsKey.hapticOnHover) private var hapticOnHover = SettingsDefaults.hapticOnHover
    @AppStorage(SettingsKey.hapticIntensity) private var hapticIntensity = SettingsDefaults.hapticIntensity
    @AppStorage(SettingsKey.hoverExpandDelay) private var hoverExpandDelay = SettingsDefaults.hoverExpandDelay

    /// Pets fly between the rim and their den rows inside this namespace.
    @Namespace private var burrowNamespace
    @ObservedObject private var petReactions = PetReactionCenter.shared
    @ObservedObject private var animationGate = MascotAnimationGate.shared

    /// Delayed hover: prevents accidental expansion when mouse passes through
    @State private var hoverTimer: Timer?
    /// The pet under the pointer in the collapsed burrow.
    @State private var hoveredPetId: String?
    @State private var isHovered = false
    /// Three-stage hover: collapsed → prehover (immediate ack) → expanded (after delay)
    @State private var hoverPhase: NotchHoverPhase = .collapsed
    /// Window height and card chrome for the completion card's reply area.
    @State private var cardSpace = CompletionCardSpace()
    /// The expanded panel's height as last laid out — where the island
    /// heads the moment it opens, before the new content is measured.
    @State private var expandedHeight: CGFloat = 0

    private var isActive: Bool { !appState.sessions.isEmpty }
    /// First launch / no-session state should still render a visible marker so the app
    /// doesn't disappear completely behind the physical notch.
    private var showIdleIndicator: Bool {
        !isActive && !hideWhenNoSession
    }
    /// Whether the bar content should be visible (respects hideWhenNoSession)
    private var showBar: Bool {
        isActive && !(hideWhenNoSession && appState.activeSessionCount == 0)
    }
    private var shouldShowExpanded: Bool {
        (showBar || showIdleIndicator) && appState.surface.isExpanded
    }

    // MARK: Burrow

    private var burrowResidents: BurrowLayout {
        BurrowResidents.pets(appState: appState, reactions: petReactions, animating: !animationGate.isIdleSettled)
    }

    private var burrowCollapsedWidth: CGFloat {
        if !showBar { return effectiveNotchW + 2 * BurrowEmptyLip.earWidth }
        let residents = burrowResidents
        return BurrowLipMetrics.width(
            notchWidth: effectiveNotchW,
            left: residents.left.count,
            right: residents.right.count,
            hasOverflow: residents.overflow > 0
        )
    }

    /// The card a lit pet holds back — its approval or question, held back
    /// or dismissed: a click on the burrow (or VoiceOver's press) opens it,
    /// the hovered pet's first.
    private var heldCard: BurrowHeldCard? {
        BurrowResidents.heldCard(pets: burrowResidents.pets, preferring: hoveredPetId, surface: appState.surface)
    }

    /// What a click or press on the collapsed burrow opens.
    private func openHeldCard() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        switch heldCard {
        case .approval(let sid): appState.reopenPermissionCard(sessionId: sid)
        case .question(let sid): appState.openPendingQuestionCard(sessionId: sid)
        case nil: appState.openPendingQuestionCard()
        }
    }

    /// Prehover acknowledgement is only rendered on the collapsed active bar —
    /// once the surface expands (from hover or any other path) it disappears.
    private var shouldShowPrehover: Bool {
        showBar && !shouldShowExpanded && hoverPhase == .prehover
    }

    private var collapsedRecapTooltip: String {
        guard !shouldShowExpanded else { return "" }
        let sid = appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
        return SessionMetadataStyle.collapsedRecapTooltip(
            for: sid.flatMap { appState.sessions[$0] },
            showProjectName: SettingsDefaults.showProjectName
        )
    }

    /// Effective island width — on notched screens the scale can only widen past the notch.
    private var effectiveNotchW: CGFloat {
        NotchWidthMetrics.effectiveNotchWidth(
            notchW: notchW,
            // The width-scale slider is gone; the burrow is sized by its pets.
            collapsedWidthScale: SettingsDefaults.collapsedWidthScale,
            hasNotch: hasNotch
        )
    }

    /// Total panel width — adapts based on state and screen geometry
    private var panelWidth: CGFloat { panelWidth(expanded: shouldShowExpanded) }

    /// The collapsed bar's width, also while the expanded panel is showing.
    private var collapsedPanelWidth: CGFloat { panelWidth(expanded: false) }

    private func panelWidth(expanded: Bool) -> CGFloat {
        if expanded && (showBar || showIdleIndicator) { return expandedPanelWidth }
        if showBar || showIdleIndicator {
            let prehoverExtra: CGFloat = shouldShowPrehover ? NotchHoverInteraction.prehoverWidthDelta : 0
            return burrowCollapsedWidth + prehoverExtra
        }
        // Nothing to show ("hide when no session"): just the notch shell.
        return hasNotch ? effectiveNotchW - 20 : effectiveNotchW
    }

    /// The den and the cards share one width (Burrow.cardWidth).
    private var expandedPanelWidth: CGFloat {
        let wanted: CGFloat
        switch appState.surface {
        case .sessionList, .collapsed: wanted = Burrow.denWidth
        default: wanted = Burrow.cardWidth
        }
        return min(max(wanted, effectiveNotchW + 160), maxPanelWidth)
    }

    /// The panel window's width (PanelWindowController.panelSize).
    private var maxPanelWidth: CGFloat { min(620, screenWidth - 40) }


    /// The collapsed bar: the pet and status ears on a notched screen, the
    /// compact bar elsewhere, or the idle marker.
    private var collapsedLayer: some View {
        Group {
            if showBar {
                let residents = burrowResidents
                BurrowLip(layout: residents,
                          notchWidth: effectiveNotchW, bandHeight: notchHeight,
                          hoveredPetId: $hoveredPetId)
                .help(collapsedRecapTooltip)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded { openHeldCard() },
                    including: heldCard != nil || appState.hiddenPendingQuestionSessionId != nil ? .all : .subviews
                )
                // VoiceOver: the burrow's press opens what a lit pet holds.
                .accessibilityAction { openHeldCard() }
            } else if showIdleIndicator {
                BurrowEmptyLip(notchWidth: effectiveNotchW, bandHeight: notchHeight)
            } else {
                // Idle: just the notch shell
                Spacer()
                    .frame(height: notchHeight)
            }
        }
        .frame(width: collapsedPanelWidth)
    }

    /// Content fades; the silhouette's springs carry the motion. The panel
    /// fades in once the island has started to grow and out before it has
    /// shrunk far enough to cut its lines; the bar comes back as the island
    /// closes around it. Timed off the springs, so the speed setting holds.
    private static var expandedLayerTransition: AnyTransition {
        let open = NotchAnimationMetrics.openResponse, close = NotchAnimationMetrics.closeResponse
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: open * 0.5).delay(open * 0.1)),
            removal: .opacity.animation(.easeOut(duration: close * 0.3))
        )
    }
    private static var collapsedLayerTransition: AnyTransition {
        let open = NotchAnimationMetrics.openResponse, close = NotchAnimationMetrics.closeResponse
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: close * 0.5).delay(close * 0.25)),
            removal: .opacity.animation(.easeOut(duration: open * 0.25))
        )
    }

    /// The island's silhouette for one state. The expanded height is the
    /// panel as last measured; a new measurement retargets the spring.
    private func islandGeometry(expanded: Bool, measuredHeight: CGFloat? = nil) -> NotchIslandGeometry {
        NotchIslandGeometry(
            centerOffset: 0,
            width: panelWidth(expanded: expanded),
            height: expanded ? max(measuredHeight ?? expandedHeight, notchHeight) : notchHeight,
            topExtension: expanded ? 14 : 3,
            bottomRadius: expanded ? Burrow.denRadius : BurrowLipMetrics.bottomRadius,
            expanded: expanded
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // The collapsed bar and the expanded panel are separate layers,
            // each laid out at its own width from its first frame: switching
            // between them only fades content, while the island's silhouette
            // and clip move on their own — Core Animation in the panel window
            // (NotchIslandShapeDriver), NotchPanelShape when hosted elsewhere.
            ZStack(alignment: .top) {
                if shouldShowExpanded {
                    // Laid out at the expanded width from the first frame and
                    // revealed by the island's clip as it grows (or hidden as it
                    // shrinks), instead of sliding with the island's edge and
                    // re-wrapping its lines on every spring frame.
                    VStack(spacing: 0) {
                    BurrowDenHeader(appState: appState, notchWidth: hasNotch ? notchW : 0)
                        .frame(height: notchHeight)

                    Group {
                    switch appState.surface {
                    case .approvalCard(let sid):
                        // Card is addressed by session — render that session's
                        // request, not whatever is at the head of the queue. (#308)
                        if let pending = appState.pendingPermission(forSession: sid) {
                            let session = appState.sessions[sid]
                            BurrowApprovalCard(
                                tool: pending.event.toolName ?? "Unknown",
                                toolInput: pending.event.toolInput,
                                queuePosition: appState.permissionQueuePosition(forSession: sid),
                                queueTotal: appState.permissionQueue.count,
                                session: session,
                                sessionId: sid,
                                appState: appState,
                                alwaysSavesRule: CodexPermissionRules.isCodexEvent(pending.event),
                                onAllow: { appState.approvePermission(always: false, expectedSessionId: sid) },
                                onAlwaysAllow: { appState.approvePermission(always: true, expectedSessionId: sid) },
                                onDeny: { appState.denyPermission(expectedSessionId: sid) },
                                onDismiss: { appState.dismissPermissionPrompt(expectedSessionId: sid) }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    case .questionCard(let sid):
                        let session = appState.sessions[sid]
                        if let q = appState.pendingQuestion(forSession: sid) {
                            QuestionBar(
                                question: q.question.question,
                                options: q.question.options,
                                descriptions: q.question.descriptions,
                                allQuestions: q.askUserQuestionState?.items ?? [],
                                requestId: q.id,
                                sessionSource: session?.source,
                                sessionContext: session?.cwd,
                                session: session,
                                sessionId: sid,
                                appState: appState,
                                queuePosition: appState.questionQueuePosition(forSession: sid),
                                queueTotal: appState.questionQueue.count,
                                onAnswer: { appState.answerQuestion($0, expectedSessionId: sid) },
                                onAnswerMulti: { appState.answerQuestionMulti($0, expectedSessionId: sid) },
                                onSkip: { appState.skipQuestion(expectedSessionId: sid) },
                                onDismiss: { appState.dismissQuestion(expectedSessionId: sid) }
                            )
                            // One view per request. Answering a card promotes the
                            // next session's request into this same slot, and
                            // without a new identity SwiftUI hands it the previous
                            // card's @State — answers, selection and typed text
                            // included. (#333)
                            .id(q.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        } else if let preview = appState.previewQuestionPayload {
                            QuestionBar(
                                question: preview.question,
                                options: preview.options,
                                descriptions: preview.descriptions,
                                allQuestions: [],
                                requestId: nil,
                                sessionSource: session?.source,
                                sessionContext: session?.cwd,
                                session: session,
                                sessionId: sid,
                                appState: appState,
                                queuePosition: 1,
                                queueTotal: 1,
                                onAnswer: { _ in },
                                onAnswerMulti: { _ in },
                                onSkip: { },
                                onDismiss: { }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    case .completionCard(let sid):
                        BurrowDoneCard(appState: appState, sessionId: appState.justCompletedSessionId ?? sid)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    case .sessionList:
                        // The den, or turned over, its back: Burrow's settings.
                        BurrowFlipCard(angle: appState.denShowsSettings ? 180 : 0,
                                       front: BurrowDen(appState: appState),
                                       back: BurrowDenBack())
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    case .collapsed:
                        EmptyView()
                    }
                    }
                    .frame(width: expandedPanelWidth)
                    }
                    .frame(width: expandedPanelWidth)
                    .recordsCompletionCardChrome(in: cardSpace)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        expandedHeight = height
                        // Straight to the island as well: when the den closes and
                        // a request it held opens its card in the same pass, the
                        // onChange below misses the card's height and the island
                        // stays den-sized, clipping the card's buttons.
                        if shouldShowExpanded {
                            islandDriver?.update(islandGeometry(expanded: true, measuredHeight: height))
                        }
                    }
                    .transition(Self.expandedLayerTransition)
                } else {
                    collapsedLayer
                        .transition(Self.collapsedLayerTransition)
                }
            }
            .frame(width: maxPanelWidth, alignment: .top)
            .modifier(SwiftUIIslandChrome(
                enabled: islandDriver == nil,
                geometry: islandGeometry(expanded: shouldShowExpanded),
                minHeight: notchHeight
            ))
            .scaleEffect(shouldShowPrehover ? NotchHoverInteraction.prehoverScale : 1, anchor: .top)
            // The island itself, not a layer still fading out around it.
            .contentShape(NotchIslandHitShape(
                width: panelWidth,
                height: shouldShowExpanded ? nil : notchHeight,
                centerOffset: 0
            ))
            .onHover { hovering in
                // Leaving the island leaves every pet, whatever surface is up:
                // a card opened over the burrow never sees its pets' exits.
                if !hovering { hoveredPetId = nil }
                // Idle indicator hover — delay un-hover to prevent oscillation when
                // the animated width change crosses the mouse position (#52).
                switch appState.surface {
                case .approvalCard, .questionCard: return
                case .completionCard:
                    // Completion card: mark entered on hover-in, block collapse until entered
                    if hovering {
                        appState.completionHasBeenEntered = true
                    } else if appState.completionHasBeenEntered || appState.deferCollapseOnMouseLeave {
                        // Mouse entered then left: the card keeps the rest of
                        // its time instead of folding at once.
                        hoverTimer?.invalidate()
                        hoverTimer = nil
                        appState.completionPointerLeft()
                    }
                    return
                default: break
                }
                // Respect collapseOnMouseLeave setting
                if !hovering && !SettingsManager.shared.collapseOnMouseLeave { return }
                // Smart suppress: don't auto-expand when active session's terminal is foreground
                if hovering && smartSuppress {
                    if let delegate = NSApp.delegate as? AppDelegate,
                       let pc = delegate.panelController,
                       pc.isActiveTerminalForeground() {
                        return
                    }
                }

                isHovered = hovering
                if hovering {
                    // Immediate lightweight acknowledgement; a quick pass-through
                    // only ever plays this first stage and reverses.
                    withAnimation(NotchAnimation.hoverPrehover) {
                        hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .mouseEntered)
                    }
                    // Delay full expansion to avoid accidental triggers
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(
                        withTimeInterval: NotchHoverInteraction.expandDelay(forSetting: hoverExpandDelay),
                        repeats: false
                    ) { _ in
                        Task { @MainActor in
                            // Guard: mouse may have left during the delay
                            guard isHovered else { return }
                            guard NotchHoverInteraction.hoverExpansionMayReplace(appState.surface) else { return }
                            // Resting on a lit pet opens the card it holds,
                            // not the den: that is what it is lit for.
                            if let pet = burrowResidents.pets.first(where: { $0.id == hoveredPetId }),
                               BurrowResidents.heldCard(for: pet, surface: appState.surface) != nil {
                                openHeldCard()
                                return
                            }
                            if hapticOnHover {
                                let performer = NSHapticFeedbackManager.defaultPerformer
                                switch hapticIntensity {
                                case 3: // strong: two taps
                                    performer.perform(.levelChange, performanceTime: .now)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        performer.perform(.levelChange, performanceTime: .now)
                                    }
                                case 2: // medium
                                    performer.perform(.levelChange, performanceTime: .default)
                                default: // light
                                    performer.perform(.alignment, performanceTime: .default)
                                }
                            }
                            // Start the island's spring before SwiftUI lays out the
                            // panel: committed now, it runs in the render server
                            // while the main thread builds the content.
                            if let islandDriver, showBar || showIdleIndicator {
                                islandDriver.update(islandGeometry(expanded: true))
                                CATransaction.flush()
                            }
                            // Same transaction as the surface: the prehover widen
                            // and scale hand over to the open spring instead of
                            // snapping back in an unanimated update.
                            withAnimation(NotchAnimation.open) {
                                hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .expandDelayElapsed)
                                appState.surface = .sessionList
                                appState.cancelCompletionQueue()
                                if appState.activeSessionId == nil {
                                    appState.activeSessionId = appState.sessions.keys.sorted().first
                                }
                            }
                        }
                    }
                } else {
                    // Reverse the prehover acknowledgement right away…
                    withAnimation(NotchAnimation.hoverPrehover) {
                        hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .mouseExited)
                    }
                    // …and collapse an expanded panel after a grace delay so an
                    // accidental mouse-out doesn't flicker it shut.
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: NotchHoverInteraction.collapseDelay, repeats: false) { _ in
                        Task { @MainActor in
                            guard !isHovered else { return }
                            // The den's back (settings) stays while you reach
                            // for its slider; a click elsewhere closes it.
                            guard !appState.denShowsSettings else { return }
                            if let islandDriver, shouldShowExpanded {
                                islandDriver.update(islandGeometry(expanded: false))
                                CATransaction.flush()
                            }
                            withAnimation(NotchAnimation.close) {
                                hoverPhase = NotchHoverInteraction.nextPhase(from: hoverPhase, event: .collapseDelayElapsed)
                                appState.surface = .collapsed
                            }
                            // A request that arrived while the den was open was
                            // held for it; the den has no approve buttons, so once
                            // it closes the request opens the way it would have.
                            if !appState.visiblePermissionSessionIds.isEmpty || appState.nextVisibleQuestion != nil {
                                withAnimation(NotchAnimation.open) { appState.showNextPending() }
                            }
                        }
                    }
                }
            }
            .onChange(of: appState.surface) { _, newSurface in
                // The burrow's pets are gone from under the pointer once
                // anything opens over them.
                if !NotchHoverInteraction.keepsHoveredPet(surface: newSurface, pointerOnIsland: true) { hoveredPetId = nil }
                // The surface can change from outside the hover flow (auto-expand
                // cards, click-to-close, …) — keep the phase from going stale.
                if newSurface == .collapsed && !isHovered {
                    hoverPhase = .collapsed
                } else if newSurface.isExpanded && hoverPhase != .expanded {
                    hoverPhase = .expanded
                }
            }
            .onChange(of: islandGeometry(expanded: shouldShowExpanded), initial: true) { _, geometry in
                islandDriver?.update(geometry)
            }

            Spacer()
                .allowsHitTesting(false)
        }
        // minHeight 0: the frame is the window's height even when the content
        // runs taller (without it the frame grows with its content), so the
        // measurement below is the window, and any overflow runs off the
        // bottom instead of pushing the notch bar off the top.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // The hosting view fills the panel window, whose height is already
        // clamped to the screen.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardSpace.recordWindowHeight($0) }
        .environment(cardSpace)
        .environment(\.burrowNamespace, burrowNamespace)
        // Surface changes made without their own transaction (auto-expanded
        // cards, click-to-close…) still animate — with the spring for their
        // direction. A fixed `.open` here also overrode every explicit close,
        // so collapsing bounced past the collapsed width and back.
        .animation(appState.surface.isExpanded ? NotchAnimation.open : NotchAnimation.close, value: appState.surface)
    }
}


// MARK: - Approval card parts

struct ApprovalToolDetailView: View {
    let tool: String
    let toolInput: [String: Any]?
    var maxLines: Int? = nil
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize

    /// Follows Content Font Size, like the rest of the card (and the session
    /// list, which shows this view under "Details").
    private var type: NotchCardTypography { NotchCardTypography(contentFontSize: contentFontSize) }

    private var filePath: String? {
        toolInput?["file_path"] as? String
    }

    var body: some View {
        Group {
            switch tool {
            case "Bash":
                VStack(alignment: .leading, spacing: 2) {
                    if let cmd = toolInput?["command"] as? String {
                        HStack(alignment: .top, spacing: 4) {
                            Text("$")
                                .font(.system(size: type.body, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                            Text(cmd)
                                .font(.system(size: type.body, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(maxLines)
                        }
                    }
                    if let desc = toolInput?["description"] as? String, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: type.secondary, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(maxLines)
                    }
                }

            case "Edit":
                VStack(alignment: .leading, spacing: 3) {
                    if let fp = filePath {
                        Text(fp)
                            .font(.system(size: type.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let old = toolInput?["old_string"] as? String {
                        HStack(alignment: .top, spacing: 4) {
                            Text("−")
                                .font(.system(size: type.body, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 1.0, green: 0.4, blue: 0.4))
                            Text(old.prefix(120))
                                .font(.system(size: type.secondary, design: .monospaced))
                                .foregroundStyle(Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.85))
                                .lineLimit(maxLines ?? 2)
                        }
                    }
                    if let new = toolInput?["new_string"] as? String {
                        HStack(alignment: .top, spacing: 4) {
                            Text("+")
                                .font(.system(size: type.body, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                            Text(new.prefix(120))
                                .font(.system(size: type.secondary, design: .monospaced))
                                .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4).opacity(0.7))
                                .lineLimit(maxLines ?? 2)
                        }
                    }
                }

            case "Write":
                VStack(alignment: .leading, spacing: 3) {
                    if let fp = filePath {
                        Text(fp)
                            .font(.system(size: type.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let content = toolInput?["content"] as? String {
                        Text(content.prefix(200))
                            .font(.system(size: type.secondary, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(maxLines ?? 4)
                    }
                }

            case "Read":
                VStack(alignment: .leading, spacing: 2) {
                    if let fp = filePath {
                        Text(fp)
                            .font(.system(size: type.secondary, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let offset = toolInput?["offset"] as? Int,
                       let limit = toolInput?["limit"] as? Int {
                        Text("\(L10n.shared["lines"]) \(offset + 1)–\(offset + limit)")
                            .font(.system(size: type.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

            case "Grep":
                VStack(alignment: .leading, spacing: 2) {
                    if let pattern = toolInput?["pattern"] as? String {
                        HStack(alignment: .top, spacing: 4) {
                            Text("/")
                                .font(.system(size: type.body, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.9, green: 0.6, blue: 0.9))
                            Text(pattern)
                                .font(.system(size: type.body, design: .monospaced))
                                .foregroundStyle(Color(red: 0.9, green: 0.6, blue: 0.9).opacity(0.8))
                                .lineLimit(maxLines ?? 2)
                        }
                    }
                    if let path = toolInput?["path"] as? String {
                        Text(path)
                            .font(.system(size: type.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

            case "Glob":
                VStack(alignment: .leading, spacing: 2) {
                    if let pattern = toolInput?["pattern"] as? String {
                        Text(pattern)
                            .font(.system(size: type.body, design: .monospaced))
                            .foregroundStyle(Color(red: 0.6, green: 0.8, blue: 1.0))
                            .lineLimit(maxLines ?? 2)
                    }
                    if let path = toolInput?["path"] as? String {
                        Text(path)
                            .font(.system(size: type.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

            default:
                VStack(alignment: .leading, spacing: 2) {
                    if let input = toolInput {
                        ForEach(Array(input.keys.sorted().prefix(4)), id: \.self) { key in
                            let val = input[key].map { "\($0)" } ?? ""
                            HStack(alignment: .top, spacing: 4) {
                                Text(key)
                                    .font(.system(size: type.caption, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.6, green: 0.7, blue: 0.9))
                                Text(String(val.prefix(160)))
                                    .font(.system(size: type.secondary, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(maxLines ?? 2)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Tooltips for the approval buttons, shared by the card and the session
/// list's inline row.
enum ApprovalHints {
    /// What "Always" commits to differs by agent: Claude-style hooks add a
    /// rule for the rest of the session, Codex gets a rule saved to disk
    /// (CodexPermissionRules) that outlives it.
    static func always(savesRule: Bool) -> String {
        L10n.shared[savesRule ? "always_hint_saved" : "always_hint_session"]
    }

    /// The same, told apart for a Codex MCP tool, whose approval goes to
    /// config.toml rather than the rules file.
    static func always(scope: ApprovalAlwaysScope) -> String {
        switch scope {
        case .session: return L10n.shared["always_hint_session"]
        case .codexRules: return L10n.shared["always_hint_saved"]
        case .codexMCPConfig: return L10n.shared["always_hint_saved_mcp"]
        }
    }
}

/// Where "Always allow" puts its rule — what the approval card's link says.
enum ApprovalAlwaysScope: Equatable {
    /// Claude-style hooks: a rule for this tool, for the rest of the session.
    case session
    /// Codex: a prefix rule in ~/.codex/rules, kept for every session.
    case codexRules
    /// Codex MCP tool: an approval in ~/.codex/config.toml
    /// (CodexPermissionRules.persistAlwaysAllowRule).
    case codexMCPConfig

    init(savesRule: Bool, tool: String) {
        if !savesRule {
            self = .session
        } else {
            self = ApprovalCopy.mcpParts(tool) == nil ? .codexRules : .codexMCPConfig
        }
    }

    /// The file the rule is saved to, as the link shows it; nil for a
    /// session rule.
    var savedPath: String? {
        switch self {
        case .session: return nil
        case .codexRules: return "~/.codex/rules"
        case .codexMCPConfig: return "~/.codex/config.toml"
        }
    }
}

/// The approval card's words: its title ("Bash wants to run a command") and
/// the scope its "Always" link spells out.
enum ApprovalCopy {
    /// What a tool does, for the title's verb.
    enum Action: Equatable {
        case command, change, read, search, web, mcp, agent, other
    }

    /// `mcp__server__tool`, split; nil for anything else.
    static func mcpParts(_ tool: String) -> (server: String, tool: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = tool.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let name = String(rest[separator.upperBound...])
        guard !server.isEmpty, !name.isEmpty else { return nil }
        return (server, name)
    }

    static func action(for tool: String) -> Action {
        if mcpParts(tool) != nil { return .mcp }
        let name = tool.lowercased().replacingOccurrences(of: "-", with: "_")
        if name == "task" || name == "agent" || name.contains("subagent") || name.contains("spawn_agent") {
            return .agent
        }
        if name.contains("webfetch") || name.contains("websearch") || name.contains("web_fetch")
            || name.contains("web_search") || name.contains("fetch_url") {
            return .web
        }
        // Before "change": Codex's write_stdin feeds a running command.
        if name == "bash" || name == "command" || name.contains("shell") || name.contains("exec_command")
            || name.contains("write_stdin") || name.contains("run_command") || name.contains("execute_command")
            || name.contains("terminal") {
            return .command
        }
        if name.contains("edit") || name.contains("write") || name.contains("apply_patch")
            || name.contains("replace") || name.contains("create_file") || name.contains("delete_file")
            || name.contains("move_file") {
            return .change
        }
        if name == "read" || name.contains("read_file") || name.contains("view_file") || name.contains("list_dir") {
            return .read
        }
        if name == "grep" || name == "glob" || name == "find" || name.contains("search") {
            return .search
        }
        return .other
    }

    /// The tool as the card names it: an MCP tool by its own name, without
    /// the `mcp__server__` prefix.
    static func displayName(_ tool: String) -> String {
        if let mcp = mcpParts(tool) { return mcp.tool }
        return ToolNameDisplay.compact(tool, maxCharacters: 32)
    }

    /// The file a change or read is about, by name.
    static func fileName(_ toolInput: [String: Any]?) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = toolInput?[key] as? String {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    static func title(tool: String, toolInput: [String: Any]?) -> String {
        let l10n = L10n.shared
        let name = displayName(tool)
        switch action(for: tool) {
        case .command:
            return String(format: l10n["approval_title_command"], name)
        case .change:
            if let file = fileName(toolInput) {
                return String(format: l10n["approval_title_change_file"], name, file)
            }
            return String(format: l10n["approval_title_change"], name)
        case .read:
            if let file = fileName(toolInput) {
                return String(format: l10n["approval_title_read_file"], name, file)
            }
            return String(format: l10n["approval_title_read"], name)
        case .search:
            return String(format: l10n["approval_title_search"], name)
        case .web:
            return String(format: l10n["approval_title_web"], name)
        case .mcp:
            let parts = mcpParts(tool) ?? (server: tool, tool: tool)
            return String(format: l10n["approval_title_mcp"], parts.server, parts.tool)
        case .agent:
            return String(format: l10n["approval_title_agent"], name)
        case .other:
            return String(format: l10n["approval_title_generic"], name)
        }
    }

    /// "Always allow Bash this session", or where Codex saves the rule.
    static func alwaysLink(tool: String, scope: ApprovalAlwaysScope) -> String {
        if let path = scope.savedPath {
            return String(format: L10n.shared["card_always_saved"], path)
        }
        return String(format: L10n.shared["card_always_session"], displayName(tool))
    }
}

/// Badge text for a global shortcut on a card's button, shown only when the
/// user has turned that shortcut on in Settings (they are all off but the
/// panel toggle by default) — the shortcut existed but nothing surfaced it
/// (#12 UX).
enum CardShortcutHint {
    static func text(for action: ShortcutAction) -> String? {
        guard action.isEnabled else { return nil }
        return action.binding.displayString
    }
}

/// Text sizes on the approval and question cards. They follow Settings ›
/// Content Font Size like the session list, from the setting clamped to the
/// sizes Settings offers: a hand-edited 40 would otherwise push the buttons
/// out of the window, and a 4 would be unreadable.
struct NotchCardTypography: Equatable {
    /// The clamped Content Font Size.
    let base: CGFloat

    init(contentFontSize: Int) {
        let smallest = ContentFontSize.choices.min() ?? 10
        let largest = ContentFontSize.choices.max() ?? 16
        base = CGFloat(min(max(contentFontSize, smallest), largest))
    }

    /// Card title and the question itself.
    var title: CGFloat { base + 1 }
    /// Command, option labels, the project in the context row.
    var body: CGFloat { base }
    /// Command description, diff lines, the branch, the queue position.
    var secondary: CGFloat { base - 1 }
    /// File paths, option descriptions, MCP argument names.
    var caption: CGFloat { max(9, base - 2) }
    /// The PERMISSION tag and shortcut badges.
    var badge: CGFloat { max(8.5, base - 2) }
    /// Button labels. Held back at the largest sizes so the decision row
    /// keeps to one line in the 580pt panel.
    var button: CGFloat { min(base + 1, 15) }
    /// The "Always allow …" link and the answer field.
    var link: CGFloat { base - 0.5 }
    /// Agent icon in the context row.
    var icon: CGFloat { base + 2 }
}

/// How much a card's action is worth, which sets how loud its button is:
/// one filled primary per card, outlined alternatives, a quiet way out.
enum NotchCardButtonRole {
    /// The answer most often given — "Allow once", "Confirm". Filled green.
    case primary
    /// Refuses the request — "Deny". Outlined red.
    case destructive
    /// Another answer — "Skip". Outlined grey.
    case secondary
    /// Leaves the decision for later — "Hide", "Back". Text only.
    case quiet
}

/// Colours of the card buttons. Shared with nothing else on purpose: the
/// session list's inline approval row mirrors these values.
enum NotchCardPalette {
    /// Burrow "Night Light": the one filled button is warm paper white with
    /// near-black text (≈16:1).
    static let allowFill = Burrow.ink
    static let allowFillHover = Color.white
    static let allowText = Burrow.onInk
    /// Deny is an ordinary choice, not an alarm: a neutral outline.
    static let deny = Burrow.ink.opacity(0.88)
    static let link = Burrow.dim
    static let permission = Burrow.amber
}

private struct NotchCardButton: View {
    let label: String
    let role: NotchCardButtonRole
    let fontSize: CGFloat
    /// Keyboard-shortcut badge (e.g. "⌘⇧A"), only when the shortcut is on.
    var hint: String? = nil
    /// Tooltip spelling out what the short label does.
    var help: String? = nil
    var isEnabled = true
    /// Share a narrow row equally instead of hugging the label.
    var expands = false
    var systemImage: String? = nil
    let action: () -> Void
    @State private var hovering = false

    private var foreground: Color {
        switch role {
        case .primary: return NotchCardPalette.allowText.opacity(isEnabled ? 1 : 0.6)
        case .destructive: return NotchCardPalette.deny
        case .secondary: return Burrow.ink.opacity(0.88)
        case .quiet: return hovering ? Burrow.ink : Burrow.dim
        }
    }

    private var fill: Color {
        switch role {
        case .primary:
            guard isEnabled else { return NotchCardPalette.allowFill.opacity(0.35) }
            return hovering ? NotchCardPalette.allowFillHover : NotchCardPalette.allowFill
        case .destructive: return hovering ? Burrow.hover : .clear
        case .secondary: return hovering ? Burrow.hover : .clear
        case .quiet: return hovering ? Burrow.hover : .clear
        }
    }

    private var stroke: Color {
        switch role {
        case .primary: return .clear
        case .destructive: return Burrow.line.opacity(hovering ? 2 : 1.4)
        case .secondary: return Burrow.line.opacity(hovering ? 2 : 1.4)
        case .quiet: return .clear
        }
    }

    /// The badge stays at AA contrast on the button's own fill.
    private var hintOpacity: Double {
        switch role {
        case .primary: return 0.9
        case .destructive: return 0.85
        case .secondary, .quiet: return 0.75
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 2, weight: .semibold))
                }
                Text(label)
                    .font(Burrow.font(fontSize, role == .primary ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(expands ? 0.8 : 1)
                if let hint {
                    Text(hint)
                        .font(.system(size: max(8.5, fontSize - 3), weight: .medium, design: .monospaced))
                        .opacity(hintOpacity)
                        .fixedSize()
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .quiet ? 10 : 14)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h && isEnabled } }
        .help(help ?? "")
        .accessibilityLabel(label)
        .accessibilityHint(help ?? "")
    }
}

/// A card's place among the requests waiting ("1 of 3"); nil when it is the
/// only one.
enum NotchCardQueueLabel {
    static func text(position: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        return String(format: L10n.shared["card_queue_position"], position, total)
    }
}

/// CLI icon + project folder (or session title) + branch heading an approval
/// or question card, so a card always says which session is asking — with
/// several agents queued, "! Bash" alone gave no clue whose command it was.
/// Clicking it focuses that session's terminal, where the full transcript is.
/// With more than one request waiting it ends in the card's place in the
/// queue ("1 of 3").
private struct NotchCardContextRow: View {
    let source: String?
    let cwd: String?
    let session: SessionSnapshot?
    let canJump: Bool
    var queuePosition = 1
    var queueTotal = 1
    let type: NotchCardTypography
    let onJump: () -> Void
    // Burrow's fixed choice: no Settings for it any more.
    private let showGitBranch = SettingsDefaults.showGitBranch
    @State private var hovering = false

    static func isShown(source: String?, cwd: String?, canJump: Bool, queueTotal: Int = 1) -> Bool {
        source != nil || cwd != nil || canJump || queueTotal > 1
    }

    private var branchLabel: String? {
        guard showGitBranch, let branch = session?.gitBranch, !branch.isEmpty else { return nil }
        return session?.gitIsWorktree == true ? "\(branch) ⧉" : branch
    }

    var body: some View {
        HStack(spacing: 6) {
            if let src = source, let icon = cliIcon(source: src, size: type.icon) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: type.icon, height: type.icon)
                    .help(session?.sourceLabel ?? src)
                    .accessibilityLabel(session?.sourceLabel ?? src)
            }
            // Same name as the den row: the title, else the folder.
            if let label = session?.sessionLabel ?? cwd.map({ ($0 as NSString).lastPathComponent }) {
                Text(label)
                    .font(Burrow.font(type.body, .bold))
                    .foregroundStyle(Burrow.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
            }
            if let branch = branchLabel {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: type.secondary - 1, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(branch)
                        .font(.system(size: type.secondary, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: BranchLabelMetrics.minimumWidth(for: branch, fontSize: type.secondary))
                }
                .foregroundStyle(.white.opacity(0.6))
                .help(branch)
                .layoutPriority(1)
            }
            if canJump {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: type.secondary))
                    .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.55))
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            if let queue = NotchCardQueueLabel.text(position: queuePosition, total: queueTotal) {
                Text(queue)
                    .font(.system(size: type.secondary, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.white.opacity(0.09) : Color.clear)
        )
        // The hover wash reaches past the column; the text lines up with it.
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { onJump() }
        .onHover { h in
            guard canJump else { return }
            withAnimation(NotchAnimation.micro) { hovering = h }
        }
        .help(canJump ? L10n.shared["card_jump_hint"] : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canJump ? .isButton : [])
        .accessibilityHint(canJump ? L10n.shared["card_jump_hint"] : "")
        .accessibilityAction { if canJump { onJump() } }
    }
}

// MARK: - Question Bar (below notch, auto-expanded)

func makeQuestionBarFreeTextAnswer(
    question: String,
    text: String
) -> AskUserQuestionAnswer? {
    guard !text.isEmpty else { return nil }
    return AskUserQuestionAnswer(
        question: question,
        answer: text,
        selectedOptions: [],
        customInput: text
    )
}

/// Answer state of one question card: which question of the wizard is up,
/// the answers given so far, and the in-progress selection or text.
///
/// It belongs to one `QuestionRequest`. SwiftUI keeps a view's `@State` for
/// as long as the view keeps its identity, and the card slot keeps its
/// identity when one request replaces another in place — answering session
/// A's card promotes session B's straight into the same `QuestionBar`. The
/// answers collected for A then led B's submission, and since answers are
/// mapped onto questions by position, B's question was sent A's answer.
/// Recording against a different request therefore starts over. (#333)
struct QuestionWizardState {
    private(set) var requestId: UUID?
    private(set) var currentQuestionIndex = 0
    private(set) var collectedAnswers: [AskUserQuestionAnswer] = []
    var selectedIndex: Int?
    var selectedIndices: Set<Int> = []
    var showOtherInput = false
    var otherText = ""
    var textInput = ""

    init(requestId: UUID? = nil) {
        self.requestId = requestId
    }

    /// Drop everything collected for any other request.
    mutating func bind(to requestId: UUID?) {
        guard self.requestId != requestId else { return }
        self = QuestionWizardState(requestId: requestId)
    }

    /// Record the answer to the current question of the request `requestId`,
    /// which asks `questionCount` questions. Returns the submission — one
    /// answer per question, all given on that request — once the last one is
    /// answered, and nil while more remain.
    ///
    /// The final answer is not kept: if the submission is refused, answering
    /// again must not append a second copy.
    mutating func record(
        _ answer: AskUserQuestionAnswer,
        for requestId: UUID?,
        questionCount: Int
    ) -> [AskUserQuestionAnswer]? {
        bind(to: requestId)
        guard currentQuestionIndex + 1 < questionCount else {
            return collectedAnswers + [answer]
        }
        collectedAnswers.append(answer)
        currentQuestionIndex += 1
        resetInput()
        return nil
    }

    mutating func goBack() {
        guard currentQuestionIndex > 0, !collectedAnswers.isEmpty else { return }
        collectedAnswers.removeLast()
        currentQuestionIndex -= 1
        resetInput()
    }

    mutating func resetInput() {
        selectedIndex = nil
        selectedIndices = []
        showOtherInput = false
        otherText = ""
        textInput = ""
    }

    // What the card's primary button would send. While it would send
    // nothing, the button shows as unavailable instead of doing nothing.

    /// Submit on a question answered by typing.
    var canSubmitText: Bool { !textInput.isEmpty }
    /// Submit under "Other" on a single-choice question.
    var canSubmitOther: Bool { !otherText.isEmpty }
    /// Confirm on a multiple-choice question: something ticked, or an
    /// "Other" answer typed.
    var canConfirmMultiSelect: Bool {
        !selectedIndices.isEmpty || (showOtherInput && !otherText.isEmpty)
    }
}

enum QuestionTextMetrics {
    /// Lines the question itself may take. At three, a question that sets out
    /// its options first lost the actual ask ("Which approach should I
    /// take?") to the ellipsis. The options scroll now, so the question gets
    /// the room; the tooltip has anything past this.
    static let lineLimit = 8
}

/// When a notch card may pull keyboard focus into its own text field (#297).
enum NotchCardFocusPolicy {
    /// The island is a non-activating overlay: a question card usually appears
    /// while the user is typing in their editor, or opens under a mouse that is
    /// only passing over to read it. Focusing the answer field then took the
    /// keystrokes meant for the editor. Only do it when the user is already
    /// working in the panel (it is key because they clicked into it); otherwise
    /// the field takes focus when clicked, like any text field.
    static func shouldFocusQuestionFieldOnAppear(panelIsKeyWindow: Bool) -> Bool {
        panelIsKeyWindow
    }
}

private struct QuestionBar: View {
    let question: String
    let options: [String]?
    let descriptions: [String]?
    /// All AskUserQuestion items (1-4). Empty for legacy Notification questions.
    let allQuestions: [AskUserQuestionItem]
    /// The `QuestionRequest` this card answers; nil for the debug preview.
    let requestId: UUID?
    let sessionSource: String?
    let sessionContext: String?
    /// Owning session, so the card can focus its terminal on click the same way
    /// ApprovalBar does. Optional: the session may be gone while the card is
    /// still on screen.
    let session: SessionSnapshot?
    let sessionId: String
    let appState: AppState
    let queuePosition: Int
    let queueTotal: Int
    let onAnswer: (String) -> Void
    let onAnswerMulti: ([AskUserQuestionAnswer]) -> Void
    let onSkip: () -> Void
    /// Close the card without answering; the request keeps waiting.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    // Click-to-jump state, mirroring ApprovalBar
    @State private var failureShakeOffset: CGFloat = 0
    @State private var jumpValidationTask: Task<Void, Never>?
    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize

    // Multi-question wizard state, bound to `requestId` (#333)
    @State private var wizard = QuestionWizardState()
    @FocusState private var otherFocused: Bool

    private let cyan = Burrow.amber
    /// The options never shrink below about two rows.
    static let optionsMinimumHeight: CGFloat = 72

    private var type: NotchCardTypography { NotchCardTypography(contentFontSize: contentFontSize) }

    private var currentItem: AskUserQuestionItem? {
        guard !allQuestions.isEmpty, wizard.currentQuestionIndex < allQuestions.count else { return nil }
        return allQuestions[wizard.currentQuestionIndex]
    }

    private var canJumpToTerminal: Bool {
        session != nil
    }

    var body: some View {
        // The pet's stage heads the card and names the session (it is also
        // the click-to-jump target), so there is no separate context row.
        VStack(alignment: .leading, spacing: 10) {
            if let item = currentItem {
                multiQuestionContent(item)
            } else {
                legacyQuestionContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .offset(x: failureShakeOffset)
        .onAppear {
            let panelIsKey = (NSApp.delegate as? AppDelegate)?.panelController?.isPanelKeyWindow ?? false
            if NotchCardFocusPolicy.shouldFocusQuestionFieldOnAppear(panelIsKeyWindow: panelIsKey) {
                isFocused = true
            }
        }
        .onChange(of: requestId, initial: true) { _, newId in
            // The caller keys this view by request, so a new request normally
            // gets a fresh view; this keeps the wizard honest if it does not.
            wizard.bind(to: newId)
        }
        .onDisappear {
            jumpValidationTask?.cancel()
            jumpValidationTask = nil
        }
    }

    private var sessionContextRow: some View {
        NotchCardContextRow(
            source: sessionSource,
            cwd: sessionContext,
            session: session,
            canJump: canJumpToTerminal,
            queuePosition: queuePosition,
            queueTotal: queueTotal,
            type: type,
            onJump: handleCardClick
        )
    }

    // MARK: - Click-to-jump handling

    /// Focus the terminal that asked the question. Same contract as
    /// ApprovalBar.handleCardClick(): the question stays queued, so collapsing
    /// after a successful jump never discards it — unlike Skip, which denies.
    private func handleCardClick() {
        jumpValidationTask?.cancel()
        jumpValidationTask = startNotchCardJump(
            kind: .question,
            session: session,
            sessionId: sessionId,
            appState: appState,
            autoCollapseAfterJump: autoCollapseAfterSessionJump,
            shakeOffset: $failureShakeOffset
        )
    }

    // MARK: - Shared pieces

    /// "?" + optional header chip + the whole question (up to
    /// QuestionTextMetrics.lineLimit lines; the tooltip has the rest).
    private func questionHeader(_ text: String, header: String?, progress: String?) -> some View {
        let queue = NotchCardQueueLabel.text(position: queuePosition, total: queueTotal)
        let extras = [header, progress, queue].compactMap { $0 }.filter { !$0.isEmpty }
        return BurrowCardStage(
            session: session,
            sessionId: sessionId,
            title: text,
            subtitle: BurrowCardSubtitle.text(session: session, extra: extras.isEmpty ? nil : extras.joined(separator: " · ")),
            onTap: canJumpToTerminal ? { handleCardClick() } : nil
        )
        .help(text)
    }

    private func answerField(_ text: Binding<String>, focus: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(">")
                .font(Burrow.mono(type.secondary, .bold))
                .foregroundStyle(Burrow.amber)
                .accessibilityHidden(true)
            TextField(L10n.shared["type_answer"], text: text)
                .textFieldStyle(.plain)
                .font(Burrow.font(type.link + 1))
                .foregroundStyle(Burrow.ink)
                .focused(focus)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Burrow.wellRadius).fill(Burrow.well))
        .overlay(
            RoundedRectangle(cornerRadius: Burrow.wellRadius)
                .strokeBorder(Burrow.wellEdge, lineWidth: 1)
        )
    }

    /// The card's one filled button, when the question needs one: a tap on
    /// a single-choice option already answers it.
    private struct PrimaryAction {
        let label: String
        let isEnabled: Bool
        let action: () -> Void
    }

    /// Back (later wizard steps) leading; Hide, Skip and the primary trailing
    /// — the approval card's order, Skip standing where Deny does.
    private func actionRow(showsBack: Bool, primary: PrimaryAction?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if showsBack { backButton(expands: false) }
                Spacer(minLength: 12)
                trailingButtons(primary: primary, expands: false)
            }
            HStack(spacing: 6) {
                if showsBack { backButton(expands: false) }
                trailingButtons(primary: primary, expands: true)
            }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
        }
    }

    private func backButton(expands: Bool) -> some View {
        NotchCardButton(label: L10n.shared["card_back"], role: .quiet, fontSize: type.button,
                        expands: expands, systemImage: "chevron.left", action: goBack)
    }

    @ViewBuilder
    private func trailingButtons(primary: PrimaryAction?, expands: Bool) -> some View {
        NotchCardButton(label: L10n.shared["card_hide"], role: .quiet, fontSize: type.button,
                        help: L10n.shared["dismiss_card_hint"], action: onDismiss)
        NotchCardButton(label: L10n.shared["card_skip"], role: .secondary, fontSize: type.button,
                        hint: CardShortcutHint.text(for: .skipQuestion),
                        help: L10n.shared["skip_question_hint"], expands: expands, action: onSkip)
        if let primary {
            NotchCardButton(label: primary.label, role: .primary, fontSize: type.button,
                            isEnabled: primary.isEnabled, expands: expands, action: primary.action)
        }
    }

    // MARK: - Multi-question content (AskUserQuestion)

    @ViewBuilder
    private func multiQuestionContent(_ item: AskUserQuestionItem) -> some View {
        // Header with the wizard's progress. Top-aligned: the question may wrap.
        questionHeader(
            item.payload.question,
            header: item.payload.header,
            progress: allQuestions.count > 1 ? "\(wizard.currentQuestionIndex + 1)/\(allQuestions.count)" : nil
        )

        // Options — scroll past what the window holds, so a long list never
        // pushes "Other" and the buttons out of reach.
        if let opts = item.payload.options, !opts.isEmpty {
            PanelFittedScrollArea(minimumHeight: Self.optionsMinimumHeight) {
                VStack(spacing: 4) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { idx, option in
                        let desc = item.payload.descriptions?.indices.contains(idx) == true ? item.payload.descriptions?[idx] : nil
                        if item.multiSelect {
                            MultiSelectRow(index: idx + 1, label: option, description: desc,
                                           isChecked: wizard.selectedIndices.contains(idx), accent: cyan, type: type) {
                                if wizard.selectedIndices.contains(idx) {
                                    wizard.selectedIndices.remove(idx)
                                } else {
                                    wizard.selectedIndices.insert(idx)
                                }
                            }
                        } else {
                            OptionRow(index: idx + 1, label: option, description: desc,
                                      isSelected: wizard.selectedIndex == idx, accent: cyan, type: type) {
                                wizard.selectedIndex = idx
                                wizard.showOtherInput = false
                                advanceWithAnswer(option, selectedOptions: [option])
                            }
                        }
                    }

                    // "Other" option
                    otherOptionRow(isMultiSelect: item.multiSelect)

                    // "Other" text input, indented under its row
                    if wizard.showOtherInput {
                        answerField($wizard.otherText, focus: $otherFocused) {
                            if !item.multiSelect && wizard.canSubmitOther {
                                advanceWithAnswer(wizard.otherText, customInput: wizard.otherText)
                            }
                        }
                        .padding(.horizontal, 14)
                        .onAppear { otherFocused = true }
                    }
                }
                .padding(.horizontal, 14)
            }
            // The scroller runs along the panel's edge, not over the rows.
            .padding(.horizontal, -14)
        } else {
            // No options — text input only
            answerField($wizard.textInput, focus: $isFocused, onSubmit: submitFreeText)
        }

        actionRow(showsBack: wizard.currentQuestionIndex > 0, primary: primaryAction(for: item))
    }

    private func primaryAction(for item: AskUserQuestionItem) -> PrimaryAction? {
        if item.payload.options?.isEmpty != false {
            return PrimaryAction(label: L10n.shared["card_submit"], isEnabled: wizard.canSubmitText, action: submitFreeText)
        }
        if item.multiSelect {
            return PrimaryAction(label: L10n.shared["card_confirm"], isEnabled: wizard.canConfirmMultiSelect,
                                 action: confirmMultiSelect)
        }
        if wizard.showOtherInput {
            return PrimaryAction(label: L10n.shared["card_submit"], isEnabled: wizard.canSubmitOther) {
                if wizard.canSubmitOther { advanceWithAnswer(wizard.otherText, customInput: wizard.otherText) }
            }
        }
        return nil
    }

    // MARK: - "Other" option row

    @ViewBuilder
    private func otherOptionRow(isMultiSelect: Bool) -> some View {
        if isMultiSelect {
            MultiSelectRow(index: -1, label: L10n.shared["other"], description: nil,
                           isChecked: wizard.showOtherInput, accent: cyan, type: type) {
                wizard.showOtherInput.toggle()
                if !wizard.showOtherInput { wizard.otherText = "" }
            }
        } else {
            OptionRow(index: -1, label: L10n.shared["other"], description: nil,
                      isSelected: wizard.showOtherInput, accent: cyan, type: type) {
                wizard.showOtherInput = true
                wizard.selectedIndex = nil
            }
        }
    }

    // MARK: - Navigation

    private func submitFreeText() {
        guard let item = currentItem,
              let answer = makeQuestionBarFreeTextAnswer(
                  question: item.payload.question,
                  text: wizard.textInput
              ) else { return }
        advance(with: answer)
    }

    private func advanceWithAnswer(
        _ answer: String,
        selectedOptions: [String] = [],
        customInput: String? = nil
    ) {
        guard let item = currentItem else { return }
        advance(with: AskUserQuestionAnswer(
            question: item.payload.question,
            answer: answer,
            selectedOptions: selectedOptions,
            customInput: customInput
        ))
    }

    private func advance(with answer: AskUserQuestionAnswer) {
        var next = wizard
        if let submission = next.record(answer, for: requestId, questionCount: allQuestions.count) {
            wizard = next
            onAnswerMulti(submission)
        } else {
            withAnimation(NotchAnimation.micro) {
                wizard = next
            }
        }
    }

    private func confirmMultiSelect() {
        guard let item = currentItem, let opts = item.payload.options else { return }
        let selectedOptions = wizard.selectedIndices.sorted().compactMap { idx in
            opts.indices.contains(idx) ? opts[idx] : nil
        }
        let customInput = wizard.showOtherInput && !wizard.otherText.isEmpty ? wizard.otherText : nil
        let parts = selectedOptions + (customInput.map { [$0] } ?? [])
        guard !parts.isEmpty else { return }
        advanceWithAnswer(
            parts.joined(separator: ", "),
            selectedOptions: selectedOptions,
            customInput: customInput
        )
    }

    private func goBack() {
        withAnimation(NotchAnimation.micro) {
            wizard.goBack()
        }
    }

    // MARK: - Legacy single-question content (Notification-based)

    @ViewBuilder
    private var legacyQuestionContent: some View {
        questionHeader(question, header: nil, progress: nil)

        if let options = options, !options.isEmpty {
            PanelFittedScrollArea(minimumHeight: Self.optionsMinimumHeight) {
                VStack(spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                        let desc = descriptions?.indices.contains(idx) == true ? descriptions?[idx] : nil
                        OptionRow(index: idx + 1, label: option, description: desc,
                                  isSelected: wizard.selectedIndex == idx, accent: cyan, type: type) {
                            wizard.selectedIndex = idx
                            onAnswer(option)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.horizontal, -14)
            actionRow(showsBack: false, primary: nil)
        } else {
            answerField($wizard.textInput, focus: $isFocused) {
                if wizard.canSubmitText { onAnswer(wizard.textInput) }
            }
            actionRow(showsBack: false, primary: PrimaryAction(
                label: L10n.shared["card_submit"], isEnabled: wizard.canSubmitText
            ) {
                if wizard.canSubmitText { onAnswer(wizard.textInput) }
            })
        }
    }
}

// MARK: - Multi-Select Row (checkbox style)

private struct MultiSelectRow: View {
    let index: Int
    let label: String
    let description: String?
    let isChecked: Bool
    let accent: Color
    let type: NotchCardTypography
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: type.body))
                    .foregroundStyle(isChecked ? accent : Burrow.dim)
                    .frame(width: type.body + 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Burrow.font(type.body + 1, .semibold))
                        .foregroundStyle(Burrow.ink)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(Burrow.font(type.caption + 0.5))
                            .foregroundStyle(Burrow.dim)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Burrow.wellRadius)
                    .fill(isChecked ? accent.opacity(0.10) : (hovering ? Burrow.hover : Burrow.well))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Burrow.wellRadius)
                    .strokeBorder(isChecked ? accent.opacity(0.45) : Burrow.wellEdge, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

// MARK: - Option Row

private struct OptionRow: View {
    let index: Int
    let label: String
    let description: String?
    let isSelected: Bool
    let accent: Color
    let type: NotchCardTypography
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Number (or ellipsis for "Other"), in a fixed column so the
                // labels line up whatever the digit.
                Text(index > 0 ? "\(index)" : "…")
                    .font(Burrow.mono(type.secondary, .semibold))
                    .foregroundStyle(accent.opacity(hovering ? 1 : 0.85))
                    .frame(minWidth: (type.secondary * 1.4).rounded(), alignment: .leading)
                // Label + Description
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Burrow.font(type.body + 1, .semibold))
                        .foregroundStyle(Burrow.ink)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(Burrow.font(type.caption + 0.5))
                            .foregroundStyle(Burrow.dim)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Burrow.wellRadius)
                    .fill(hovering ? Burrow.hover : Burrow.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Burrow.wellRadius)
                    .strokeBorder(hovering ? accent.opacity(0.45) : Burrow.wellEdge, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The card header's git branch next to a long project name.
enum BranchLabelMetrics {
    /// Characters a squeezed branch keeps. The project name outranks it,
    /// and with no floor a long name left the branch an icon and "…".
    static let minimumCharacters = 12

    /// The branch's full width when it is short, else room for
    /// `minimumCharacters` (middle-truncated).
    static func minimumWidth(for label: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let glyph = ("M" as NSString).size(withAttributes: [.font: font]).width
        let full = (label as NSString).size(withAttributes: [.font: font]).width
        return (min(full, glyph * CGFloat(minimumCharacters)) + 1).rounded(.up)
    }
}

/// Namespace for jump animation utilities shared between ApprovalBar and SessionCard
enum JumpAnimationHelper {
    static let shakeSequence = [8, -8, 6, -6, 3, -3, 0]
    static let shakeStepDuration: UInt64 = 35_000_000

    @MainActor
    static func runShake(offset: Binding<CGFloat>) async {
        for value in shakeSequence {
            withAnimation(.easeInOut(duration: 0.035)) {
                offset.wrappedValue = CGFloat(value)
            }
            try? await Task.sleep(nanoseconds: shakeStepDuration)
        }
    }
}

enum JumpValidationOutcome: Equatable {
    case success
    case failed
    case cancelled
}

func evaluateJumpValidation(
    delays: [UInt64],
    isCancelled: () -> Bool = { Task.isCancelled },
    sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
    checkSucceeded: () async -> Bool
) async -> JumpValidationOutcome {
    for delay in delays {
        await sleep(delay)
        if isCancelled() { return .cancelled }
        if await checkSucceeded() { return .success }
    }

    return isCancelled() ? .cancelled : .failed
}

/// Which notch card a click-to-jump was started from.
///
/// The jump validation runs asynchronously, so by the time it lands the panel
/// may already be showing a different card. Collapsing on a surface the jump
/// did not originate from would discard a live card the user never touched —
/// the same class of cross-card mix-up as #308.
enum NotchCardKind: Equatable {
    case approval
    case question

    /// Is `surface` still the card this jump started from?
    func matches(_ surface: IslandSurface) -> Bool {
        switch (self, surface) {
        case (.approval, .approvalCard), (.question, .questionCard):
            return true
        default:
            return false
        }
    }
}

/// Retry schedule for checking whether a click-to-jump actually landed.
let sessionJumpValidationDelays: [UInt64] = [120_000_000, 320_000_000, 640_000_000]

/// Did the terminal owning `session` come to the front?
func sessionJumpSucceeded(_ session: SessionSnapshot) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = TerminalVisibilityDetector.isSessionTabVisible(session)
                || TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
            continuation.resume(returning: succeeded)
        }
    }
}

/// Shared click-to-jump driver for the notch cards (approval + question).
///
/// Both cards behave identically on click: activate the owning terminal, then
/// poll a few times to see whether the jump landed — collapsing the notch on
/// success, error sound + shake on failure. Only the surface allowed to
/// collapse differs, which is what `kind` selects.
///
/// Returns the validation task so the caller can cancel it on disappear, or
/// nil when there is nothing to validate.
func startNotchCardJump(
    kind: NotchCardKind,
    session: SessionSnapshot?,
    sessionId: String,
    appState: AppState,
    autoCollapseAfterJump: Bool,
    shakeOffset: Binding<CGFloat>,
    delays: [UInt64] = sessionJumpValidationDelays
) -> Task<Void, Never>? {
    // Session may be nil if it was removed while the card is still visible
    guard let session else {
        return Task { @MainActor in
            SoundManager.shared.preview("burrow_error")
            await JumpAnimationHelper.runShake(offset: shakeOffset)
        }
    }

    TerminalActivator.activate(session: session, sessionId: sessionId)

    guard autoCollapseAfterJump else { return nil }

    // Validate jump: retry 3x with increasing delays (120ms, 320ms, 640ms)
    // Collapse on success; play error sound + shake on failure
    return Task {
        let outcome = await evaluateJumpValidation(
            delays: delays,
            checkSucceeded: { await sessionJumpSucceeded(session) }
        )

        switch outcome {
        case .success:
            guard !Task.isCancelled else { return }
            // Auto-collapse to collapsed surface on successful jump
            await MainActor.run {
                guard kind.matches(appState.surface) else { return }
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        case .failed:
            guard !Task.isCancelled else { return }
            await MainActor.run {
                SoundManager.shared.preview("burrow_error")
            }
            guard !Task.isCancelled else { return }
            await JumpAnimationHelper.runShake(offset: shakeOffset)
        case .cancelled:
            return
        }
    }
}

// MARK: - Notch Panel Shape (inverse radius at top, regular radius at bottom)

/// The island's black silhouette and clip drawn by SwiftUI — for a
/// NotchPanelView hosted without a NotchIslandShapeDriver.
private struct SwiftUIIslandChrome: ViewModifier {
    let enabled: Bool
    let geometry: NotchIslandGeometry
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(width: geometry.width)
                        .offset(x: geometry.centerOffset)
                }
                .background(alignment: .top) {
                    NotchPanelShape(
                        topExtension: geometry.topExtension,
                        bottomRadius: geometry.bottomRadius,
                        minHeight: minHeight
                    )
                    .fill(.black)
                    .frame(width: geometry.width)
                    .offset(x: geometry.centerOffset)
                }
        } else {
            content
        }
    }
}

/// Hover and click area: the island's rectangle inside the full-width
/// layer stack. `height` nil runs to the bottom of the stack.
private struct NotchIslandHitShape: Shape {
    let width: CGFloat
    let height: CGFloat?
    let centerOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.midX + centerOffset - width / 2,
            y: rect.minY,
            width: width,
            height: height ?? rect.height
        ))
    }
}

private struct NotchPanelShape: Shape {
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    /// Fixed minimum height — NOT animated, prevents spring overshoot from exposing the notch
    var minHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = topExtension
        let maxY = max(rect.maxY, rect.minY + minHeight)
        let br = min(bottomRadius, rect.width / 4, (maxY - rect.minY) / 2)
        // Smoothness factor for continuous-curvature corners (superellipse approximation).
        // 0.5523 = perfect circle; higher values tighten the curve for an Apple squircle feel.
        let k: CGFloat = 0.62

        var p = Path()
        // Top edge (extends into notch area via wings)
        p.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        // Right shoulder: cubic bezier tangent to top line (horizontal) and right side (vertical)
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        // Right side down to bottom-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: maxY - br))
        // Bottom-right: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.maxX - br, y: maxY),
            control1: CGPoint(x: rect.maxX, y: maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: maxY)
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: rect.minX + br, y: maxY))
        // Bottom-left: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.minX, y: maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: maxY),
            control2: CGPoint(x: rect.minX, y: maxY - br * (1 - k))
        )
        // Left side up to shoulder
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + ext))
        // Left shoulder: cubic bezier tangent to left side (vertical) and top line (horizontal)
        p.addCurve(
            to: CGPoint(x: rect.minX - ext, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// Terminal icon + name badge (display only, not a button)
private struct TerminalBadge: View {
    let session: SessionSnapshot

    /// The card header keeps its tags at full size, so a long terminal or
    /// host name is cut here rather than squeezing the project name.
    static let labelMaxWidth: CGFloat = 96

    private static let sourceBundleIds: [String: String] = [
        "codex": "com.openai.codex",
        "opencode": "ai.opencode.desktop",
    ]
    private static var termIconCache: [String: NSImage] = [:]

    private var termIcon: NSImage? {
        // CLI hosted in a foreign IDE: show the agent icon, not the host IDE.
        if session.isCLIHostedInForeignApp,
           let src = SessionSnapshot.normalizedSupportedSource(session.source),
           let icon = cliIcon(source: src, size: 13) {
            return icon
        }
        let bid = session.termBundleId ?? Self.sourceBundleIds[session.mascotSource]
        guard let bid else { return nil }
        if let cached = Self.termIconCache[bid] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.termIconCache[bid] = icon
        return icon
    }

    private var badgeLabel: String? {
        session.terminalBadgeLabel
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = termIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            if let term = badgeLabel {
                Text(term)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .hugWidth(of: term, fontSize: 9.5, upTo: Self.labelMaxWidth)
            }
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Shared Helpers

private let cliIconFiles: [String: String] = [
    "claude": "claude",
    "codex": "codex",
    "opencode": "opencode",
    "google-antigravity": "antigravity",
]

private var cliIconCache: [String: NSImage] = [:]

func cliIcon(source: String, size: CGFloat = 16) -> NSImage? {
    let key = "\(source)_\(Int(size))"
    if let cached = cliIconCache[key] { return cached }

    guard let filename = cliIconFiles[source],
          let url = Bundle.appModule.url(forResource: filename, withExtension: "png", subdirectory: "Resources/cli-icons"),
          let image = NSImage(contentsOf: url)
    else {
        // No asset (new integrations, custom CLIs): draw a monogram tile so
        // every row in the settings CLI list still gets an icon.
        let fallback = monogramIcon(for: source, size: size)
        cliIconCache[key] = fallback
        return fallback
    }
    image.size = NSSize(width: size, height: size)
    cliIconCache[key] = image
    return image
}

/// Rounded tile with the source's first letter; hue derived from the source
/// name so distinct CLIs get stable, distinct colors.
private func monogramIcon(for source: String, size: CGFloat) -> NSImage {
    let letter = String(source.trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(1)).uppercased()
    // Deterministic hash — Swift's hashValue is seeded per launch and would
    // repaint the tile a different color every run.
    let stableHash = source.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    let hue = Double(stableHash % 360) / 360.0
    let scale: CGFloat = 4  // draw at 4x so small sizes stay crisp
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let bg = NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
        NSBezierPath(roundedRect: rect.insetBy(dx: px * 0.02, dy: px * 0.02),
                     xRadius: px * 0.22, yRadius: px * 0.22).addClip()
        bg.setFill()
        rect.fill()
        let font = NSFont.systemFont(ofSize: px * 0.58, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: letter, attributes: attrs)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (px - textSize.width) / 2, y: (px - textSize.height) / 2))
        return true
    }
    image.size = NSSize(width: size, height: size)
    return image
}

private extension View {
    /// Monospaced label that hugs its text up to `cap` and truncates below
    /// that only when its row runs out of room. `.frame(maxWidth:)` alone
    /// would stretch a short label to the cap.
    @ViewBuilder
    func hugWidth(of text: String, fontSize: CGFloat, upTo cap: CGFloat?) -> some View {
        if let cap {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            let width = min(((text as NSString).size(withAttributes: [.font: font]).width + 1).rounded(.up), cap)
            frame(minWidth: 0, idealWidth: width, maxWidth: width, alignment: .leading)
        } else {
            self
        }
    }
}

// MARK: - Session metadata (recap + model tag)

enum SessionMetadataStyle {
    static let modelTagColor = Color(red: 0.55, green: 0.82, blue: 0.78)
    /// Recap glyph tint — distinct from the green ">" user and orange "$"
    /// reply markers so a recap never reads as the agent speaking.
    static let recapAccent = Color(red: 0.6, green: 0.68, blue: 1.0)

    /// Tooltip for the collapsed bar: the displayed idle session's recap,
    /// headed like its card — so with "Show project name" off it names the
    /// session title (or the agent), never the folder.
    static func collapsedRecapTooltip(for session: SessionSnapshot?, showProjectName: Bool) -> String {
        guard let session, let recap = session.visibleRecap else { return "" }
        return "↻ \(session.headline(showProjectName: showProjectName).text)\n\(recap.text)"
    }
}
