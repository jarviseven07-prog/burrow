import AppKit
import CodeIslandCore

/// Detects whether a session's terminal tab/pane is currently the active (visible) one.
/// Used by smart-suppress to avoid notifying when the user is already looking at the session.
///
/// Two detection levels:
/// - **App-level** (`isTerminalFrontmostForSession`): fast, main-thread safe, checks if the
///   terminal app is the frontmost application. No AppleScript or subprocess calls.
/// - **Tab-level** (`isSessionTabVisible`): precise, checks the specific tab/session/pane.
///   Uses AppleScript or CLI calls that may block 50-200ms. Call from background thread only.
///
/// Tab-level detection covers Terminal.app (TTY match on the selected tab); an
/// agent's own app or an IDE counts as visible when it is in front, and any
/// other terminal falls back to app-level only.
struct TerminalVisibilityDetector {

    // MARK: - Probe (what callers consult)

    /// The two checks as one swappable pair. Every caller — Smart Suppress,
    /// jump validation, the question card — goes through
    /// `probe`, so a test process never reads the real frontmost app or scripts
    /// the terminal of whoever runs the suite: it gets `.unknown` unless a test
    /// installs its own answer.
    struct Probe: Sendable {
        /// App level; cheap enough for the main thread.
        let isTerminalFrontmost: @Sendable (SessionSnapshot) -> Bool
        /// Tab level; may block on AppleScript or a terminal CLI.
        let isSessionTabVisible: @Sendable (SessionSnapshot) -> Bool

        /// The real desktop: frontmost app, window list, AppleScript, CLIs.
        static let live = Probe(
            isTerminalFrontmost: { TerminalVisibilityDetector.liveIsTerminalFrontmost($0) },
            isSessionTabVisible: { TerminalVisibilityDetector.liveIsSessionTabVisible($0) }
        )

        /// "Can't tell" — what the detector already answers for a terminal it
        /// cannot inspect: not visible, so nothing is suppressed.
        static let unknown = Probe(
            isTerminalFrontmost: { _ in false },
            isSessionTabVisible: { _ in false }
        )
    }

    /// Read from any thread; tests swap it.
    static var probe: Probe {
        get {
            probeLock.lock()
            defer { probeLock.unlock() }
            return installedProbe
        }
        set {
            probeLock.lock()
            installedProbe = newValue
            probeLock.unlock()
        }
    }

    private static let probeLock = NSLock()
    private static var installedProbe: Probe = RuntimeEnvironment.isRunningTests ? .unknown : .live

    /// Fast check: is the session's terminal app the frontmost application?
    /// Safe to call from the main thread — no AppleScript or subprocess calls.
    static func isTerminalFrontmostForSession(_ session: SessionSnapshot) -> Bool {
        probe.isTerminalFrontmost(session)
    }

    /// Full check: is the session's specific tab/pane currently visible?
    /// **Call from a background thread only** — AppleScript/CLI calls may block 50-200ms.
    static func isSessionTabVisible(_ session: SessionSnapshot) -> Bool {
        probe.isSessionTabVisible(session)
    }

    // MARK: - App-level check (main-thread safe, no blocking)

    private static func liveIsTerminalFrontmost(_ session: SessionSnapshot) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let frontBundleId = frontApp.bundleIdentifier?.lowercased() ?? ""

        if let termBundleId = session.termBundleId?.lowercased(),
           !termBundleId.isEmpty {
            // Bundle ID is known — match exclusively by bundle ID, don't fall through
            // to TERM_PROGRAM (avoids Warp's TERM_PROGRAM=Apple_Terminal false positive)
            return frontBundleId == termBundleId
        }

        guard let termApp = session.termApp else { return false }

        let frontName = frontApp.localizedName?.lowercased() ?? ""
        let term = termApp.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: "apple_", with: "")
        let normalizedFront = frontName.replacingOccurrences(of: ".app", with: "")

        return normalizedFront.contains(term)
            || term.contains(normalizedFront)
            || frontBundleId.contains(term)
    }

    // MARK: - Tab-level check (background thread only)

    /// What the tab-level check answers once the session's app is in front,
    /// when the app alone decides it; nil when only a tab/pane probe can tell.
    /// Pure and main-thread safe, so a caller that must not block (a queued
    /// completion) can still honour the cases where no probe is needed.
    static func visibilityWhenAppFrontmost(_ session: SessionSnapshot) -> Bool? {
        // Native app bundles (Cursor APP, Codex APP, Claude Desktop): app IS the session, suppress when frontmost
        if session.isNativeAppMode {
            return true
        }

        // IDE integrated terminals (VS Code, JetBrains): we can't query which internal
        // tool-window is focused without Accessibility permission, so fall back to the
        // app-frontmost signal — if the IDE is the frontmost app, assume the terminal is
        // effectively "in view" and let smart-suppress silence the notification (#112).
        // Trade-off: if the user has the editor focused and not the terminal pane, a
        // completion event is also suppressed. That's the same trade-off the OS makes
        // for any app-level "do not disturb while focused" heuristic.
        if session.isIDETerminal {
            return true
        }
        return nil
    }

    private static func liveIsSessionTabVisible(_ session: SessionSnapshot) -> Bool {
        // Fast path: terminal not even frontmost
        guard liveIsTerminalFrontmost(session) else { return false }

        if let decided = visibilityWhenAppFrontmost(session) {
            return decided
        }

        if session.termBundleId?.lowercased() == "com.apple.terminal" {
            return isTerminalAppTabActive(session)
        }

        // Unknown terminal — can't determine tab, prefer showing notification
        return false
    }

    // MARK: - Terminal.app

    /// Check if Terminal.app's selected tab has the matching TTY.
    private static func isTerminalAppTabActive(_ session: SessionSnapshot) -> Bool {
        if let tty = session.ttyPath, !tty.isEmpty {
            let escaped = escapeAppleScript(tty)
            let script = """
            tell application "Terminal"
                try
                    if tty of selected tab of front window is "\(escaped)" then return "true"
                end try
                return "false"
            end tell
            """
            return runAppleScriptSync(script)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        // No TTY — can't precisely identify tab, prefer showing notification
        return false
    }

    // MARK: - Helpers

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run AppleScript synchronously on the calling (background) thread and
    /// return its result as text; nil when it fails. Out of process instead of
    /// NSAppleScript, which is main-thread-only — see AppleScriptRunner. Capped
    /// at 5 s like the CLI probes below: an unanswered check reads as "not
    /// visible", which shows the notification rather than swallowing it.
    private static func runAppleScriptSync(_ source: String) -> String? {
        AppleScriptRunner.current.evaluate(source, 5)
    }
}
