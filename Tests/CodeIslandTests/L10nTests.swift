import XCTest
@testable import CodeIsland

final class L10nTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    func testChineseTranslationsContainAllKeysPresentInEnglish() {
        let enKeys = Set(L10n.strings["en"]?.keys ?? Dictionary<String, String>().keys)
        let zhKeys = Set(L10n.strings["zh"]?.keys ?? Dictionary<String, String>().keys)

        let missingKeys = enKeys.subtracting(zhKeys)
        XCTAssertTrue(missingKeys.isEmpty, "Chinese is missing keys: \(missingKeys)")
    }

    func testOnlyEnglishAndChineseAreShipped() {
        XCTAssertEqual(Set(L10n.strings.keys), ["en", "zh"])
    }

    func testAnOldLanguageChoiceFallsBackToEnglish() {
        // A choice saved before the other languages were removed.
        L10n.shared.language = "de"

        XCTAssertEqual(L10n.shared["reply_complete_placeholder"], "Reply complete")
    }

    func testMissingKeyReadsAsTheKey() {
        L10n.shared.language = "zh"

        XCTAssertEqual(L10n.shared["nonexistent_key"], "nonexistent_key")
    }

    // MARK: - reply_complete_placeholder

    func testReplyCompletePlaceholderHasNoBrackets() {
        for lang in ["en", "zh"] {
            let value = L10n.strings[lang]?["reply_complete_placeholder"] ?? ""
            XCTAssertFalse(value.hasPrefix("["),
                           "'\(lang)' reply_complete_placeholder must not start with '['")
            XCTAssertFalse(value.hasSuffix("]"),
                           "'\(lang)' reply_complete_placeholder must not end with ']'")
        }
    }

    func testReplyCompletePlaceholderReturnsLocalizedValuePerLanguage() {
        let expected: [String: String] = [
            "en": "Reply complete",
            "zh": "回复完成",
        ]
        for (lang, translation) in expected {
            L10n.shared.language = lang
            XCTAssertEqual(L10n.shared["reply_complete_placeholder"], translation,
                           "Wrong reply_complete_placeholder for language '\(lang)'")
        }
    }
}
