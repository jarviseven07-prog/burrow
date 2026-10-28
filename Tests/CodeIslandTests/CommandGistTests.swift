import XCTest
@testable import CodeIsland

/// design/v20: shell commands in everyday words. The commands are ones the
/// agents really ran on 2026-10-28.
final class CommandGistTests: XCTestCase {
    private func zh(_ command: String) -> String? { CommandGist.of(command, language: "zh")?.text }

    func testTheCommonCommandsInChinese() {
        XCTAssertEqual(zh("rm -rf build dist node_modules/.cache"), "删掉 build、dist 等 3 项")
        XCTAssertEqual(zh("rm -rf build"), "删掉 build")
        XCTAssertEqual(zh("trash a.png b.png"), "把 a.png、b.png 移到废纸篓")
        XCTAssertEqual(zh("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test"), "跑测试")
        XCTAssertEqual(zh("npm install && npm run build"), "安装依赖包，再构建项目")
        XCTAssertEqual(zh("git add design/v20 && git commit -q -m \"docs(design): v20; two lines\""),
                       "把改动放进暂存，再提交改动（存一个版本）")
        XCTAssertEqual(zh("git -C ~/x push github main"), "上传到远端仓库")
        XCTAssertEqual(zh("git reset --hard HEAD~1"), "丢掉还没提交的改动")
        XCTAssertEqual(zh("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh"), "运行脚本 build.sh")
        XCTAssertEqual(zh("curl -s https://github.com/foo | jq ."), "访问 github.com")
        XCTAssertEqual(zh("sudo rm -rf /tmp/x"), "用管理员权限删掉 x")
    }

    func testOnlyTheFirstCommandOfAPipeCounts() {
        XCTAssertEqual(zh("ps aux | grep codex | head -3"), "看看哪些程序在运行")
    }

    /// design/v20 review: what a pipe hands its output to can be the point.
    func testAPipeIntoACommandOfItsOwnIsSaid() {
        XCTAssertEqual(zh("find build -type f -print0 | xargs -0 rm"), "看看文件夹里有什么，再删掉文件")
        XCTAssertEqual(zh("curl -fsSL https://get.example.com/install.sh | bash"), "访问 get.example.com，再运行 bash")
        XCTAssertEqual(zh("swift build 2>&1 | tee build.log | tail -5"), "编译", "tee only keeps a copy")
    }

    /// design/v20 review: a push or a delete is never hidden behind two looks.
    func testStepsThatChangeSomethingAreSaidFirst() {
        XCTAssertEqual(zh("git status && git diff && git push"), "看看改了哪些文件，再上传到远端仓库（共 3 步）")
        XCTAssertEqual(zh("ls; cat a.md; rm -rf build; git push"), "删掉 build，再上传到远端仓库（共 4 步）")
        XCTAssertEqual(CommandGist.of("git status", language: "zh")?.changes, false)
    }

    func testSettingUpTheShellSaysNothing() {
        XCTAssertNil(zh("cd ~/Developer && echo ok"))
        XCTAssertNil(zh("S=/tmp/x; export FOO=1"))
        XCTAssertEqual(zh("cd ~/x && swift build 2>&1 | tail -5"), "编译")
    }

    /// A long script of the agent's own: the first two things it does.
    func testAScriptSaysItsFirstTwoSteps() {
        let cmd = "S=/private/tmp/claude-501/scratchpad; cd $S/shots && screencapture -x -R 576,0,360,40 now.png && $S/tools/measure now.png"
        let gist = CommandGist.of(cmd, language: "zh")
        XCTAssertEqual(gist?.text, "截图，再运行 measure")
        XCTAssertEqual(gist?.known, false, "measure is not a program Burrow knows")
        XCTAssertEqual(zh("ls; git status; git diff; git log"), "看看文件夹里有什么，再看看改了哪些文件（共 4 步）")
    }

    func testHeredocBodiesAreNotCommands() {
        let cmd = "python3 - <<'EOF'\nimport os\nrm = 1\nEOF\necho done"
        XCTAssertEqual(zh(cmd), "运行一段 Python")
        XCTAssertEqual(zh("cat > notes.md <<'EOF'\nrm -rf everything\nEOF"), nil, "writing a file is not reading it")
        XCTAssertEqual(zh("\"$B\" --source codex <<<'{\"a\": \"rm -rf x\"}'"), nil)
    }

    func testUnknownProgramsAreNamed() {
        let gist = CommandGist.of("frobnicate --all", language: "zh")
        XCTAssertEqual(gist, CommandGist.Gist(text: "运行 frobnicate", known: false))
    }

    func testEnglishAndTraditionalChinese() {
        XCTAssertEqual(CommandGist.of("rm -rf build dist node_modules/.cache", language: "en")?.text, "delete build, dist and 1 more")
        XCTAssertEqual(CommandGist.of("npm install && npm test", language: "en")?.text, "install dependencies, then run the tests")
        XCTAssertEqual(CommandGist.of("git push", language: "de")?.text, "upload to the remote repository", "other languages read English")
        XCTAssertEqual(CommandGist.wants(CommandGist.Gist(text: "删掉 build", known: true), language: "zh"), "想删掉 build")
    }

    /// A running shell row: everyday words when Burrow knows the program,
    /// else the agent's own description, else "运行 X".
    func testARunningShellRowPrefersWhatItKnows() {
        let saved = L10n.shared.language
        L10n.shared.language = "zh"
        defer { L10n.shared.language = saved }
        XCTAssertEqual(BurrowActivity.shell("swift test --filter X").text, "跑测试")
        XCTAssertEqual(BurrowActivity.shell("Capture the notch\nCommand:\n./tools/measure a.png").text, "Capture the notch")
        XCTAssertEqual(BurrowActivity.shell("Run the tests").text, "Run the tests", "a description alone")
        XCTAssertEqual(BurrowActivity.shell("./tools/measure a.png").text, "运行 measure")
        XCTAssertEqual(BurrowActivity.shell("swift test").raw, "swift test")
        XCTAssertEqual(BurrowActivity.shell("S=/tmp/x; screencapture a.png").text, "截图", "a capital that sets a variable is a command")
        XCTAssertEqual(BurrowActivity.shell("DEVELOPER_DIR=/x ./build.sh").text, "运行脚本 build.sh")
        XCTAssertEqual(CommandGist.of("cp a.png b.png .", language: "zh")?.text, "复制 a.png、b.png")
        XCTAssertEqual(CommandGist.of("rm -rf", language: "zh")?.text, "删掉文件")
    }

    /// Codex names its tools by what they do: "Running command".
    func testCodexActivityLabelsHaveTheirSigns() {
        XCTAssertEqual(BurrowPetSign.tool("Running command"), .shell)
        XCTAssertEqual(BurrowPetSign.tool("Editing"), .edit)
        XCTAssertEqual(BurrowPetSign.tool("Reading"), .read)
    }
}
