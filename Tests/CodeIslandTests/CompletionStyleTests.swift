import XCTest
@testable import CodeIsland

/// Three-way completion notification style (off by default) and
/// its one-time migration of old installs away from the "expand" default.
final class CompletionStyleTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CompletionStyleTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultIsOff() {
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .off)
    }

    func testLegacyDisabledBoolMigratesToOff() {
        defaults.set(false, forKey: SettingsKey.autoExpandOnCompletion)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .off)
    }

    func testLegacyEnabledBoolFallsBackToOff() {
        defaults.set(true, forKey: SettingsKey.autoExpandOnCompletion)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .off)
    }

    func testExplicitExpandStillWorks() {
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .expand)
    }

    func testNewKeyWinsOverLegacyBool() {
        defaults.set(false, forKey: SettingsKey.autoExpandOnCompletion)
        defaults.set("glance", forKey: SettingsKey.completionNotificationStyle)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .glance)
    }

    func testUnknownRawValueFallsBackToOff() {
        defaults.set("bogus", forKey: SettingsKey.completionNotificationStyle)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .off)
    }

    // MARK: - One-time completion-off migration

    func testMigrationMovesStoredExpandToOffOnce() {
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        SettingsManager.migrateCompletionCardOffOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.completionNotificationStyle), "off")
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.fermataMigratedCompletionOffKey))
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .off)

        // Runs once: a later, deliberate choice survives the next launch.
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        SettingsManager.migrateCompletionCardOffOnce(defaults: defaults)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .expand)
    }

    func testMigrationWritesOffWhenNothingStored() {
        SettingsManager.migrateCompletionCardOffOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.completionNotificationStyle), "off")
    }

    func testMigrationKeepsAnExplicitGlance() {
        defaults.set("glance", forKey: SettingsKey.completionNotificationStyle)
        SettingsManager.migrateCompletionCardOffOnce(defaults: defaults)
        XCTAssertEqual(AppState.completionStyle(defaults: defaults), .glance)
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.fermataMigratedCompletionOffKey))
    }
}
