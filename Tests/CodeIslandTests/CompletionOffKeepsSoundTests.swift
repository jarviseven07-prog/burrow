import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Burrow ships with the completion card off. The completion sound is a
/// separate effect of the same Stop event and must keep playing.
@MainActor
final class CompletionOffKeepsSoundTests: XCTestCase {
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundTaskComplete,
        SettingsKey.quietHoursEnabled,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    private func hook(_ eventName: String, _ sessionId: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": eventName,
            "session_id": sessionId,
            "cwd": "/tmp/fermata-off-sound",
            "_source": "claude",
            "_ppid": Int(getpid()),
        ])))
    }

    func testStopPlaysTheCompletionSoundButOpensNoCardWhenStyleIsOff() throws {
        UserDefaults.standard.set("off", forKey: SettingsKey.completionNotificationStyle)
        let appState = AppState()
        appState.handleEvent(try hook("SessionStart", "fermata-off-1"))
        played = []

        appState.handleEvent(try hook("Stop", "fermata-off-1"))

        XCTAssertEqual(played, ["burrow_complete"], "the sound is independent of the card")
        XCTAssertEqual(appState.surface, .collapsed, "no completion card pops down")
        XCTAssertNil(appState.justCompletedSessionId)
    }
}
