import AppKit
import SwiftUI
import os.log
import CodeIslandCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let log = Logger(subsystem: "com.codeisland", category: "AppDelegate")

    var panelController: PanelWindowController?
    private var hookServer: HookServer?
    private var hookRecoveryTimer: Timer?
    private var lastHookCheck: Date = .distantPast
    private let hotKeyManager = GlobalHotKeyManager()
    private var localShortcutMonitor: Any?
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else: the launch Apple Event that says "login
        // item" is only current during this synchronous call.
        let isLoginLaunch = LaunchContext.isCurrentLaunchAtLogin()
        ProcessInfo.processInfo.disableAutomaticTermination("CodeIsland must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Pre-set app icon so Dock/menu bar use the packaged bundle icon.
        NSApp.applicationIconImage = Self.bundleAppIcon()
        StatusItemController.shared.startObserving()
        // Start HookServer BEFORE installing hooks into CLI configs.
        // If we write settings.json first, Claude Code picks up the new hooks
        // immediately but the socket isn't listening yet — PermissionRequest
        // hooks get no response and Claude Code denies them.
        hookServer = HookServer(appState: appState)
        hookServer?.start()

        // Hook installation does subprocess version detection plus disk I/O —
        // keep it off the main thread so app launch isn't blocked even when a
        // CLI binary hangs. See #139.
        Task.detached(priority: .userInitiated) {
            if ConfigInstaller.install() {
                Self.log.info("Hooks installed")
            } else {
                Self.log.warning("Failed to install hooks")
            }
        }

        // Watch system sleep/wake so the mascot animations pause and re-anchor
        // their periodic schedules instead of pinning a core after wake (#225).
        MascotAnimationGate.shared.start()
        // Lock / screen saver / display sleep → event sounds hold off.
        SceneMuteMonitor.shared.start()

        panelController = PanelWindowController(appState: appState)
        panelController?.showPanel()

        appState.startSessionDiscovery()
        appState.startCodexAppServerWatcher()

        // Hooks auto-recovery: periodic + app activation trigger
        hookRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRepairHooks()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRepairHooks()
            }
        }

        #if DEBUG
        // Preview mode: inject mock data if --preview flag is present
        if let scenario = DebugHarness.requestedScenario() {
            Self.log.debug("Loading scenario: \(scenario.rawValue)")
            DebugHarness.apply(scenario, to: appState)
            // --collapsed keeps the bar collapsed, for checking the compact layout.
            if DebugHarness.keepsCollapsed { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if appState.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        appState.surface = .sessionList
                    }
                }
            }
            return
        }
        #endif

        // The jingle confirms a launch the user just made; at login it is
        // noise on every boot for everyone with Launch at Login on.
        if isLoginLaunch {
            Self.log.info("Launched at login — skipping boot sound")
        } else {
            SoundManager.shared.playBoot()
        }
        setupGlobalShortcut()
        SettingsManager.shared.reconcileLaunchAtLogin()
        closePlaceholderSettingsWindows()
        if ProcessInfo.processInfo.arguments.contains("--settings") {
            showSettings()
        }

        // Boot animation: brief expand to confirm app is running
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard appState.surface == .collapsed else { return }
            withAnimation(NotchAnimation.pop) {
                appState.surface = .sessionList
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .sessionList = appState.surface {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookRecoveryTimer?.invalidate()
        teardownGlobalShortcut()
        appState.saveSessions()
        hookServer?.stop()
        appState.stopCodexAppServerWatcher()
        appState.stopSessionDiscovery()
    }

    // MARK: - Global Shortcuts

    func setupGlobalShortcut() {
        teardownGlobalShortcut()

        // Collect all enabled shortcut bindings, skip duplicates (first wins)
        var bindings: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, action: ShortcutAction)] = []
        var seen: Set<String> = []
        for action in ShortcutAction.allCases {
            guard action.isEnabled else { continue }
            let b = action.binding
            let key = "\(b.keyCode)-\(b.modifiers.rawValue)"
            guard seen.insert(key).inserted else { continue }
            bindings.append((b.keyCode, b.modifiers, action))
        }
        guard !bindings.isEmpty else { return }

        // Global path: Carbon RegisterEventHotKey fires from any frontmost app
        // and — unlike an NSEvent global keyboard monitor — needs no
        // Accessibility permission. This is the primary handler. See #217.
        for b in bindings {
            hotKeyManager.register(keyCode: b.keyCode, modifiers: b.mods) { [weak self] in
                Task { @MainActor in self?.executeShortcut(b.action) }
            }
        }

        // Local monitor: same-app fallback so the shortcut still works (and is
        // swallowed) while CodeIsland's own panel/settings window is focused.
        let localHandler: (NSEvent) -> Bool = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for b in bindings where event.keyCode == b.keyCode && eventMods == b.mods {
                Task { @MainActor in self?.executeShortcut(b.action) }
                return true
            }
            return false
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            localHandler(event) ? nil : event
        }
    }

    private func teardownGlobalShortcut() {
        hotKeyManager.unregisterAll()
        if let m = localShortcutMonitor { NSEvent.removeMonitor(m) }
        localShortcutMonitor = nil
    }

    /// Burrow's settings are the den's back (design/v21): open the den on it.
    func showSettings() {
        withAnimation(NotchAnimation.open) { appState.showSettings() }
    }

    /// Close the empty SwiftUI `Settings` scene window (CodeIslandApp's
    /// placeholder). macOS restores it on relaunch, and under Stage Manager it
    /// would sit on screen as a blank pane.
    private func closePlaceholderSettingsWindows() {
        for w in NSApp.windows {
            let id = w.identifier?.rawValue ?? ""
            if id.contains("Settings") || w.title == "CodeIsland Settings" {
                w.isRestorable = false
                w.close()
            }
        }
    }

    private static func bundleAppIcon() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 256, height: 256)
        return image
    }

    private func executeShortcut(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            if appState.surface.isExpanded {
                withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
            } else {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .sessionList
                    appState.cancelCompletionQueue()
                    if appState.activeSessionId == nil {
                        appState.activeSessionId = appState.sessions.keys.sorted().first
                    }
                }
            }
        // Card shortcuts act only on the card on screen (#308); with the
        // request hidden they open its card instead of acting unseen.
        case .approve, .approveAlways, .deny, .skipQuestion:
            appState.performCardShortcut(action)
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

    private func checkAndRepairHooks() {
        guard Date().timeIntervalSince(lastHookCheck) > 60 else { return }
        lastHookCheck = Date()
        // verifyAndRepair walks every enabled CLI and rewrites settings on
        // disk — keep it off the main thread so the activation observer (fires
        // on every app switch) can't stutter the UI. See #139.
        Task.detached(priority: .background) {
            let repaired = ConfigInstaller.verifyAndRepair()
            if !repaired.isEmpty {
                Self.log.info("Auto-repaired hooks for: \(repaired.joined(separator: ", "))")
            }
        }
    }

}
