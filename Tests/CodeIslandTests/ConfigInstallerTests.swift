import XCTest
@testable import CodeIsland
import CodeIslandCore

final class ConfigInstallerTests: XCTestCase {

    func testRemoveManagedHookEntriesAlsoPrunesLegacyVibeIslandHooks() throws {
        let hooks: [String: Any] = [
            "SessionEnd": [
                [
                    "hooks": [
                        [
                            "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude",
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.claude/hooks/codeisland-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "async": true,
                            "command": "~/.claude/hooks/bark-notify.sh",
                            "timeout": 10,
                            "type": "command",
                        ],
                    ],
                ],
            ],
        ]

        let cleaned = ConfigInstaller.removeManagedHookEntries(from: hooks)
        let sessionEnd = try XCTUnwrap(cleaned["SessionEnd"] as? [[String: Any]])

        XCTAssertEqual(sessionEnd.count, 1)
        let remainingHooks = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "~/.claude/hooks/bark-notify.sh")
    }

    func testCodexSessionEndTimeoutRespectsTeardownCapAndRepairsStaleConfig() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let staleConfig = """
        {
          "hooks": {
            "SessionEnd": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/test/.codeisland/codeisland-bridge --source codex",
                    "timeout": 5
                  }
                ]
              }
            ]
          }
        }
        """
        let configPath = tempDir.appendingPathComponent("hooks.json")
        try staleConfig.write(to: configPath, atomically: true, encoding: .utf8)

        var codex = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        let tempPath = tempDir.path
        codex.rootOverride = { tempPath }

        let configuredTimeout = try XCTUnwrap(codex.events.first { $0.0 == "SessionEnd" }?.1)
        XCTAssertEqual(configuredTimeout, 3)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: codex, fm: fm))

        let data = try Data(contentsOf: configPath)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let sessionEnd = try XCTUnwrap(hooks["SessionEnd"] as? [[String: Any]])
        let hookList = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(hookList.first?["timeout"] as? Int, 3)
    }

    func testCodexRegistersEverySupportedLifecycleEvent() throws {
        let codex = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        let configured = Set(codex.events.map { $0.0 })
        let expected: Set<String> = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SessionStart", "SessionEnd", "SubagentStart",
            "SubagentStop", "UserPromptSubmit", "Stop", "Interrupt",
        ]

        XCTAssertEqual(configured, expected)
    }

    // MARK: - Opencode config merge (issue #89 — do not clobber user-authored config)

    func testMergeOpencodePluginRefCreatesMinimalConfigWhenFileAbsent() throws {
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: nil,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        XCTAssertEqual(json["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(json["plugin"] as? [String], ["file:///tmp/codeisland.js"])
    }

    func testMergeOpencodePluginRefPreservesUnrelatedKeysAndOtherPlugins() throws {
        let original = """
        {
          "model": "anthropic/claude-sonnet-4",
          "theme": "tokyonight",
          "plugin": ["file:///user/other-plugin.js"],
          "autoshare": false
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet-4")
        XCTAssertEqual(json["theme"] as? String, "tokyonight")
        XCTAssertEqual(json["autoshare"] as? Bool, false)
        let plugins = try XCTUnwrap(json["plugin"] as? [String])
        XCTAssertTrue(plugins.contains("file:///user/other-plugin.js"))
        XCTAssertTrue(plugins.contains("file:///tmp/codeisland.js"))
    }

    func testMergeOpencodePluginRefDeduplicatesOurOwnRefs() throws {
        let original = """
        {
          "plugin": [
            "file:///old/codeisland.js",
            "file:///some/vibe-island.js",
            "file:///user/other.js"
          ]
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///new/codeisland.js",
                identifier: "codeisland"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(json["plugin"] as? [String])
        XCTAssertEqual(plugins.filter { $0.contains("codeisland") }.count, 1)
        XCTAssertFalse(plugins.contains { $0.contains("vibe-island") })
        XCTAssertTrue(plugins.contains("file:///user/other.js"))
        XCTAssertTrue(plugins.contains("file:///new/codeisland.js"))
    }

    func testMergeOpencodePluginRefReturnsNilOnMalformedJSON() {
        // Unterminated object — installer MUST refuse to overwrite instead of
        // nuking the user's config.
        let malformed = "{\n  \"model\": \"sonnet\",\n  \"plugin\": [\n"
        XCTAssertNil(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: malformed,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
    }

    func testMergeOpencodePluginRefReturnsNilWhenRootIsNotAnObject() {
        // User accidentally wrote a top-level array instead of object.
        let array = "[\"not\", \"an\", \"object\"]"
        XCTAssertNil(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: array,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
    }

    func testRemoveOpencodePluginRefKeepsUserKeysAndOtherPlugins() throws {
        let original = """
        {
          "model": "sonnet",
          "plugin": ["file:///tmp/codeisland.js", "file:///user/other.js"]
        }
        """
        let cleaned = try XCTUnwrap(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: original,
                identifier: "codeisland"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "sonnet")
        XCTAssertEqual(json["plugin"] as? [String], ["file:///user/other.js"])
    }

    func testRemoveOpencodePluginRefReturnsNilOnMalformedJSON() {
        XCTAssertNil(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: "{ not valid json",
                identifier: "codeisland"
            )
        )
    }

    func testRemoveOpencodePluginRefReturnsNilWhenFileAbsent() {
        XCTAssertNil(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: nil,
                identifier: "codeisland"
            )
        )
    }

    // MARK: - Minimal-diff merge preserves user formatting (#105 / #106 / #119)

    func testMergeOpencodePluginRefPreservesJSONCCommentsAndKeyOrder() throws {
        let original = """
        {
          // Default model
          "model": "github-copilot/gpt-5.4",
          "permission": {
            "bash": "allow"
          },
          "plugin": ["file:///old/other-plugin.js"]
        }

        """ // trailing blank line emulates user's EOF newline
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
        // Comment survives.
        XCTAssertTrue(merged.contains("// Default model"), "JSONC comment must survive minimal-diff merge")
        // Slashes not escaped.
        XCTAssertFalse(merged.contains("\\/"), "Slashes must not be escaped as \\/")
        // Key order: model → permission → plugin (unchanged from original)
        let modelIdx = try XCTUnwrap(merged.range(of: "\"model\""))
        let permIdx = try XCTUnwrap(merged.range(of: "\"permission\""))
        let pluginIdx = try XCTUnwrap(merged.range(of: "\"plugin\""))
        XCTAssertTrue(modelIdx.lowerBound < permIdx.lowerBound)
        XCTAssertTrue(permIdx.lowerBound < pluginIdx.lowerBound)
        // New plugin ref added, old other-plugin kept.
        XCTAssertTrue(merged.contains("file:///tmp/codeisland.js"))
        XCTAssertTrue(merged.contains("file:///old/other-plugin.js"))
    }

    func testMergeOpencodePluginRefPreservesUnrelatedEnvAndApiKey() throws {
        // #119: ANTHROPIC_API_KEY and other env entries must NOT vanish across an install.
        let original = """
        {
          "env": {
            "ANTHROPIC_API_KEY": "sk-super-secret",
            "MAX_MCP_OUTPUT_TOKENS": "200000"
          },
          "autoMemoryEnabled": false,
          "plugin": []
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/codeisland.js",
                identifier: "codeisland"
            )
        )
        XCTAssertTrue(merged.contains("\"ANTHROPIC_API_KEY\": \"sk-super-secret\""),
                      "User's API key must survive the install")
        XCTAssertTrue(merged.contains("\"MAX_MCP_OUTPUT_TOKENS\": \"200000\""))
        XCTAssertTrue(merged.contains("\"autoMemoryEnabled\": false"))
        XCTAssertTrue(merged.contains("file:///tmp/codeisland.js"))
    }

    func testRemoveOpencodePluginRefPreservesOriginalFormatting() throws {
        let original = """
        {
          "model": "sonnet",
          "plugin": ["file:///tmp/codeisland.js", "file:///user/other.js"],
          "autoshare": false
        }

        """
        let cleaned = try XCTUnwrap(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: original,
                identifier: "codeisland"
            )
        )
        XCTAssertTrue(cleaned.contains("\"model\": \"sonnet\""))
        XCTAssertTrue(cleaned.contains("file:///user/other.js"))
        XCTAssertFalse(cleaned.contains("file:///tmp/codeisland.js"))
        XCTAssertFalse(cleaned.contains("\\/"), "No slash escaping")
    }

}
