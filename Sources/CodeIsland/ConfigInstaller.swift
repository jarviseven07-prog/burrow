import Foundation
import AppKit
import CodeIslandCore

// MARK: - Hook Identifiers

private enum HookId {
    static let current = "codeisland"
    static let legacyNames = ["vibenotch", "vibe-island", "vibeisland"]
    static func isOurs(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains(current) || legacyNames.contains(where: lower.contains)
    }
}

// MARK: - CLI Definitions

/// Hook entry format variants
enum HookFormat {
    case claude
    case nested
    case antigravityNamed

    var storageValue: String {
        switch self {
        case .claude: return "claude"
        case .nested: return "nested"
        case .antigravityNamed: return "antigravityNamed"
        }
    }

    init?(storageValue: String) {
        switch storageValue.lowercased() {
        case "claude": self = .claude
        case "nested": self = .nested
        case "antigravitynamed": self = .antigravityNamed
        default: return nil
        }
    }
}

struct CLIConfig {
    let name: String           // display name
    let source: String         // --source flag value
    let configPath: String     // path to config file (relative to home, or to rootOverride if set)
    let configKey: String      // top-level JSON key containing hooks ("hooks" for most)
    let format: HookFormat
    let events: [(String, Int, Bool)]  // (eventName, timeout, async)
    /// Events that require a minimum CLI version (eventName → minVersion like "2.1.89")
    var versionedEvents: [String: String] = [:]
    /// Optional root directory override. When set, `configPath` is resolved relative to this
    /// directory instead of the user's home (used by Codex to honor $CODEX_HOME).
    var rootOverride: (@Sendable () -> String)? = nil
    /// Optional override for the user-visible config path (e.g. "$CODEX_HOME/hooks.json").
    var displayPathOverride: (@Sendable () -> String)? = nil
    /// Optional override for the `--source` value passed to the bridge.
    var bridgeSourceOverride: String? = nil

    var fullPath: String {
        if let override = rootOverride {
            return override() + "/" + configPath
        }
        if configPath.hasPrefix("/") { return configPath }
        if configPath.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + configPath.dropFirst(2)
        }
        return NSHomeDirectory() + "/\(configPath)"
    }
    var dirPath: String { (fullPath as NSString).deletingLastPathComponent }
    var displayConfigPath: String {
        if let override = displayPathOverride { return override() }
        if configPath.hasPrefix("/") || configPath.hasPrefix("~/") { return configPath }
        return "~/\(configPath)"
    }
}

struct CustomCLIConfig: Codable, Identifiable, Equatable {
    var id: String { source }
    let name: String
    let source: String
    let configPath: String
    let format: String
    let configKey: String
}

struct ConfigInstaller {
    private static let codeislandDir = NSHomeDirectory() + "/.codeisland"
    private static let bridgePath = codeislandDir + "/codeisland-bridge"
    private static let hookScriptPath = codeislandDir + "/codeisland-hook.sh"
    private static let hookCommand = "~/.codeisland/codeisland-hook.sh"
    /// Absolute path for external CLI hooks — avoids tilde expansion issues in IDE environments
    private static let bridgeCommand = codeislandDir + "/codeisland-bridge"


    // Legacy paths for migration cleanup (#32)
    private static let legacyBridgePath = NSHomeDirectory() + "/.claude/hooks/codeisland-bridge"
    private static let legacyHookScriptPath = NSHomeDirectory() + "/.claude/hooks/codeisland-hook.sh"

    // MARK: - Codex home resolution

