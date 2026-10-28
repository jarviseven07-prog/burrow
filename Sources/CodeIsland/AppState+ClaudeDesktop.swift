import AppKit
import CodeIslandCore

/// Claude Desktop hosts Claude Code sessions run from its Code tab.
extension AppState {
    nonisolated static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    /// Bring Claude Desktop forward and, given a deep link, navigate it there.
    nonisolated static func openInClaudeDesktop(_ deepLink: URL?) {
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleId).first,
           app.isHidden {
            app.unhide()
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: claudeDesktopBundleId) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Reopen first, like a Dock click: it brings back a closed or hidden
        // main window (and switches Space). The link event queues behind it and
        // then navigates that window to the conversation.
        workspace.openApplication(at: appURL, configuration: configuration)
        if let deepLink {
            workspace.open([deepLink], withApplicationAt: appURL, configuration: configuration)
        }
    }
}
