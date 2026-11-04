import XCTest
@testable import CodeIsland

/// The den's back, Burrow's settings: health check 2026-11-04 #23 and #24.
/// Neither the login item nor Carbon hot keys can be driven from a test
/// without touching the Mac's own state, so these read the source.
final class DenBackSettingsTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeIsland/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// #23: the switch called `SMAppService.register()` on the main thread
    /// and stayed on after a failure until the back was shown again.
    func testTheLoginSwitchRegistersOffTheMainThreadAndShowsTheOutcome() throws {
        let back = try source("BurrowDenBack.swift")
        XCTAssertFalse(back.contains("SettingsManager.shared.launchAtLogin ="), "no blocking set from the switch")
        XCTAssertTrue(back.contains("let change = SettingsManager.applyLaunchAtLogin(on)"))
        let settings = try source("Settings.swift")
        XCTAssertTrue(settings.contains("static func applyLaunchAtLogin(_ wanted: Bool) -> Task<Bool, Never>"))
        XCTAssertTrue(settings.contains("loginQueue.async"), "off the main thread")
    }

    /// Review of #23: flicked on and off fast, the two changes could run
    /// the wrong way round and leave the login item on with the switch off.
    /// What is wanted is written down on the main thread as the switch is
    /// flicked, before any task; each change, one at a time on a serial
    /// queue, applies what is wanted when it runs; only the latest flick's
    /// outcome is shown.
    func testOnlyTheLatestFlickSetsTheLoginSwitch() throws {
        let back = try source("BurrowDenBack.swift")
        let flick = try XCTUnwrap(back.range(of: "loginRequest += 1"))
        let started = try XCTUnwrap(back.range(of: "SettingsManager.applyLaunchAtLogin(on)"))
        let task = try XCTUnwrap(back.range(of: "Task {", range: flick.upperBound..<back.endIndex))
        XCTAssertLessThan(started.lowerBound, task.lowerBound, "started outside the task")
        XCTAssertTrue(back.contains("if request == loginRequest { launchAtLogin = enabled }"))
        XCTAssertFalse(back.contains("Task.detached { SMAppService"), "the first read waits behind changes")

        let settings = try source("Settings.swift")
        let apply = try XCTUnwrap(settings.range(of: "static func applyLaunchAtLogin(_ wanted: Bool)"))
        let body = settings[apply.upperBound...].prefix(400)
        let written = try XCTUnwrap(body.range(of: "UserDefaults.standard.set(wanted"))
        let queued = try XCTUnwrap(body.range(of: "onLoginQueue"))
        XCTAssertLessThan(written.lowerBound, queued.lowerBound, "written down before the change is queued")
        XCTAssertTrue(settings.contains("let wanted = UserDefaults.standard.bool(forKey: launchAtLoginWantedKey)"),
                      "each change applies what is wanted when it runs")
        XCTAssertTrue(settings.contains("DispatchQueue(label: \"burrow.login-item\""), "a serial queue")
    }
}

extension DenBackSettingsTests {
    /// #24: recording a combination Burrow already uses fired it instead —
    /// the global hot key is taken before the recorder's key monitor.
    func testShortcutsAreOffWhileOneIsRecorded() throws {
        let back = try source("BurrowDenBack.swift")
        let start = try XCTUnwrap(back.range(of: "private func startRecording"))
        let stop = try XCTUnwrap(back.range(of: "private func stopRecording"))
        let recording = back[start.lowerBound..<stop.lowerBound]
        XCTAssertTrue(recording.contains("suspendGlobalShortcuts()"), "off before the key monitor")
        XCTAssertFalse(recording.contains("setupGlobalShortcut()"), "back on only through stopRecording")
        let stopping = back[stop.lowerBound...].prefix(600)
        XCTAssertTrue(stopping.contains("setupGlobalShortcut()"), "every way out puts them back")
        XCTAssertTrue(try source("AppDelegate.swift").contains("func suspendGlobalShortcuts()"))
    }

    /// Under `@NSApplicationDelegateAdaptor`, `NSApp.delegate` is SwiftUI's
    /// wrapper: the cast to AppDelegate is nil, so the back's calls to it —
    /// putting a recorded shortcut in place among them — never arrived.
    func testTheBackReachesTheAppDelegateItself() throws {
        let back = try source("BurrowDenBack.swift")
        XCTAssertFalse(back.contains("NSApp.delegate as? AppDelegate"))
        XCTAssertTrue(back.contains("AppDelegate.shared?.setupGlobalShortcut()"))
        XCTAssertTrue(try source("AppDelegate.swift").contains("Self.shared = self"))
    }

    /// #22: the menu bar's "Settings…" went through the same cast.
    func testTheMenuBarItemReachesTheAppDelegate() throws {
        let item = try source("StatusItemController.swift")
        XCTAssertFalse(item.contains("NSApp.delegate as? AppDelegate"))
        XCTAssertTrue(item.contains("AppDelegate.shared?.showSettings()"))
    }
}
