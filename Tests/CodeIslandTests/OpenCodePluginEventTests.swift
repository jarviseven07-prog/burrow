import XCTest
@testable import CodeIsland

/// OpenCode 1.x — the desktop app is 1.19 — loads the plugin through `server()`.
/// This runs the bundled file under node against a stand-in socket and checks
/// what would reach the island. Every event must say which hook it is, or the
/// island drops it: on 2026-10-28 a cut line in `base()` left every OpenCode
/// conversation out of the den, and only the bun tests (not run here) noticed.
final class OpenCodePluginEventTests: XCTestCase {
    func testServerEventsReachTheIslandWithTheirHookNames() throws {
        guard let node = Self.nodePath() else { throw XCTSkip("node is not installed") }
        let plugin = try XCTUnwrap(
            Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js", subdirectory: "Resources")
                ?? Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js")
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-oc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: plugin, to: dir.appendingPathComponent("codeisland.mjs"))
        try Self.script.write(to: dir.appendingPathComponent("run.mjs"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [dir.appendingPathComponent("run.mjs").path]
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["CODEISLAND_SOCKET_PATH"] = dir.appendingPathComponent("island.sock").path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.hasPrefix("RESULT ") }, text)
        let received = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.dropFirst("RESULT ".count).utf8)) as? [[String: Any]]
        )
        let byEvent = { (name: String) in received.first { $0["hook_event_name"] as? String == name } }

        XCTAssertEqual(received.count, 3)
        for payload in received {
            XCTAssertEqual(payload["session_id"] as? String, "opencode-ses_1")
            XCTAssertEqual(payload["_source"] as? String, "opencode")
            XCTAssertNotNil(payload["hook_event_name"], "the island drops an event without its hook name")
        }
        XCTAssertEqual(byEvent("SessionStart")?["cwd"] as? String, "/p/app")
        XCTAssertEqual(byEvent("PreToolUse")?["tool_name"] as? String, "Bash")
        XCTAssertEqual(byEvent("Stop")?["session_title"] as? String, "List the project files")
    }

    private static let script = #"""
    import { createServer } from "net";
    const received = [];
    const island = createServer((sock) => {
      let buf = "";
      sock.on("data", (d) => { buf += d; });
      sock.on("end", () => { received.push(JSON.parse(buf)); });
    });
    await new Promise((resolve) => island.listen(process.env.CODEISLAND_SOCKET_PATH, resolve));
    const mod = await import("./codeisland.mjs");
    const hooks = await mod.default.server({ client: {}, serverUrl: new URL("http://127.0.0.1:4096") });
    const fire = (type, properties) => hooks.event({ event: { type, properties } });
    await fire("session.created", { info: { id: "ses_1", directory: "/p/app" } });
    await fire("message.part.updated", {
      part: { type: "tool", sessionID: "ses_1", tool: "bash", state: { status: "running", input: { command: "ls" } } },
    });
    await fire("session.updated", { info: { id: "ses_1", title: "List the project files" } });
    await fire("session.status", { sessionID: "ses_1", status: { type: "idle" } });
    for (let i = 0; i < 200 && received.length < 3; i++) await new Promise((r) => setTimeout(r, 10));
    console.log("RESULT " + JSON.stringify(received));
    process.exit(0);
    """#

    private static func nodePath() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let dirs = path + [NSHomeDirectory() + "/.local/node/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
