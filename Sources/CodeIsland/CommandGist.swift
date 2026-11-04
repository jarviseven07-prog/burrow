import Foundation

/// A shell command in everyday words — "删掉 build、dist 等 3 项", "跑测试" —
/// for people who don't read shell (design/v20). Claude Desktop sends the
/// command alone, with no description, so Burrow says it itself: the common
/// programs it knows, else "运行 X". Its own phrase table rather than
/// L10n's: Chinese (both scripts) and English; other languages read English.
enum CommandGist {
    struct Gist: Equatable {
        let text: String
        /// A program Burrow knows; false for a bare "运行 X".
        let known: Bool
        /// False for a step that only looks (ls, git status, grep…).
        var changes = true
        /// Output written into a file (`> build.log`): said, but after the
        /// other changes when there are more than two steps.
        var isWrite = false
    }

    /// The gist of `command`; nil when it only moves around (cd, echo…).
    static func of(_ command: String, language: String = L10n.shared.effectiveLanguage) -> Gist? {
        let words = Words(language)
        var steps: [Gist] = []
        for part in segments(of: command) {
            var said: [Gist] = []
            let step = part.piped ? pipedGist(of: part.words, words) : gist(of: part.words, words)
            let write = writeGist(of: part.words, words)
            // Output that goes into a file is not shown to anyone: a look
            // whose output is written is the write (`cat /dev/null > ~/.zshrc`).
            if let step, write == nil || step.changes { said.append(step) }
            if let write { said.append(write) }
            for step in said where !steps.contains(where: { $0.text == step.text }) { steps.append(step) }
        }
        guard !steps.isEmpty else { return nil }
        // Two steps are said. With more, the ones that change something come
        // first, so a push or a delete is never hidden behind two looks
        // (design/v20 review) — or behind a log file being written; they keep
        // the order they run in.
        func rank(_ step: Gist) -> Int { step.changes ? (step.isWrite ? 1 : 2) : 0 }
        let pick = steps.indices.sorted { a, b in
            rank(steps[a]) != rank(steps[b]) ? rank(steps[a]) > rank(steps[b]) : a < b
        }.prefix(2)
        let shown = pick.sorted().map { steps[$0] }
        var text = shown.map(\.text).joined(separator: words.then)
        if steps.count > 2 { text += String(format: words.steps, steps.count) }
        return Gist(text: text, known: shown.allSatisfy(\.known), changes: shown.contains(where: \.changes))
    }

    /// "想删掉…" / "wants to delete…": what an agent asks to run.
    static func wants(_ gist: Gist, language: String = L10n.shared.effectiveLanguage) -> String {
        String(format: Words(language).wants, gist.text)
    }

    // MARK: Reading the shell

    /// One command of a line, as its words; `piped` when it reads the one
    /// before it through a pipe.
    struct Part {
        let words: [String]
        let piped: Bool
    }