    /// Resolve Codex's config directory. Honors $CODEX_HOME (with a leading `~` expanded);
    /// falls back to `~/.codex`. Whitespace-only or empty values are treated as unset.
    static func codexHome() -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() + "/.codex" }
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw
    }

    /// User-visible form of a Codex config path (uses `$CODEX_HOME/...` when the env var
    /// is set, otherwise `~/.codex/...`).
    static func displayCodexPath(filename: String) -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~/.codex/\(filename)" : "$CODEX_HOME/\(filename)"
    }

    // MARK: - All supported CLIs

    private static let builtInCLIs: [CLIConfig] = [
        // Claude Code — uses hook script (with bridge dispatcher + nc fallback)
        CLIConfig(
            name: "Claude Code", source: "claude",
            configPath: "settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("PermissionRequest", 86400, false),
                ("Stop", 5, true),
                // Fires *instead of* Stop when the turn ends on an API error
                // (rate limit, overload, auth, billing…). It is the only
                // turn-level failure signal, so it owns the error sound.
                ("StopFailure", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ],
            versionedEvents: [
                "PostToolUseFailure": "2.1.89",
                // Added in Claude Code 2.1.78 (CHANGELOG: "Added `StopFailure`
                // hook event…"); gated like PostToolUseFailure so an older
                // build never sees a hook key it does not know.
                "StopFailure": "2.1.78",
            ],
            rootOverride: { ClaudeConfigPaths.configDir() },
            displayPathOverride: { ClaudeConfigPaths.displayPath(ClaudeConfigPaths.settingsPath()) }
        ),
        // Codex — honors $CODEX_HOME (falls back to ~/.codex)
        CLIConfig(
            name: "Codex", source: "codex",
            configPath: "hooks.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5, false),
                ("SessionEnd", 3, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                // Codex fires PermissionRequest before shell escalation /
                // managed-network approvals. Without this hook the panel
                // stays in "running" and the approval sound never plays —
                // see issue #145 and developers.openai.com/codex/hooks.
                ("PermissionRequest", 86400, false),
                ("PreCompact", 5, false),
                ("PostCompact", 5, false),
                ("SubagentStart", 5, false),
                ("SubagentStop", 5, false),
                ("Stop", 5, false),
                ("Interrupt", 3, false),
            ],
            rootOverride: { ConfigInstaller.codexHome() },
            displayPathOverride: { ConfigInstaller.displayCodexPath(filename: "hooks.json") }
        ),
        // Google Antigravity (Gemini-based IDE/CLI).
        // Reads a STANDALONE ~/.gemini/config/hooks.json (NOT Gemini-CLI's
        // settings.json "hooks" key) wrapped in a named-config object keyed by
        // "codeisland". Event names are Claude-style PascalCase; stdin carries no
        // hook_event_name, so each command needs --event <Event> (#215).
        CLIConfig(
            name: "Google Antigravity", source: "google-antigravity",
            configPath: ".gemini/config/hooks.json", configKey: "codeisland",
            format: .antigravityNamed,
            events: defaultEvents(for: .antigravityNamed),
            rootOverride: { NSHomeDirectory() }
        ),
    ]

    static var allCLIs: [CLIConfig] {
        builtInCLIs
    }

    /// Non-Claude CLIs (installed via bridge binary directly)
    private static var externalCLIs: [CLIConfig] {
        allCLIs.filter { $0.source != "claude" }
    }

    static func defaultEvents(for format: HookFormat) -> [(String, Int, Bool)] {
        switch format {
        case .claude:
            return [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        case .nested:
            return [
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ]
        case .antigravityNamed:
            // Antigravity hooks.json uses Claude-style PascalCase event names.
            // We install the three actionable events for status.
            // PreInvocation/PostInvocation are pass-through with no internal
            // meaning, so they're omitted. Timeout is in SECONDS (docs default 30).
            // PreToolUse no longer waits on an island card — the bridge answers
            // `ask` at once (#339) — and a hook Antigravity has to kill counts
            // as a denial, so it keeps the documented default rather than a
            // day-long ceiling nothing should ever reach.
            return [
                ("PreToolUse", 30, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ]
        }
    }

    /// Hook script version — bump this when the script template changes
    private static let hookScriptVersion = 5

    /// Hook script for Claude Code (dispatcher: bridge binary → nc fallback)
    private static let hookScript = """
        #!/bin/bash
        # CodeIsland hook v\(hookScriptVersion) — native bridge with shell fallback
        BRIDGE="$HOME/.codeisland/codeisland-bridge"
        if [ -x "$BRIDGE" ]; then
          exec "$BRIDGE" "$@"
        fi
        # Fallback: original shell approach (no binary installed yet)
        SOCK="/tmp/codeisland-$(id -u).sock"
        [ -S "$SOCK" ] || exit 0
        INPUT=$(cat)
        _ITERM_GUID="${ITERM_SESSION_ID##*:}"
        TERM_INFO="\\"_term_app\\":\\"${TERM_PROGRAM:-}\\",\\"_iterm_session\\":\\"${_ITERM_GUID:-}\\",\\"_tty\\":\\"$(tty 2>/dev/null || true)\\",\\"_ppid\\":$PPID"
        PATCHED="${INPUT%\\}},${TERM_INFO}}"
        if echo "$INPUT" | grep -q '"PermissionRequest"'; then
          echo "$PATCHED" | nc -U -w 120 "$SOCK" 2>/dev/null || true
        else
          echo "$PATCHED" | nc -U -w 2 "$SOCK" 2>/dev/null || true
        fi
        """

    // MARK: - OpenCode plugin paths

    private static let opencodePluginDir = NSHomeDirectory() + "/.config/opencode/plugins"
    private static let opencodePluginPath = NSHomeDirectory() + "/.config/opencode/plugins/codeisland.js"
    private static let opencodeConfigPath = NSHomeDirectory() + "/.config/opencode/config.json"
    private static let opencodeConfigPathNew = NSHomeDirectory() + "/.config/opencode/opencode.json"
    // OpenCode recommends opencode.jsonc (with-comments). When the user already
    // has it we should merge our plugin entry there instead of resurrecting
    // opencode.json. See issue #132.
    private static let opencodeConfigPathJsonc = NSHomeDirectory() + "/.config/opencode/opencode.jsonc"

    // MARK: - Install / Uninstall

    static func install() -> Bool {
        let fm = FileManager.default

        // Ensure ~/.codeisland directory
        try? fm.createDirectory(atPath: codeislandDir, withIntermediateDirectories: true)

        // Clean up legacy paths at ~/.claude/hooks/ (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        // A previous run may have created the Claude config dir after the resolution was
        // memoized, so re-resolve before installing into it.
        ClaudeConfigPaths.invalidateCache()

        // Install hook script + bridge binary (shared by all CLIs)
        installHookScript(fm: fm)
        installBridgeBinary(fm: fm)

        // Install hooks for each enabled CLI
        var ok = true
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            if cli.source == "claude" {
                if !installClaudeHooks(cli: cli, fm: fm) { ok = false }
            } else {
                if !installExternalHooks(cli: cli, fm: fm) { ok = false }
            }
        }

        // Codex's required feature flag is installed by installExternalHooks;
        // its failure contributes to `ok` above, rather than reporting success.
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            repairCodexMCPApprovalTables(fm: fm)
        }

        // Install OpenCode plugin
        if isEnabled(source: "opencode") {
            if !installOpencodePlugin(fm: fm) { ok = false }
        }

        return ok
    }

    static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: hookScriptPath)
        try? fm.removeItem(atPath: bridgePath)
        // Also clean up legacy paths (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        for cli in allCLIs {
            uninstallHooks(cli: cli, fm: fm)
        }

        uninstallOpencodePlugin(fm: fm)
    }

    /// Check if Claude Code hooks are installed
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookScriptPath) else { return false }
        return isHooksInstalled(for: allCLIs[0], fm: fm)
    }

    /// Check if a specific CLI's hooks are installed
    static func isInstalled(source: String) -> Bool {
        if source == "opencode" { return isOpencodePluginInstalled(fm: FileManager.default) }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return isHooksInstalled(for: cli, fm: FileManager.default)
    }

    /// Check if CLI directory exists (tool is installed on this machine)
    static func cliExists(source: String) -> Bool {
        if source == "opencode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/opencode") }
        if source == "google-antigravity" {
            // Detect via Antigravity-specific markers, NOT bare ~/.gemini (which the
            // plain Gemini CLI also creates). See installExternalHooks gating (#215).
            let fm = FileManager.default
            return fm.fileExists(atPath: NSHomeDirectory() + "/.gemini/config")
                || fm.fileExists(atPath: NSHomeDirectory() + "/.gemini/antigravity-cli")
        }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return FileManager.default.fileExists(atPath: cli.dirPath)
    }

    // Keep backward compat
    static func isCodexInstalled() -> Bool { isInstalled(source: "codex") }

    /// Whether a CLI is enabled by user (UserDefaults). Default: true.
    static func isEnabled(source: String) -> Bool {
        let key = "cli_enabled_\(source)"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Toggle a single CLI on/off: installs or uninstalls its hooks.
    @discardableResult
    static func setEnabled(source: String, enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: "cli_enabled_\(source)")
        let fm = FileManager.default
        if enabled {
            installHookScript(fm: fm)
            installBridgeBinary(fm: fm)
            if source == "opencode" {
                return installOpencodePlugin(fm: fm)
            }
            guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
            if cli.source == "claude" {
                return installClaudeHooks(cli: cli, fm: fm)
            } else {
                guard installExternalHooks(cli: cli, fm: fm) else { return false }
                return isHooksInstalled(for: cli, fm: fm)
            }
        } else {
            if source == "opencode" {
                uninstallOpencodePlugin(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                uninstallHooks(cli: cli, fm: fm)
            }
            return true
        }
    }

    /// Check all installed CLIs and repair missing hooks. Returns names of repaired CLIs.
    static func verifyAndRepair() -> [String] {
        let fm = FileManager.default
        // Ensure bridge binary and hook script are current
        installBridgeBinary(fm: fm)
        installHookScript(fm: fm)

        var repaired: [String] = []
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            guard fm.fileExists(atPath: cli.dirPath) else { continue }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            // #182: respect a user who deleted some hook events by hand — don't
            // re-add them unless nothing of ours remains or a stale entry needs
            // cleanup.
            if shouldPreservePartialHooks(for: cli, fm: fm) { continue }
            if cli.source == "claude" {
                if installClaudeHooks(cli: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            } else {
                guard installExternalHooks(cli: cli, fm: fm) else { continue }
                if isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            }
        }
        // Codex config.toml: ensure hooks = true
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            if !enableCodexHooksConfig(fm: fm) {
                repaired.removeAll { $0 == "Codex" }
            }
        }
        // OpenCode plugin
        if isEnabled(source: "opencode"),
           fm.fileExists(atPath: (opencodeConfigPath as NSString).deletingLastPathComponent),
           !isOpencodePluginInstalled(fm: fm) {
            if installOpencodePlugin(fm: fm) { repaired.append("OpenCode") }
        }
        return repaired
    }

    // MARK: - JSONC Support

    /// Strip // and /* */ comments from JSONC, preserving strings
    static func stripJSONComments(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex

        while i < end {
            let c = input[i]
            if c == "\"" {
                result.append(c)
                i = input.index(after: i)
                while i < end {
                    let sc = input[i]
                    result.append(sc)
                    if sc == "\\" {
                        i = input.index(after: i)
                        if i < end { result.append(input[i]) }
                    } else if sc == "\"" {
                        break
                    }
                    i = input.index(after: i)
                }
                if i < end { i = input.index(after: i) }
                continue
            }
            let next = input.index(after: i)
            if c == "/" && next < end {
                let nc = input[next]
                if nc == "/" {
                    i = input.index(after: next)
                    while i < end && input[i] != "\n" { i = input.index(after: i) }
                    continue
                } else if nc == "*" {
                    i = input.index(after: next)
                    while i < end {
                        let bi = input.index(after: i)
                        if input[i] == "*" && bi < end && input[bi] == "/" {
                            i = input.index(after: bi)
                            break
                        }
                        i = input.index(after: i)
                    }
                    continue
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }

    /// Parse a JSON file, stripping JSONC comments first
    private static func parseJSONFile(at path: String, fm: FileManager) -> [String: Any]? {
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let stripped = stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - CLI Version Detection

    /// How `compatibleEvents` learns the installed Claude Code's version.
    /// Detecting it starts the user's real `claude`, so a test process gets
    /// "unknown" — what a machine without Claude Code gets — unless a test
    /// installs a version of its own.
    static var claudeVersionProvider: () -> String? = {
        RuntimeEnvironment.isRunningTests ? nil : detectClaudeVersion()
    }

    /// Detect installed Claude Code version by running `claude --version`.
    /// Cache is guarded by a lock because `install()` and `verifyAndRepair()`
    /// can both call this from `Task.detached` since #139 (#103 review).
    private static var cachedClaudeVersion: String?
    private static let cachedClaudeVersionLock = NSLock()
    private static func detectClaudeVersion() -> String? {
        cachedClaudeVersionLock.lock()
        if let cached = cachedClaudeVersion {
            cachedClaudeVersionLock.unlock()
            return cached
        }
        cachedClaudeVersionLock.unlock()

        // Find claude binary — GUI apps don't inherit user's shell PATH
        guard let claudePath = claudeBinaryCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // 5s timeout: a stuck `claude --version` used to freeze app launch (#139).
        guard let data = ProcessRunner.run(path: claudePath, args: ["--version"], timeout: 5),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Parse "2.1.92 (Claude Code)" → "2.1.92"
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").first ?? ""
        guard !version.isEmpty else { return nil }
        cachedClaudeVersionLock.lock()
        cachedClaudeVersion = version
        cachedClaudeVersionLock.unlock()
        return version
    }

    /// Where `claude` lives, in the order a login shell would usually find it:
    /// the native installer, Homebrew on Apple Silicon (the cask, or npm with
    /// Homebrew's node), Intel Homebrew / a /usr/local npm prefix, and the old
    /// `claude migrate-installer` local install. Without a version, the
    /// version-gated events (PostToolUseFailure, StopFailure) are skipped.
    static func claudeBinaryCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.claude/local/claude",
        ]
    }

    /// Compare semver strings: returns true if `installed` >= `required`
    static func versionAtLeast(_ installed: String, _ required: String) -> Bool {
        let i = installed.split(separator: ".").compactMap { Int($0) }
        let r = required.split(separator: ".").compactMap { Int($0) }
        for idx in 0..<max(i.count, r.count) {
            let iv = idx < i.count ? i[idx] : 0
            let rv = idx < r.count ? r[idx] : 0
            if iv > rv { return true }
            if iv < rv { return false }
        }
        return true // equal
    }

    /// Filter events based on installed CLI version
    private static func compatibleEvents(for cli: CLIConfig) -> [(String, Int, Bool)] {
        guard !cli.versionedEvents.isEmpty else { return cli.events }

        // Only Claude Code needs version checking for now
        guard cli.source == "claude" else { return cli.events }
        let version = claudeVersionProvider()

        return cli.events.filter { (event, _, _) in
            guard let minVer = cli.versionedEvents[event] else { return true }
            guard let version else { return false } // can't detect version → skip risky events
            return versionAtLeast(version, minVer)
        }
    }

    // MARK: - Claude Code (special: uses hook script)

    private static func installClaudeHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        let dir = cli.dirPath
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Read raw text (preserved verbatim for minimal-diff write-back).
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 — protect user data).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let settings = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = settings[cli.configKey] as? [String: Any] ?? [:]
        let events = compatibleEvents(for: cli)

        let alreadyInstalled = events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String) == hookCommand }
            }
        }
        if alreadyInstalled && !hasStaleAsyncKey(hooks) { return true }

        // Remove all managed hooks first, including legacy Vibe Island entries.
        hooks = removeManagedHookEntries(from: hooks)

        // Re-install only compatible events
        for (event, timeout, _) in events {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            let hookEntry: [String: Any] = [
                "type": "command", "command": hookCommand, "timeout": timeout,
            ]
            eventHooks.append(["matcher": "", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }

        return writeJSONWithKey(
            cli: cli,
            originalText: originalText,
            key: cli.configKey,
            value: hooks,
            fm: fm
        )
    }

    /// Minimal-diff write of a single top-level key, preserving user comments / key order / escaping.
    /// Creates the file fresh if `originalText` is nil. Returns false on any failure (caller-side #89 guard).
    /// A symlinked config file (dotfiles, a settings.json shared between
    /// accounts) is written at its target, so the link survives.
    private static func writeJSONWithKey(
        cli: CLIConfig,
        originalText: String?,
        key: String,
        value: Any,
        fm: FileManager
    ) -> Bool {
        let source: String = {
            if let t = originalText, !t.isEmpty { return t }
            return "{}\n"
        }()
        guard let merged = JSONMinimalEditor.setTopLevelValue(in: source, key: key, value: value) else {
            return false
        }
        return ConfigPathIdentity.write(Data(merged.utf8), to: cli.fullPath, fileManager: fm)
    }

    // MARK: - External CLIs (use bridge binary directly)

    @discardableResult
    static func installExternalHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .antigravityNamed {
            // Google Antigravity shares the ~/.gemini root with the plain Gemini
            // CLI, so we must NOT install just because ~/.gemini exists — that
            // would write a stray hooks.json into a Gemini-only user's home.
            // Gate on an Antigravity-specific marker: the shared ~/.gemini/config
            // dir (where agy-cli writes per CHANGELOG v1.0.8) or the legacy
            // ~/.gemini/antigravity-cli dir.
            let geminiRoot = NSHomeDirectory() + "/.gemini"
            let configDir = cli.dirPath                       // ~/.gemini/config
            let antigravityDir = geminiRoot + "/antigravity-cli"
            let hasAntigravityPresence =
                fm.fileExists(atPath: configDir) || fm.fileExists(atPath: antigravityDir)
            guard hasAntigravityPresence else { return true }
            if !fm.fileExists(atPath: configDir) {
                try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            }
        } else {
            guard fm.fileExists(atPath: cli.dirPath) else { return true } // CLI not installed, skip OK
        }

        // Read raw text for minimal-diff write-back.
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 safety guard).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let root = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = root[cli.configKey] as? [String: Any] ?? [:]
        // Quote the path in case home directory contains spaces or special characters
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let bridgeSource = cli.bridgeSourceOverride ?? cli.source
        let baseCommand = "\(quotedBridge) --source \(bridgeSource)"

        for (event, timeout, _) in cli.events {
            var eventEntries = hooks[event] as? [[String: Any]] ?? []
            // Remove old hooks before adding fresh ones (ensures reinstall works)
            eventEntries.removeAll { containsOurHook($0) }

            let entry: [String: Any]
            switch cli.format {
            case .claude:
                // Long-running PermissionRequest hooks need a timeout per entry,
                // or they hang the agent (#103).
                entry = ["matcher": "*", "hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .nested:
                entry = ["hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .antigravityNamed:
                // Antigravity named-config entry. The outer wrapper name is the
                // configKey ("codeisland"), keyed here by installExternalHooks, so we
                // emit only the inner {matcher?, hooks:[{type,command,timeout}]} value.
                // stdin lacks hook_event_name -> the command must carry --event.
                //
                // The two event families take DIFFERENT shapes, and getting this
                // wrong is silent — Antigravity just never runs the handler:
                //   tool events  (PreToolUse/PostToolUse) → [{matcher, hooks:[…]}]
                //   model events (PreInvocation/PostInvocation/Stop) → [{type, command}]
                // We previously wrapped Stop in a `hooks` array too, so Stop never
                // fired and every Antigravity session sat on "thinking" forever (#297).
                let agyCommand = "\(baseCommand) --event \(event)"
                let handler: [String: Any] = ["type": "command", "command": agyCommand, "timeout": timeout]
                if event == "PreToolUse" || event == "PostToolUse" {
                    entry = ["matcher": "*", "hooks": [handler]]
                } else {
                    entry = handler
                }
            }
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        let seeded = originalText

        guard writeJSONWithKey(
            cli: cli,
            originalText: seeded,
            key: cli.configKey,
            value: hooks,
            fm: fm
        ) else { return false }
        // A hooks.json without the activation flag is not an installed Codex
        // integration; install/toggle/repair must propagate its failure.
        return cli.source != "codex" || enableCodexHooksConfig(fm: fm, codexHome: cli.dirPath)
    }

    // MARK: - Codex config.toml

    /// Clears out the transport-less `[mcp_servers.*.tools.*]` tables an older
    /// CodeIsland could write, which make Codex reject the whole config.toml
    /// (#316). Runs at launch because the user has no reason to connect their
    /// broken Codex to an "Always Allow" they clicked days earlier — and the
    /// symptom (unrelated settings refusing to save) never points here.
    @discardableResult
    static func repairCodexMCPApprovalTables(fm: FileManager) -> Bool {
        let configPath = codexHome() + "/config.toml"
        guard fm.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8),
              let repaired = CodexPermissionRules.repairingOrphanedMCPToolTables(contents) else {
            return false
        }
        return ConfigPathIdentity.write(Data(repaired.utf8), to: configPath, fileManager: fm)
    }

    /// Ensure the Codex hooks feature flag is true in $CODEX_HOME/config.toml
    /// (or ~/.codex/config.toml when unset) so Codex actually fires hook events.
    /// The source editor recognizes quoted/bare keys and table scope without
    /// touching comments, unrelated flags or strings containing TOML examples.
    /// An unsupported/conflicting layout is left untouched and returns false.
    /// `codexHome` is overridden for extra Codex roots registered in Settings —
    /// each root has its own config.toml, and a hooks.json without the flag
    /// next to it is never read. A symlinked config.toml is edited at its
    /// target and stays a symlink.
    @discardableResult
    static func enableCodexHooksConfig(fm: FileManager, codexHome: String = ConfigInstaller.codexHome()) -> Bool {
        let configPath = codexHome + "/config.toml"
        try? fm.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let contents: String
        if fm.fileExists(atPath: configPath) {
            guard let existing = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
            contents = existing
        } else {
            contents = ""
        }
        guard let result = CodexHooksConfig.enablingHooks(in: contents) else { return false }
        if result == contents { return true }
        return ConfigPathIdentity.write(Data(result.utf8), to: configPath, fileManager: fm)
    }

    // MARK: - Uninstall (generic)

    internal static func uninstallHooks(cli: CLIConfig, fm: FileManager) {
        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              var hooks = root[cli.configKey] as? [String: Any],
              let originalText = fm.contents(atPath: cli.fullPath).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        hooks = removeManagedHookEntries(from: hooks)

        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: cli.configKey)
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: cli.configKey, value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            // Through a symlinked config file, not over it.
            ConfigPathIdentity.write(data, to: cli.fullPath, fileManager: fm)
        }
    }

    // MARK: - Detection helpers

    static func removeManagedHookEntries(from hooks: [String: Any]) -> [String: Any] {
        var cleaned = hooks
        for (event, value) in cleaned {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { containsOurHook($0) }
            if entries.isEmpty {
                cleaned.removeValue(forKey: event)
            } else {
                cleaned[event] = entries
            }
        }
        return cleaned
    }

    static func isHooksInstalled(for cli: CLIConfig, fm: FileManager) -> Bool {
        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              let hooks = root[cli.configKey] as? [String: Any] else { return false }
        // Check that ALL required events have our hook installed, not just any one
        let allPresent = cli.events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
        guard allPresent else { return false }
        // Also check for stale "async" keys that need cleanup
        if hasStaleAsyncKey(hooks) { return false }
        // Pre-#297 installs wrapped Antigravity's model events in a `hooks` array,
        // a shape Antigravity silently ignores. Report those as not-installed so
        // verifyAndRepair rewrites them into the flat handler form.
        if cli.format == .antigravityNamed, hasNestedAntigravityModelEvent(hooks) { return false }
        return true
    }

    /// Antigravity's `PreInvocation` / `PostInvocation` / `Stop` handlers are a
    /// direct `[{type, command}]` list; only `PreToolUse` / `PostToolUse` take the
    /// `[{matcher, hooks: […]}]` wrapper. A CodeIsland entry for a model event
    /// carrying a `hooks` array is the broken legacy shape. (#297)
    static func hasNestedAntigravityModelEvent(_ hooks: [String: Any]) -> Bool {
        let modelEvents = ["Stop", "PreInvocation", "PostInvocation"]
        for event in modelEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            if entries.contains(where: { containsOurHook($0) && $0["hooks"] != nil }) {
                return true
            }
        }
        return false
    }

    /// #182: tell apart a user who intentionally kept only some hook events
    /// from a config that was never installed, fully wiped, or corrupted.
    /// Returns true when at least one of our hook entries is present and
    /// nothing stale needs rewriting — meaning verifyAndRepair should leave the
    /// (incomplete) config untouched instead of re-adding the removed events.
    static func shouldPreservePartialHooks(hooks: [String: Any], events: [(String, Int, Bool)]) -> Bool {
        if hasStaleAsyncKey(hooks) { return false }
        return events.contains { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
    }

    private static func shouldPreservePartialHooks(for cli: CLIConfig, fm: FileManager) -> Bool {
        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              let hooks = root[cli.configKey] as? [String: Any] else { return false }
        // A legacy-shaped Antigravity model event is broken, not "intentionally
        // pruned by the user" — it must be rewritten, not preserved. (#297)
        if cli.format == .antigravityNamed, hasNestedAntigravityModelEvent(hooks) { return false }
        return shouldPreservePartialHooks(hooks: hooks, events: cli.events)
    }

    /// Detect legacy hook entries with invalid "async" key
    private static func hasStaleAsyncKey(_ hooks: [String: Any]) -> Bool {
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries where containsOurHook(entry) {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    if hookList.contains(where: { $0["async"] != nil }) { return true }
                }
            }
        }
        return false
    }

    /// Check if a hook entry contains our hook command
    private static func containsOurHook(_ entry: [String: Any]) -> Bool {
        // Claude/nested format: entry.hooks[].command
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains {
                let cmd = $0["command"] as? String ?? ""
                return HookId.isOurs(cmd)
            }
        }
        // Antigravity model events: entry.command
        if let cmd = entry["command"] as? String, HookId.isOurs(cmd) { return true }
        return false
    }

    // MARK: - Bridge & Hook Script

    private static func installHookScript(fm: FileManager) {
        let needsUpdate: Bool
        if fm.fileExists(atPath: hookScriptPath) {
            if let existing = fm.contents(atPath: hookScriptPath),
               let str = String(data: existing, encoding: .utf8) {
                // Update if script doesn't contain bridge dispatcher OR version is outdated
                let hasCurrentVersion = str.contains("# CodeIsland hook v\(hookScriptVersion)")
                needsUpdate = !hasCurrentVersion
            } else {
                needsUpdate = true
            }
        } else {
            needsUpdate = true
        }
        if needsUpdate {
            fm.createFile(atPath: hookScriptPath, contents: Data(hookScript.utf8))
            chmod(hookScriptPath, 0o755)
        }
    }

    private static func installBridgeBinary(fm: FileManager) {
        guard let execPath = Bundle.main.executablePath else { return }
        let execDir = (execPath as NSString).deletingLastPathComponent
        let contentsDir = (execDir as NSString).deletingLastPathComponent
        var srcPath = contentsDir + "/Helpers/codeisland-bridge"
        if !fm.fileExists(atPath: srcPath) { srcPath = execDir + "/codeisland-bridge" }
        guard fm.fileExists(atPath: srcPath) else { return }

        // Atomic replace: copy to temp file first, then rename (overwrites atomically)
        let tmpPath = bridgePath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try? fm.removeItem(atPath: tmpPath)
            try fm.copyItem(atPath: srcPath, toPath: tmpPath)
            chmod(tmpPath, 0o755)
            // Strip quarantine xattr so Gatekeeper won't block the binary
            stripQuarantine(tmpPath)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: bridgePath), withItemAt: URL(fileURLWithPath: tmpPath))
        } catch {
            // replaceItemAt fails if destination doesn't exist yet — fall back to rename
            try? fm.moveItem(atPath: tmpPath, toPath: bridgePath)
            chmod(bridgePath, 0o755)
        }
        // Ensure final binary is free of quarantine (covers both paths above)
        stripQuarantine(bridgePath)
    }

    /// Remove com.apple.quarantine xattr so Gatekeeper won't block the binary.
    /// Copied binaries inherit quarantine from the source app bundle.
    private static func stripQuarantine(_ path: String) {
        removexattr(path, "com.apple.quarantine", 0)
    }

    // MARK: - OpenCode Plugin

    /// The JS plugin source — embedded as resource or bundled alongside
    private static func opencodePluginSource() -> String? {
        // Try SPM resource bundle (where build actually places it)
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        // Fallback: try without subdirectory
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    /// Merge our plugin reference into an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the original contents
    /// are present but unparseable / not a JSON object — in that case the caller
    /// MUST NOT overwrite the file (see issue #89). Uses minimal-diff editing so
    /// user comments, key order, and whitespace are preserved (#105/#106).
    static func mergeOpencodePluginRef(
        originalContents: String?,
        pluginRef: String,
        identifier: String
    ) -> String? {
        // Brand-new file — emit a minimal canonical document.
        guard let contents = originalContents, !contents.isEmpty else {
            let config: [String: Any] = [
                "$schema": "https://opencode.ai/config.json",
                "plugin": [pluginRef],
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            ), var merged = String(data: data, encoding: .utf8) else { return nil }
            if !merged.hasSuffix("\n") { merged += "\n" }
            return merged
        }

        // Verify parseable and dedup plugin entries against the parsed view.
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var plugins = parsed["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("vibe-island") || $0.contains(identifier) }
        plugins.append(pluginRef)

        // Replace the plugin array in-place, preserving surrounding text exactly.
        guard var merged = JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins) else {
            return nil
        }
        // Add $schema if missing — minimal-diff insertion at end of object.
        if parsed["$schema"] == nil {
            guard let withSchema = JSONMinimalEditor.setTopLevelValue(
                in: merged, key: "$schema", value: "https://opencode.ai/config.json"
            ) else { return merged }
            merged = withSchema
        }
        return merged
    }

    /// Remove our plugin reference from an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the file is absent,
    /// unparseable, or does not currently reference us (nothing to do).
    static func removeOpencodePluginRef(
        originalContents: String?,
        identifier: String
    ) -> String? {
        guard let contents = originalContents else { return nil }
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard var plugins = parsed["plugin"] as? [String],
              plugins.contains(where: { $0.contains(identifier) }) else {
            return nil
        }
        plugins.removeAll { $0.contains(identifier) }
        if plugins.isEmpty {
            return JSONMinimalEditor.deleteTopLevelKey(in: contents, key: "plugin")
        }
        return JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins)
    }

    @discardableResult
    private static func installOpencodePlugin(fm: FileManager) -> Bool {
        // Only install if opencode config dir exists
        let configDir = (opencodeConfigPath as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: configDir) else { return true } // not installed, skip silently

        // Clean up old vibe-island plugin
        let oldPlugin = opencodePluginDir + "/vibe-island.js"
        if fm.fileExists(atPath: oldPlugin) { try? fm.removeItem(atPath: oldPlugin) }

        // Write plugin JS
        guard let source = opencodePluginSource() else { return false }
        try? fm.createDirectory(atPath: opencodePluginDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: opencodePluginPath, contents: Data(source.utf8)) else { return false }

        // Pick the registration target. Order: .jsonc (OpenCode-recommended)
        // when present, else .json. We never create .json when the user
        // already has .jsonc — see issue #132.
        let pluginRef = "file://\(opencodePluginPath)"
        let targetPath: String = fm.fileExists(atPath: opencodeConfigPathJsonc)
            ? opencodeConfigPathJsonc
            : opencodeConfigPathNew
        let originalContents: String? = fm.contents(atPath: targetPath)
            .flatMap { String(data: $0, encoding: .utf8) }

        guard let merged = mergeOpencodePluginRef(
            originalContents: originalContents,
            pluginRef: pluginRef,
            identifier: HookId.current
        ) else {
            // Existing config is unparseable — refuse to overwrite user data.
            // Plugin JS is staged; the config file stays untouched until the user fixes it.
            return false
        }

        if let original = originalContents, !original.isEmpty {
            backupOpencodeConfig(at: targetPath, original: original, fm: fm)
        }
        fm.createFile(atPath: targetPath, contents: Data(merged.utf8))

        // Clean up legacy config.json registration to prevent double-load.
        if let legacyContents = fm.contents(atPath: opencodeConfigPath)
            .flatMap({ String(data: $0, encoding: .utf8) }),
           let cleaned = removeOpencodePluginRef(originalContents: legacyContents, identifier: HookId.current) {
            backupOpencodeConfig(at: opencodeConfigPath, original: legacyContents, fm: fm)
            fm.createFile(atPath: opencodeConfigPath, contents: Data(cleaned.utf8))
        }
        return true
    }

    private static func uninstallOpencodePlugin(fm: FileManager) {
        try? fm.removeItem(atPath: opencodePluginPath)
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
            guard let contents = fm.contents(atPath: configPath)
                .flatMap({ String(data: $0, encoding: .utf8) }),
                  let cleaned = removeOpencodePluginRef(originalContents: contents, identifier: HookId.current)
            else { continue }
            backupOpencodeConfig(at: configPath, original: contents, fm: fm)
            fm.createFile(atPath: configPath, contents: Data(cleaned.utf8))
        }
    }

    /// Write a timestamped backup next to the original config file the first
    /// time we mutate it. Subsequent writes skip backup if one already exists
    /// for the same path to avoid spamming the directory.
    private static func backupOpencodeConfig(at path: String, original: String, fm: FileManager) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // Skip if any previous codeisland backup exists for this file.
        if let entries = try? fm.contentsOfDirectory(atPath: dir),
           entries.contains(where: { $0.hasPrefix(name + ".codeisland.bak.") }) {
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupPath = "\(path).codeisland.bak.\(stamp)"
        fm.createFile(atPath: backupPath, contents: Data(original.utf8))
    }

    /// Current OpenCode plugin version — bump when codeisland-opencode.js changes
    /// (the MiMo Code copy is the same file, so it follows this too).
    private static let opencodePluginVersion = "v10"

    private static func isOpencodePluginInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: opencodePluginPath) else { return false }
        // If any config file exists but is unparseable, treat plugin as installed
        // to avoid a repair loop that would clobber the user's JSON (#89).
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
            guard fm.fileExists(atPath: configPath) else { continue }
            guard let data = fm.contents(atPath: configPath),
                  let stripped = String(data: data, encoding: .utf8).map(stripJSONComments),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
                return true
            }
            if let plugins = parsed["plugin"] as? [String],
               plugins.contains(where: { $0.contains(HookId.current) }) {
                // Check version; outdated plugin triggers re-install.
                if let existing = fm.contents(atPath: opencodePluginPath),
                   let str = String(data: existing, encoding: .utf8) {
                    return str.contains("// version: \(opencodePluginVersion)")
                }
                return false
            }
        }
        return false
    }

}
