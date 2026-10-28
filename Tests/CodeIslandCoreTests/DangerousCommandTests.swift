import XCTest
@testable import CodeIslandCore

/// The approval card marks these words red and drops its default button.
final class DangerousCommandTests: XCTestCase {
    private func marked(_ command: String) -> [String] {
        DangerousCommand.matches(in: command).map { String(command[$0.range]) }
    }

    private func kinds(_ command: String) -> [DangerousCommand.Kind] {
        DangerousCommand.matches(in: command).map(\.kind)
    }

    func testRecursiveForcedRemoveIsMarked() {
        XCTAssertEqual(marked("rm -rf build dist node_modules/.cache"), ["rm -rf"])
        XCTAssertEqual(marked("rm -fr build"), ["rm -fr"])
        XCTAssertEqual(marked("rm -r -f build"), ["rm -r -f"])
        XCTAssertEqual(marked("rm --recursive --force build"), ["rm --recursive --force"])
        XCTAssertEqual(marked("cd x && rm -Rf y"), ["rm -Rf"])
    }

    func testOrdinaryRemoveIsNot() {
        XCTAssertEqual(marked("rm notes.txt"), [])
        XCTAssertEqual(marked("rm -f notes.txt"), [])
        XCTAssertEqual(marked("rm -r empty"), [])
        XCTAssertEqual(marked("git rm --cached x"), [])
        XCTAssertEqual(marked("npm run format"), [])
    }

    func testOtherKinds() {
        XCTAssertEqual(kinds("sudo make install"), [.sudo])
        XCTAssertEqual(marked("git push --force origin main"), ["--force"])
        XCTAssertEqual(marked("git push -f"), ["-f"])
        XCTAssertEqual(marked("git push --force-with-lease"), [])
        XCTAssertEqual(kinds("git reset --hard HEAD~1"), [.resetHard])
        XCTAssertEqual(kinds("git clean -fdx"), [.clean])
        XCTAssertEqual(kinds("git clean -n"), [])
        XCTAssertEqual(kinds("psql -c 'drop table users'"), [.drop])
        XCTAssertEqual(kinds("chmod -R 777 ."), [.chmodOpen])
        XCTAssertEqual(kinds("chmod 644 a.txt"), [])
    }

    /// Options before git's subcommand don't hide it (design/v20 review).
    func testGitOptionsBeforeTheSubcommand() {
        XCTAssertEqual(kinds("git -C ~/Developer/projects/CodeIsland reset --hard HEAD~1"), [.resetHard])
        XCTAssertEqual(marked("git -C ~/x reset --hard HEAD~1"), ["reset --hard"], "the folder is not the danger")
        XCTAssertEqual(marked("git clean -fdx"), ["clean -fdx"])
        XCTAssertEqual(marked("git -C \"my repo\" push --force origin main"), ["--force"])
        XCTAssertEqual(kinds("git -c core.pager=cat --no-pager clean -fd"), [.clean])
        XCTAssertEqual(kinds("git -C x push"), [])
        XCTAssertEqual(kinds("git -C x status"), [])
    }

    func testSafeCommandsStayPlain() {
        for command in ["ls -la", "swift test --filter BurrowLip", "git status", "git push", "npm run build",
                        "grep -rf patterns.txt src", "rsync -a src dst"] {
            XCTAssertEqual(marked(command), [], command)
        }
    }

    func testSeveralMatchesComeInOrder() {
        XCTAssertEqual(kinds("sudo rm -rf /tmp/x"), [.sudo, .remove])
    }
}
