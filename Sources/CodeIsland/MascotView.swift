import SwiftUI
import CodeIslandCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to its mascot. Agents with their own pet
/// (design/pets.json) get the 16x16 pet with buddy's seven states; any
/// other agent gets an empty space of the same size.
struct MascotView: View {
    let source: String
    let status: MascotAgentStatus
    var size: CGFloat = 27
    /// When set, finish / fail / quick-approve reactions for this session play.
    var sessionId: String? = nil
    /// What it is working on, shown above its laptop (the burrow's pets).
    var sign: PetSign? = nil
    @ObservedObject private var animationGate = MascotAnimationGate.shared
    @ObservedObject private var reactions = PetReactionCenter.shared

    /// Buddy's seven states from the island's five statuses plus reactions.
    /// Idle shows the sleeping pose while animations are gated off (collapsed
    /// and nothing running) and the idle carousel otherwise.
    static func petState(status: MascotAgentStatus, reaction: PetState?, animating: Bool) -> PetState {
        // Waiting on you outranks a passing reaction: the next approval often
        // lands while the last one's heart is still up, and the night light
        // (and the click that opens the card) must not wait it out.
        if status == .waitingApproval || status == .waitingQuestion { return .attention }
        if let reaction { return reaction }
        switch status {
        case .idle: return animating ? .idle : .sleep
        case .processing, .running: return .busy
        case .waitingApproval, .waitingQuestion: return .attention
        }
    }

    private func pet(_ species: PetSpecies) -> some View {
        PixelPetView(
            species: species,
            state: Self.petState(status: status,
                                 reaction: reactions.state(forSession: sessionId),
                                 // Asleep only when the island has settled — not
                                 // because Reduce Motion stills the frames.
                                 animating: !animationGate.isIdleSettled),
            size: size,
            phaseStart: reactions.startDate(forSession: sessionId),
            sign: sign
        )
    }

    var body: some View {
        let resolved = SessionSnapshot.normalizedSupportedSource(source) ?? source
        // Burrow: pets always play at the speed they were drawn for. The old
        // mascot-speed slider is gone from Settings, so a value stored under
        // `mascotSpeed` would only slow them down where nobody can see why.
        Group {
            if let species = PetSpecies.bySource[resolved] {
                pet(species)
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
        .environment(\.mascotAnimationsActive, animationGate.animationsActive)
        .environment(\.mascotAnimationEpoch, animationGate.epoch)
    }
}