    /// Each command a line runs: split at ; && || & | and new lines. Quotes
    /// and $( ) stay whole; heredoc bodies and comments are dropped.
    static func segments(of command: String) -> [Part] {
        var out: [Part] = []
        var words: [String] = [], word = ""
        var quote: Character?, depth = 0
        var inPipe = false, heredoc: String?
        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        func endSegment(pipe: Bool) {
            endWord()
            if !words.isEmpty { out.append(Part(words: words, piped: inPipe)) }
            words = []
            inPipe = pipe
        }
        let lines = command.components(separatedBy: "\n")
        for line in lines {
            if let end = heredoc {
                if line.trimmingCharacters(in: .whitespaces) == end { heredoc = nil }
                continue
            }
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    if q == "\"", c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                        word.append(chars[i + 1]); i += 2   // "a \" b" stays one quote
                        continue
                    }
                    if c == q { quote = nil } else { word.append(c) }
                } else if depth > 0 {
                    if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                    word.append(c)
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "\\", i + 1 < chars.count {
                    // \; \| \  are plain characters: find's `-exec … \;` is one command.
                    // \> \< keep their backslash, or they would read as redirects.
                    if "<>".contains(chars[i + 1]) { word.append(c) }
                    word.append(chars[i + 1]); i += 2
                    continue
                } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                    depth = 1; word.append("$("); i += 1
                } else if c == "#", word.isEmpty {
                    break
                } else if c == ";" {
                    endSegment(pipe: false)
                } else if c == "&" || c == "|" {
                    let doubled = i + 1 < chars.count && chars[i + 1] == c
                    if c == "&", !doubled, i > 0, chars[i - 1] == ">" || (i + 1 < chars.count && chars[i + 1] == ">") {
                        word.append(c)   // 2>&1, &>file
                    } else {
                        endSegment(pipe: c == "|" && !doubled)
                        if doubled { i += 1 }
                    }
                } else if c == "<", i + 2 < chars.count, chars[i + 1] == "<", chars[i + 2] == "<" {
                    // <<<"text": a here-string, not a heredoc.
                    endWord()
                    i += 3
                    continue
                } else if c == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                    // <<EOF, <<-'EOF': skip the body that follows this line.
                    var j = i + 2
                    if j < chars.count, chars[j] == "-" { j += 1 }
                    while j < chars.count, chars[j] == " " { j += 1 }
                    var tag = ""
                    while j < chars.count, !" ;|&)".contains(chars[j]) {
                        if chars[j] != "'" && chars[j] != "\"" { tag.append(chars[j]) }
                        j += 1
                    }
                    if !tag.isEmpty { heredoc = tag }
                    endWord()
                    i = j
                    continue
                } else if c == ">" {
                    // An unquoted > redirects wherever it stands (`x>~/.zshrc`):
                    // it starts a word of its own, keeping a 2 or & in front
                    // (2>, &>). Arrows (->, =>) and markup (<a:t>) are text
                    // whose nested quotes this reading lost.
                    let staysInWord = word.allSatisfy(\.isNumber) || word == "&"
                        || word.hasSuffix(">") || word.hasSuffix("-") || word.hasSuffix("=") || word.contains("<")
                    if !staysInWord { endWord() }
                    word.append(c)
                } else if c == " " || c == "\t" {
                    endWord()
                } else {
                    word.append(c)
                }
                i += 1
            }
            if quote == nil, depth == 0 { endSegment(pipe: false) } else { word.append("\n") }
        }
        endSegment(pipe: false)
        return out
    }

    /// Words that only set up the shell around a command.
    static let quiet: Set<String> = [
        "cd", "pushd", "popd", "echo", "printf", "sleep", "export", "set", "unset", "source", ".",
        "true", "false", "wait", "clear", "read", "local", "exit", "return", "test", "[", "[[",
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "{", "}",
        "alias", "unalias", "shift", "trap", "eval",
    ]
    /// Words that run the command after them.
    static let wrappers: Set<String> = ["time", "env", "nohup", "exec", "command", "builtin", "caffeinate", "timeout", "gtimeout"]
    /// Options of those that take a value (`timeout -s KILL`, `env -u NAME`).
    private static let wrapperValued: Set<String> = ["-s", "-k", "--signal", "--kill-after", "-u", "--unset"]
    /// Programs that only filter what comes down a pipe.
    static let filters: Set<String> = [
        "grep", "rg", "ag", "egrep", "fgrep", "ack", "head", "tail", "sort", "uniq", "wc", "cut", "awk",
        "tr", "jq", "yq", "column", "less", "more", "cat", "bat", "fold", "nl", "fmt", "paste", "comm",
        "tac", "rev", "xxd", "od", "hexdump", "base64", "fzf", "pbcopy", "tee", "sed", "perl",
    ]
    /// xargs options that take a value.
    private static let xargsValued: Set<String> = ["-n", "-I", "-P", "-L", "-s", "-E", "-d", "-J", "-R", "-S"]

    /// A command after a pipe: nothing to say when it only filters, but a
    /// `| xargs rm` or `| sh` does something of its own (design/v20 review).
    private static func pipedGist(of segment: [String], _ w: Words) -> Gist? {
        var rest = segment[...]
        if let head = rest.first, (head as NSString).lastPathComponent == "xargs" {
            rest = dropXargs(rest)
        }
        guard let program = rest.first else { return nil }
        let name = (program as NSString).lastPathComponent
        let editsInPlace = (name == "sed" || name == "perl")
            && rest.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "-pi" })
        if filters.contains(name), !editsInPlace { return nil }
        return gist(of: Array(rest), w)
    }

    /// The words after `xargs` and its options.
    private static func dropXargs(_ words: ArraySlice<String>) -> ArraySlice<String> {
        var rest = words.dropFirst()
        while let flag = rest.first, flag.hasPrefix("-") {
            rest = rest.dropFirst()
            if xargsValued.contains(flag) { rest = rest.dropFirst() }
        }
        return rest
    }

    /// "覆盖写入 .zshrc" when a command's output goes into a file (`>`, `>>`,
    /// `2>`, `&>`…); nil when it goes nowhere that lasts (/dev/null, 2>&1).
    private static func writeGist(of segment: [String], _ w: Words) -> Gist? {
        var targets: [String] = [], appends = true
        var i = 0
        while i < segment.count {
            let word = segment[i]
            guard let match = word.range(of: #"^(?:\d|&)?(>>?)"#, options: .regularExpression) else { i += 1; continue }
            let op = word[match]
            var target = String(word[match.upperBound...])
            if target.isEmpty, i + 1 < segment.count {
                target = segment[i + 1]
                i += 1
            } else if target.first == ">" || target.contains(where: \.isWhitespace) {
                i += 1
                continue  // a quoted ">>> hi" that lost its quotes, not a redirect
            }
            i += 1
            // `2>&1`, `>&2`: one output joins another, no file.
            guard !target.isEmpty, !target.hasPrefix("&"), !target.hasPrefix("/dev/") else { continue }
            if !op.hasSuffix(">>") { appends = false }
            targets.append(target)
        }
        let files = names(targets)
        guard !files.isEmpty else { return nil }
        return Gist(text: String(format: appends ? w.append : w.overwrite, w.list(files)), known: true, isWrite: true)
    }

    /// The command's arguments, without redirections.
    private static func arguments(_ words: ArraySlice<String>) -> [String] {
        var out: [String] = [], skipNext = false
        for w in words {
            if skipNext { skipNext = false; continue }
            if [">", ">>", "<", "2>", "&>", "1>", "2>>"].contains(w) { skipNext = true; continue }
            if w.first == ">" || w.first == "<" || w.hasPrefix("2>") || w.hasPrefix("1>") || w.hasPrefix("&>") { continue }
            out.append(w)
        }
        return out
    }

    /// The names an argument list points at: file and folder names, not flags.
    static func names(_ args: [String]) -> [String] {
        args.filter { !$0.hasPrefix("-") && !$0.isEmpty }.compactMap { arg in
            let trimmed = arg.hasSuffix("/") && arg.count > 1 ? String(arg.dropLast()) : arg
            let base = (trimmed as NSString).lastPathComponent
            guard !base.isEmpty, base != "." else { return nil }
            return base.count > 24 ? String(base.prefix(23)) + "…" : base
        }
    }

    private static func gist(of segment: [String], _ w: Words) -> Gist? {
        var rest = segment[...]
        var admin = false
        // NAME=value, sudo, time…: the command is after them.
        while let head = rest.first {
            if head.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                rest = rest.dropFirst()
            } else if head == "sudo" {
                admin = true
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
            } else if wrappers.contains(head) {
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") || flag.contains("=") {
                    rest = rest.dropFirst()
                    if wrapperValued.contains(flag) { rest = rest.dropFirst() }
                }
                // `timeout 60 rm -rf build`: the duration is not the command.
                if head.hasSuffix("timeout"), let duration = rest.first,
                   duration.range(of: #"^\d+(\.\d+)?[smhd]?$"#, options: .regularExpression) != nil {
                    rest = rest.dropFirst()
                }
            } else if head == "xargs" {
                // `xargs rm -rf < dirs.txt` runs rm whether or not it is piped.
                rest = dropXargs(rest)
            } else {
                break
            }
        }
        guard let program = rest.first else { return nil }
        let name = (program as NSString).lastPathComponent
        guard !quiet.contains(name) else { return nil }
        let args = arguments(rest.dropFirst())
        guard let step = phrase(name: name, path: program, args: args, w) else { return nil }
        return admin ? Gist(text: String(format: w.admin, step.text), known: step.known) : step
    }

    private static func phrase(name: String, path: String, args: [String], _ w: Words) -> Gist? {
        func known(_ text: String) -> Gist { Gist(text: text, known: true) }
        func looks(_ text: String) -> Gist { Gist(text: text, known: true, changes: false) }
        func with(_ template: String, _ items: [String], fallback: String? = nil) -> Gist {
            if !items.isEmpty { return known(String(format: template, w.list(items))) }
            if let fallback { return known(fallback) }
            // "删掉文件", not "删掉 文件": the space is only for Latin names.
            let text = String(format: template, w.files)
            guard w.files.first?.isASCII == false else { return known(text) }
            return known(text.replacingOccurrences(of: " " + w.files, with: w.files)
                .replacingOccurrences(of: w.files + " ", with: w.files))
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        let sub = positional.first ?? ""
        switch name {
        case "rm", "rmdir", "unlink", "srm":
            return with(w.remove, names(args))
        case "trash":
            return with(w.trash, names(args))
        case "mv":
            return with(w.move, names(Array(positional.dropLast())))
        case "cp", "ditto", "rsync":
            return with(w.copy, names(Array(positional.dropLast())))
        case "mkdir":
            return with(w.mkdir, names(args))
        case "touch":
            return with(w.touch, names(args))
        case "cat", "head", "tail", "less", "more", "bat", "open-file":
            let files = names(args.filter { Int($0) == nil })
            return files.isEmpty ? nil : looks(with(w.look, files).text)
        case "find":
            // -delete and -exec are not looks (health check 2026-11-04 #7).
            if args.contains("-delete") { return known(w.findDelete) }
            // Every -exec counts; one that changes something is said first.
            let ends: Set<String> = [";", "+"]
            let runs = args.indices
                .filter { ["-exec", "-execdir", "-ok", "-okdir"].contains(args[$0]) }
                .compactMap { i in
                    gist(of: Array(args[(i + 1)...].prefix { !ends.contains($0) }.filter { $0 != "{}" }), w)
                }
            return runs.first(where: \.changes) ?? runs.first ?? looks(w.listing)
        case "ls", "tree", "fd", "du", "stat", "file":
            return looks(w.listing)
        case "grep", "rg", "ag", "egrep", "fgrep", "ack":
            guard let pattern = positional.first else { return looks(w.searching) }
            let short = pattern.count > 16 ? String(pattern.prefix(15)) + "…" : pattern
            return looks(String(format: w.search, short))
        case "wc":
            return looks(w.count)
        case "sed", "perl":
            if args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "-pi" }) {
                return with(w.edit, Array(names(args).dropFirst()))
            }
            return looks(w.text)
        case "awk", "sort", "uniq", "cut", "tr", "jq", "xargs", "column", "diff":
            return looks(w.text)
        case "git":
            return git(args, w)
        case "npm", "pnpm", "yarn", "bun":
            switch sub {
            case "", "install", "i", "ci", "add": return known(w.install)
            case "run", "run-script": return script(positional.dropFirst().first ?? "", w)
            case "exec", "x", "dlx": return Gist(text: String(format: w.run, positional.dropFirst().first ?? name), known: false)
            default: return script(sub, w)
            }
        case "npx", "bunx", "pnpx":
            return Gist(text: String(format: w.run, sub.isEmpty ? name : sub), known: false)
        case "pip", "pip3", "poetry", "uv", "pipx", "gem", "cargo-install", "pod":
            if name == "uv", sub == "run" { return python(Array(args.drop(while: { $0 != "run" }).dropFirst()), w) }
            return known(w.install)
        case "python", "python3", "python3.11", "python3.12", "python3.13":
            return python(args, w)
        case "node", "deno", "ruby", "php", "osascript-js":
            guard let file = names(positional).first else { return known(w.runProgram) }
            return known(String(format: w.runScript, file))
        case "swift":
            switch sub {
            case "build": return known(w.compile)
            case "test": return known(w.test)
            case "run": return known(w.runProgram)
            default: return known(w.runProgram)
            }
        case "swiftc", "clang", "gcc", "g++", "make", "cmake", "ninja", "tsc", "javac":
            return known(w.compile)
        case "cargo", "go":
            switch sub {
            case "test": return known(w.test)
            case "run": return known(w.runProgram)
            case "install", "get", "add": return known(w.install)
            default: return known(w.compile)
            }
        case "xcodebuild":
            return known(args.contains("test") ? w.test : w.compile)
        case "pytest", "jest", "vitest", "mocha":
            return known(w.test)
        case "bash", "sh", "zsh", "fish":
            if let file = names(positional).first { return known(String(format: w.runScript, file)) }
            return Gist(text: String(format: w.run, name), known: false)
        case "curl", "wget", "http", "xh":
            let host = positional.compactMap { URL(string: $0)?.host }.first
            return host.map { known(String(format: w.web, $0)) } ?? known(w.webAny)
        case "brew":
            if ["install", "reinstall", "upgrade"].contains(sub) {
                return with(w.installApp, Array(positional.dropFirst()), fallback: w.install)
            }
            return known(w.brew)
        case "open":
            if let i = args.firstIndex(of: "-a"), i + 1 < args.count { return known(String(format: w.open, args[i + 1])) }
            let targets = positional.map { URL(string: $0)?.host ?? (($0 as NSString).lastPathComponent) }.filter { !$0.isEmpty }
            return with(w.open, targets)
        case "osascript":
            return known(w.osascript)
        case "screencapture":
            return known(w.screenshot)
        case "sips", "convert", "magick", "pngquant", "optipng", "cwebp":
            return known(w.image)
        case "ffmpeg", "ffprobe", "ffplay":
            return known(w.video)
        case "defaults":
            return sub == "read" || sub == "domains" ? looks(w.readSettings) : known(w.writeSettings)
        case "kill", "pkill", "killall":
            return known(w.kill)
        case "ps", "pgrep", "lsof", "top", "htop":
            return looks(w.processes)
        case "launchctl":
            return known(w.processes)
        case "chmod", "chown", "chflags", "xattr":
            return known(w.permissions)
        case "tar", "zip", "unzip", "gzip", "gunzip", "7z":
            return known(w.archive)
        case "ssh", "scp", "sftp", "mosh":
            return known(w.remote)
        case "codesign", "notarytool", "spctl":
            return known(w.sign)
        case "docker", "docker-compose", "podman":
            return known(w.docker)
        default:
            // A script of the project's own: ./build.sh, $S/tools/measure.
            if name.hasSuffix(".sh") || name.hasSuffix(".py") || name.hasSuffix(".command") {
                return known(String(format: w.runScript, name))
            }
            if name.contains("$") || name.isEmpty { return nil }
            return Gist(text: String(format: w.run, name), known: false)
        }
    }

    private static func git(_ args: [String], _ w: Words) -> Gist {
        // git -C dir / -c key=value come before the subcommand.
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            i += (args[i] == "-C" || args[i] == "-c") ? 2 : 1
        }
        let sub = i < args.count ? args[i] : ""
        let rest = i < args.count ? Array(args[(i + 1)...]) : []
        func known(_ text: String) -> Gist { Gist(text: text, known: true) }
        func looks(_ text: String) -> Gist { Gist(text: text, known: true, changes: false) }
        switch sub {
        case "status": return looks(w.gitStatus)
        case "diff", "show": return looks(w.gitDiff)
        case "log", "reflog", "blame", "shortlog": return looks(w.gitLog)
        case "add": return known(w.gitAdd)
        case "commit": return known(w.gitCommit)
        case "push":
            // `--delete` / `-d` / `:branch` delete a branch on the remote.
            let refs = rest.filter { !$0.hasPrefix("-") }.dropFirst()
            let deleting = rest.contains("--delete") || rest.contains("-d")
                ? Array(refs) : refs.filter { $0.count > 1 && $0.hasPrefix(":") }.map { String($0.dropFirst()) }
            return deleting.isEmpty ? known(w.gitPush) : known(String(format: w.gitDeleteRemote, w.list(deleting)))
        case "pull", "fetch": return known(w.gitPull)
        case "checkout", "switch":
            // `checkout -- file`, `checkout .`, `-f`: uncommitted work is thrown away.
            let discards = rest.contains("--") || rest.first(where: { !$0.hasPrefix("-") }) == "."
                || rest.contains("-f") || rest.contains("--force") || rest.contains("--discard-changes")
            return known(discards ? w.gitResetHard : w.gitBranch)
        case "branch":
            let deletes = rest.contains { $0 == "--delete" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.lowercased().contains("d")) }
            let branches = rest.filter { !$0.hasPrefix("-") }
            return deletes && !branches.isEmpty
                ? known(String(format: w.gitDeleteBranch, w.list(branches))) : known(w.gitBranch)
        case "merge", "rebase", "cherry-pick": return known(w.gitMerge)
        case "reset": return known(rest.contains("--hard") ? w.gitResetHard : w.gitReset)
        case "restore": return known(w.gitReset)
        case "stash":
            return known(rest.first == "drop" || rest.first == "clear" ? w.gitStashDrop : w.gitStash)
        case "clone": return known(w.gitClone)
        case "rm", "mv": return known(w.gitAdd)
        case "clean": return known(w.gitClean)
        case "tag": return known(w.gitTag)
        case "init": return known(w.gitInit)
        default: return Gist(text: String(format: w.run, sub.isEmpty ? "git" : "git " + sub), known: false)
        }
    }

    private static func script(_ name: String, _ w: Words) -> Gist {
        let n = name.lowercased()
        if n.hasPrefix("test") || n.hasPrefix("e2e") { return Gist(text: w.test, known: true) }
        if n.hasPrefix("build") || n.hasPrefix("compile") { return Gist(text: w.build, known: true) }
        if ["dev", "start", "serve", "preview", "watch"].contains(where: n.hasPrefix) { return Gist(text: w.serve, known: true) }
        if n.hasPrefix("lint") || n.hasPrefix("format") || n.hasPrefix("typecheck") { return Gist(text: w.lint, known: true) }
        return Gist(text: String(format: w.runScript, name.isEmpty ? "npm" : name), known: false)
    }

    private static func python(_ args: [String], _ w: Words) -> Gist {
        if let i = args.firstIndex(of: "-m"), i + 1 < args.count {
            let module = args[i + 1]
            if module == "pytest" || module == "unittest" { return Gist(text: w.test, known: true) }
            if module == "pip" { return Gist(text: w.install, known: true) }
            if module == "http.server" { return Gist(text: w.serve, known: true) }
            return Gist(text: String(format: w.run, module), known: false)
        }
        if let file = args.first(where: { $0.hasSuffix(".py") }) {
            return Gist(text: String(format: w.runPython, (file as NSString).lastPathComponent), known: true)
        }
        return Gist(text: w.pythonSnippet, known: true)
    }

    // MARK: Words

    struct Words {
        let then, steps, wants, admin, files, and, more: String
        let moreCountsAll: Bool
        let remove, trash, move, copy, mkdir, touch, look, listing, search, searching, count, edit, text: String
        let findDelete, overwrite, append: String
        let gitStatus, gitDiff, gitLog, gitAdd, gitCommit, gitPush, gitPull, gitBranch, gitMerge: String
        let gitReset, gitResetHard, gitStash, gitClone, gitClean, gitTag, gitInit: String
        let gitDeleteBranch, gitDeleteRemote, gitStashDrop: String
        let install, test, build, compile, serve, lint, runScript, runPython, pythonSnippet, runProgram: String
        let installApp, brew, web, webAny, open, osascript, screenshot, image, video: String
        let readSettings, writeSettings, kill, processes, permissions, archive, remote, sign, docker, run: String

        /// "build、dist 等 3 项" / "build, dist and 1 more".
        func list(_ items: [String]) -> String {
            switch items.count {
            case 0: return files
            case 1: return items[0]
            case 2: return items[0] + and + items[1]
            // Chinese counts them all ("等 3 项"), English the rest ("and 1 more").
            default: return String(format: more, items[0], items[1], moreCountsAll ? items.count : items.count - 2)
            }
        }

        init(_ language: String) {
            switch language {
            case "zh":
                then = "，再"; steps = "（共 %d 步）"; wants = "想%@"
                admin = "用管理员权限%@"; files = "文件"; and = "、"
                more = "%@、%@ 等 %d 项"; moreCountsAll = true
                remove = "删掉 %@"; trash = "把 %@ 移到废纸篓"
                move = "移动 %@"; copy = "复制 %@"
                mkdir = "新建文件夹 %@"; touch = "新建文件 %@"
                look = "查看 %@"; listing = "看看文件夹里有什么"
                search = "在文件里搜「%@」"; searching = "在文件里搜东西"
                count = "数一数行数"; edit = "改文件 %@"; text = "整理文字"
                findDelete = "删掉找到的文件"; overwrite = "覆盖写入 %@"; append = "往 %@ 末尾追加内容"
                gitStatus = "看看改了哪些文件"; gitDiff = "看看具体改了什么"
                gitLog = "看提交记录"; gitAdd = "把改动放进暂存"
                gitCommit = "提交改动（存一个版本）"; gitPush = "上传到远端仓库"
                gitPull = "拉取最新代码"; gitBranch = "切换或新建分支"
                gitMerge = "合并分支"; gitReset = "撤回改动"
                gitResetHard = "丢掉还没提交的改动"; gitStash = "把改动先收起来"
                gitClone = "下载一个仓库"; gitClean = "删掉没纳入 git 的文件"
                gitTag = "给版本打标签"; gitInit = "新建一个 git 仓库"
                gitDeleteBranch = "删掉分支 %@"; gitDeleteRemote = "删掉远端的分支 %@"
                gitStashDrop = "丢掉收起来的改动"
                install = "安装依赖包"; test = "跑测试"; build = "构建项目"
                compile = "编译"; serve = "启动开发服务器"; lint = "检查代码"
                runScript = "运行脚本 %@"; runPython = "运行 Python 脚本 %@"
                pythonSnippet = "运行一段 Python"; runProgram = "运行程序"
                installApp = "安装软件 %@"; brew = "管理装好的软件"
                web = "访问 %@"; webAny = "访问网络"; open = "打开 %@"
                osascript = "控制别的应用"; screenshot = "截图"; image = "处理图片"
                video = "处理视频"; readSettings = "读应用设置"; writeSettings = "改应用设置"
                kill = "结束一个程序"; processes = "看看哪些程序在运行"
                permissions = "改文件权限"; archive = "打包或解压文件"
                remote = "连到另一台电脑"; sign = "给 App 签名"
                docker = "运行 Docker 容器"; run = "运行 %@"
            default:
                then = ", then "; steps = " (%d steps)"; wants = "wants to %@"; admin = "%@ as administrator"
                files = "files"; and = " and "; more = "%@, %@ and %d more"; moreCountsAll = false
                remove = "delete %@"; trash = "move %@ to the Trash"; move = "move %@"; copy = "copy %@"
                mkdir = "make the folder %@"; touch = "create %@"; look = "look at %@"; listing = "list a folder"
                search = "search the files for “%@”"; searching = "search the files"; count = "count lines"
                edit = "edit %@"; text = "sort out some text"
                findDelete = "delete the files it finds"; overwrite = "overwrite %@"; append = "append to %@"
                gitStatus = "see which files changed"; gitDiff = "see what changed"; gitLog = "read the commit history"
                gitAdd = "stage the changes"; gitCommit = "commit the changes (save a version)"
                gitPush = "upload to the remote repository"; gitPull = "pull the latest code"
                gitBranch = "switch or create a branch"; gitMerge = "merge branches"; gitReset = "undo changes"
                gitResetHard = "throw away uncommitted changes"; gitStash = "put the changes aside"
                gitClone = "download a repository"; gitClean = "delete files git doesn't track"
                gitTag = "tag a version"; gitInit = "start a git repository"
                gitDeleteBranch = "delete the branch %@"; gitDeleteRemote = "delete %@ on the remote"
                gitStashDrop = "throw away the stashed changes"
                install = "install dependencies"; test = "run the tests"; build = "build the project"; compile = "compile"
                serve = "start the dev server"; lint = "check the code"; runScript = "run the script %@"
                runPython = "run the Python script %@"; pythonSnippet = "run some Python"; runProgram = "run the program"
                installApp = "install %@"; brew = "manage installed software"; web = "fetch %@"; webAny = "go online"
                open = "open %@"; osascript = "control another app"; screenshot = "take a screenshot"
                image = "process images"; video = "process video"; readSettings = "read app settings"
                writeSettings = "change app settings"; kill = "stop a program"; processes = "see what's running"
                permissions = "change file permissions"; archive = "pack or unpack files"
                remote = "connect to another computer"; sign = "sign the app"; docker = "run a Docker container"
                run = "run %@"
            }
        }
    }
}
