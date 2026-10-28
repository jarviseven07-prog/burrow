import AppKit
import ApplicationServices
import CodeIslandCore

/// Brings forward the window running a session: Claude Desktop's Code tab, the
/// agent's own app, Terminal.app's tab, or any other app's window by folder.
struct TerminalActivator {

    /// Reverse map: source → native app bundle ID. Used as a fallback when
    /// termBundleId is missing but the source's desktop app is running.
    static let sourceToNativeAppBundleId: [String: String] = [
        "codex": "com.openai.codex",
        "opencode": "ai.opencode.desktop",
    ]

    /// Bundle IDs of apps that have both APP and CLI modes.
    /// When termBundleId matches, bring that app to front;
    /// otherwise fall through to terminal tab-matching.
    private static let nativeAppBundles: [String: String] = [
        "com.openai.codex": "Codex",
        "ai.opencode.desktop": "OpenCode",
        "com.google.antigravity": "Antigravity",
        // Claude Code Desktop (#211). Deliberately NOT in sourceToNativeAppBundleId:
        // most "claude" sessions are terminal CLI runs, and that fallback would
        // steal their click-to-jump whenever the desktop app happens to be open.
        "com.anthropic.claudefordesktop": "Claude",
    ]

    static func activate(session: SessionSnapshot, sessionId: String? = nil) {
        // A Claude Code session run from Claude Desktop's Code tab: open that
        // exact session. Raising the app alone left the user on whichever
        // session it last showed.
        if let hostId = session.claudeDesktopSessionId,
           let url = ClaudeDesktopCodeSession.deepLinkURL(hostSessionId: hostId) {
            AppState.openInClaudeDesktop(url)
            return
        }

        // The agent's own app (Codex, OpenCode, Claude, Antigravity) or an IDE
        // terminal: these can hold several workspace windows at once, so match
        // the one whose title contains the session's project folder instead of
        // just raising the most-recently-used window (#199). activateIDEWindow
        // falls back to a plain app-level activation when there's no cwd or no
        // matching window.
        if let bundleId = session.termBundleId,
           nativeAppBundles[bundleId] != nil || session.isIDETerminal {
            activateIDEWindow(bundleId: bundleId, cwd: session.cwd)
            return
        }

        // When the source's desktop app is running, prefer it over the terminal
        // (e.g. opencode → OpenCode).
        if let nativeBundleId = sourceToNativeAppBundleId[session.source],
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == nativeBundleId }) {
            activateByBundleId(nativeBundleId)
            return
        }

        // Terminal.app: tab-level switching by TTY, then by folder. Matched by
        // bundle ID — Warp also sets TERM_PROGRAM=Apple_Terminal.
        let termApp = session.termApp ?? ""
        if session.termBundleId == "com.apple.Terminal"
            || (session.termBundleId == nil && ["", "terminal", "apple_terminal"].contains(termApp.lowercased())) {
            activateTerminalApp(ttyPath: session.ttyPath, cwd: session.cwd)
            return
        }

        // Any other terminal: match its window by project folder, else raise it.
        if let bundleId = session.termBundleId, let cwd = session.cwd, !cwd.isEmpty {
            activateTerminalWindow(bundleId: bundleId, cwd: cwd, fallbackName: termApp)
        } else {
            bringToFront(termApp)
        }
    }

    // MARK: - Terminal.app (AppleScript: match by TTY, fallback to CWD)

    private static func activateTerminalApp(ttyPath: String?, cwd: String?) {
        // If Terminal.app is not running, launch it and return — no tab matching possible.
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Terminal"
        }) else {
            bringToFront("Terminal")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()

        let ttyEscaped = ttyPath.map(escapeAppleScript) ?? ""
        let dirEscaped = cwd.map { escapeAppleScript(($0 as NSString).lastPathComponent) } ?? ""

        // Try tty → tab auto-name → user custom title → deminiaturize any window as a last resort.
        // Terminal.app auto-generates `name of t` containing the running command + cwd; `custom title`
        // only exists when the user set it explicitly, so matching against `name` works for the
        // overwhelming default case.
        // Note: locals named `targetTty` / `targetDir` (NOT `tty` / `dir`). AppleScript's
        // resolver can't reliably tell `if tty of t is tty` apart from `if tty of t is
        // tty of <implicit object>` — `tty` is also a tab property name, so reusing it as
        // a local variable causes Strategy 1 to silently misfire and Strategy 2 to
        // fall through, which manifested as "click any session, jumps to the same tab"
        // (issue #124).
        let script = """
        tell application "Terminal"
            set targetTty to "\(ttyEscaped)"
            set targetDir to "\(dirEscaped)"
            set found to false

            -- Strategy 1: precise tty match
            -- `tabs of w` is wrapped in its own try: Terminal.app can keep a window
            -- with no tabs at all (invisible utility window: name "", visible false).
            -- Asking it for tabs raises -10000, which would abort the whole tell block
            -- and skip every later window plus the final `activate`.
            if targetTty is not "" then
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            try
                                if tty of t is targetTty then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected tab of w to t
                                    set index of w to 1
                                    set found to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if found then exit repeat
                end repeat
            end if

            -- Strategy 2: auto tab title contains the cwd folder name
            if not found and targetDir is not "" then
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            try
                                if (name of t as text) contains targetDir then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected tab of w to t
                                    set index of w to 1
                                    set found to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if found then exit repeat
                end repeat
            end if

            -- Strategy 3: user-set custom title
            if not found and targetDir is not "" then
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            try
                                if custom title of t contains targetDir then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected tab of w to t
                                    set index of w to 1
                                    set found to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if found then exit repeat
                end repeat
            end if

            -- Fallback: unminimize the first miniaturized window so the user always sees something.
            if not found then
                repeat with w in windows
                    try
                        if miniaturized of w then
                            set miniaturized of w to false
                            set index of w to 1
                            exit repeat
                        end if
                    end try
                end repeat
            end if

            activate
        end tell

        -- Final fallback via System Events: when Terminal.app's `windows` collection doesn't
        -- include a minimized window (some macOS 14 cases), or when osascript silently no-ops,
        -- force both frontmost and AXMinimized=false through Accessibility (issue #124).
        try
            tell application "System Events"
                tell process "Terminal"
                    set frontmost to true
                    repeat with w in windows
                        try
                            if value of attribute "AXMinimized" of w is true then
                                set value of attribute "AXMinimized" of w to false
                            end if
                        end try
                    end repeat
                end tell
            end tell
        end try
        """
        runAppleScript(script)
    }

    // MARK: - IDE window-level activation (JetBrains, VS Code, Zed, etc.)

    /// Activate the specific IDE window whose title contains the project folder name.
    /// Falls back to app-level activation if no CWD or no matching window found.
    private static func activateIDEWindow(bundleId: String, cwd: String?) {
        guard let cwd = cwd, !cwd.isEmpty else {
            activateByBundleId(bundleId)
            return
        }
        let folderName = (cwd as NSString).lastPathComponent
        guard !folderName.isEmpty else {
            activateByBundleId(bundleId)
            return
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            activateByBundleId(bundleId)
            return
        }

        if app.isHidden { app.unhide() }
        app.activate()

        // Use System Events to iterate windows and AXRaise the best match.
        // Priority: exact folder name at word boundary > shortest title containing folder name.
        // This avoids jumping to the wrong window when multiple projects share a folder name
        // (e.g., /work/app vs /backup/app).
        let appName = app.localizedName ?? "Application"
        let escapedFolder = escapeAppleScript(folderName)
        let script = """
        tell application "System Events"
            tell process "\(escapeAppleScript(appName))"
                set frontmost to true
                set bestWindow to missing value
                set bestLen to 999999
                repeat with w in windows
                    try
                        set wName to name of w as text
                        if wName contains "\(escapedFolder)" then
                            set wLen to count of wName
                            if wLen < bestLen then
                                set bestWindow to w
                                set bestLen to wLen
                            end if
                        end if
                    end try
                end repeat
                if bestWindow is not missing value then
                    perform action "AXRaise" of bestWindow
                end if
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Generic terminal window matching

    /// For terminals without tab-switching APIs, try to raise the window whose title
    /// contains the project folder name via System Events. Falls back to app-level.
    private static func activateTerminalWindow(bundleId: String, cwd: String, fallbackName: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            bringToFront(fallbackName)
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()

        let folderName = (cwd as NSString).lastPathComponent
        guard !folderName.isEmpty else { return }

        let appName = app.localizedName ?? fallbackName
        let script = """
        tell application "System Events"
            tell process "\(escapeAppleScript(appName))"
                repeat with w in windows
                    try
                        if name of w contains "\(escapeAppleScript(folderName))" then
                            perform action "AXRaise" of w
                            return
                        end if
                    end try
                end repeat
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Activate by bundle ID

    private static func activateByBundleId(_ bundleId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
        }
        // Also use openApplication for reliable Space switching (Electron apps like VSCode)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Generic (bring app to front)

    private static func bringToFront(_ termApp: String) {
        let name: String
        let lower = termApp.lowercased()
        if lower.isEmpty || lower.contains("terminal") { name = "Terminal" }
        else { name = termApp }

        // Try NSRunningApplication first — handles Space switching and unhide
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(name)
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
            return
        }
        // Fallback: open -a (app not running yet)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", name]
            try? proc.run()
        }
    }

    // MARK: - Helpers

    /// Fire-and-forget, off the caller's queue as before, so a click on the main
    /// thread never waits for osascript to spawn. Out of process rather than
    /// NSAppleScript, which is main-thread-only — see AppleScriptRunner. The
    /// runner is read here, not on the queue, so a test that swaps it around a
    /// call sees that call's script.
    private static func runAppleScript(_ source: String) {
        let runner = AppleScriptRunner.current
        DispatchQueue.global(qos: .userInitiated).async {
            runner.launch(source)
        }
    }

    /// Escape special characters for AppleScript string interpolation
    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
