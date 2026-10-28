import XCTest
@testable import CodeIsland

/// Each agent with its own pet sounds in its own key; everyone else uses
/// the base Burrow sounds.
@MainActor
final class SoundVoiceTests: XCTestCase {
    func testAgentsWithTheirOwnPetHaveTheirOwnVoice() {
        XCTAssertNil(SoundManager.voice(forSource: "claude"))
        XCTAssertNil(SoundManager.voice(forSource: nil))
        XCTAssertNil(SoundManager.voice(forSource: "cursor"), "agents without a pet use the base sounds")
        XCTAssertEqual(SoundManager.voice(forSource: "codex"), "codex")
        XCTAssertEqual(SoundManager.voice(forSource: "opencode"), "opencode")
        XCTAssertEqual(SoundManager.voice(forSource: "google-antigravity"), "antigravity")
    }

    func testEveryVoiceShipsEverySound() {
        for sound in ["burrow_start", "burrow_submit", "burrow_approval", "burrow_complete", "burrow_error", "burrow_boot"] {
            for voice in ["", "_codex", "_opencode", "_antigravity"] {
                let name = sound + voice
                let url = Bundle.appModule.url(forResource: name, withExtension: "wav", subdirectory: "Resources")
                    ?? Bundle.appModule.url(forResource: name, withExtension: "wav")
                XCTAssertNotNil(url, "\(name).wav missing from the bundle")
            }
        }
    }
}
