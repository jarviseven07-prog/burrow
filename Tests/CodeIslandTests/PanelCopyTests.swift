import XCTest
@testable import CodeIsland

/// Names and tooltips that explain the panel's terse controls.
final class PanelCopyTests: XCTestCase {
    private let hintKeys = [
        "dismiss_card_hint", "skip_question_hint", "always_hint_session", "always_hint_saved",
    ]

    func testEveryLanguageSpellsOutThePanelControls() {
        // zh is not merged over English, so a missing key there would
        // surface as the raw key in a tooltip.
        for (lang, table) in L10n.strings {
            for key in hintKeys {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang) has no \(key)")
            }
        }
    }

    @MainActor
    func testAlwaysSaysWhetherTheRuleOutlivesTheSession() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        L10n.shared.language = "en"
        XCTAssertTrue(ApprovalHints.always(savesRule: true).contains("~/.codex/rules"))
        XCTAssertTrue(ApprovalHints.always(savesRule: false).contains("session"))
    }
}
