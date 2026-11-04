import XCTest
@testable import CodeIsland

/// Health check 2026-11-04 #13: a quota lookup's child that ignored SIGTERM,
/// or a grandchild still holding its output pipe, kept the read blocked
/// past the deadline, `running` stayed true and no bar updated again until
/// Burrow restarted. Every read now ends at the deadline.
final class QuotaLookupDeadlineTests: XCTestCase {
    private func rpc(_ script: String, timeout: TimeInterval) throws -> LineRPC {
        try XCTUnwrap(LineRPC(executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", script], timeout: timeout))
    }

    func testAnAnswerComesBack() throws {
        let rpc = try rpc(#"read line; echo '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'; sleep 30"#, timeout: 5)
        defer { rpc.close() }
        XCTAssertEqual(rpc.request("ping", [:])?["ok"] as? Bool, true)
    }

    func testAChildThatIgnoresSIGTERMStillEndsTheReadAtTheDeadline() throws {
        let rpc = try rpc("trap '' TERM; read line; sleep 30", timeout: 1)
        let start = Date()
        XCTAssertNil(rpc.request("ping", [:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        rpc.close()
    }

    func testAGrandchildHoldingThePipeStillEndsTheReadAtTheDeadline() throws {
        // The shell is gone at once; its background sleep keeps stdout open.
        let rpc = try rpc("sleep 30 & exit 0", timeout: 1)
        defer { rpc.close() }
        let start = Date()
        XCTAssertNil(rpc.request("ping", [:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    /// A child that ignores SIGTERM is killed outright a moment later.
    func testAStubbornChildIsKilled() throws {
        let rpc = try rpc("trap '' TERM; while true; do sleep 1; done", timeout: 0.5)
        let pid = rpc.processIdentifier
        XCTAssertNil(rpc.request("ping", [:]))
        rpc.close()
        let deadline = Date().addingTimeInterval(LineRPC.killGrace + 3)
        while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "still running")
    }
}
