import SwiftUI

@main
struct CodeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        // The SwiftUI Settings scene above is a placeholder; the app menu's
        // "Settings…" (⌘,) turns the den over to its back, Burrow's settings
        // (design/v21), instead of opening that empty window.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.shared["settings_title"]) {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
