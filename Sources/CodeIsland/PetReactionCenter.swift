import Foundation
import CodeIslandCore

/// Short-lived pet reactions on top of the session status, like buddy's
/// celebrate / dizzy / heart: a turn finished, a turn failed, or the user
/// approved a permission request quickly.
@MainActor
final class PetReactionCenter: ObservableObject {
    static let shared = PetReactionCenter()

    enum Reaction {
        case celebrate, dizzy, heart

        var state: PetState {
            switch self {
            case .celebrate: return .celebrate
            case .dizzy: return .dizzy
            case .heart: return .heart
            }
        }

        var duration: TimeInterval {
            switch self {
            case .celebrate: return 3
            case .dizzy: return 4
            case .heart: return 2
            }
        }
    }

    /// An approval this fast earns a heart (buddy uses the same 5s rule).
    static let quickApprovalWindow: TimeInterval = 5

    @Published private(set) var active: [String: Reaction] = [:]
    private var tokens: [String: UUID] = [:]
    private var startedAt: [String: Date] = [:]
    private var askedAt: [UUID: Date] = [:]

    private init() {}

    func state(forSession sessionId: String?) -> PetState? {
        guard let sessionId else { return nil }
        return active[sessionId]?.state
    }

    /// When the session's current reaction began — its animation is played
    /// from there (a celebration starts with its crouch).
    func startDate(forSession sessionId: String?) -> Date? {
        guard let sessionId, active[sessionId] != nil else { return nil }
        return startedAt[sessionId]
    }

    func trigger(_ reaction: Reaction, sessionId: String) {
        let token = UUID()
        tokens[sessionId] = token
        startedAt[sessionId] = Date()
        active[sessionId] = reaction
        DispatchQueue.main.asyncAfter(deadline: .now() + reaction.duration) { [weak self] in
            guard let self, self.tokens[sessionId] == token else { return }
            self.tokens[sessionId] = nil
            self.startedAt[sessionId] = nil
            self.active[sessionId] = nil
        }
    }

    func turnEnded(sessionId: String, failed: Bool) {
        trigger(failed ? .dizzy : .celebrate, sessionId: sessionId)
    }

    func permissionAsked(requestId: UUID) {
        let now = Date()
        // A request answered in the terminal (or dropped) never reports back;
        // past the heart's window its entry can only ever be stale.
        askedAt = askedAt.filter { now.timeIntervalSince($0.value) < Self.quickApprovalWindow }
        askedAt[requestId] = now
    }

    func permissionApproved(requestId: UUID, sessionId: String) {
        guard let asked = askedAt.removeValue(forKey: requestId) else { return }
        if Date().timeIntervalSince(asked) < Self.quickApprovalWindow {
            trigger(.heart, sessionId: sessionId)
        }
    }

    func permissionClosed(requestId: UUID) {
        askedAt[requestId] = nil
    }
}
