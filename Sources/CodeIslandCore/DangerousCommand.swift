import Foundation

/// Words in a shell command that can't be taken back: the approval card
/// marks them and gives up its filled default button. Kept short on purpose
/// — when everything is red, nothing is.
public enum DangerousCommand {
    public enum Kind: String, CaseIterable, Sendable {
        /// `rm` with both recursive and force flags.
        case remove
        case sudo
        /// `git push --force` / `-f` (not `--force-with-lease`).
        case forcePush
        case resetHard
        /// `git clean -f…`
        case clean
        /// SQL `DROP TABLE / DATABASE / SCHEMA`.
        case drop
        case chmodOpen
    }

    public struct Match: Equatable, Sendable {
        public let kind: Kind
        /// The marked words, as a range of the command.
        public let range: Range<String.Index>
    }

    /// Every dangerous word in `command`, in order.
    public static func matches(in command: String) -> [Match] {
        var out: [Match] = []
        let ns = command as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for (kind, regex, group) in patterns {
            for m in regex.matches(in: command, range: whole) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, let range = Range(r, in: command) else { continue }
                if kind == .remove, !removesRecursivelyByForce(ns.substring(with: m.range(at: 1))) { continue }
                out.append(Match(kind: kind, range: range))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `rm`'s flags ask for both recursive and forced removal.
    static func removesRecursivelyByForce(_ flags: String) -> Bool {
        var recursive = false, force = false
        for flag in flags.split(whereSeparator: \.isWhitespace) {
            if flag == "--recursive" { recursive = true; continue }
            if flag == "--force" { force = true; continue }
            guard flag.hasPrefix("-"), !flag.hasPrefix("--") else { continue }
            if flag.contains("r") || flag.contains("R") { recursive = true }
            if flag.contains("f") { force = true }
        }
        return recursive && force
    }

    /// `git` and the options that may come before its subcommand
    /// (`git -C dir`, `git -c key=value`, `git --no-pager`).
    private static let git = #"\bgit(?:\s+(?:-[Cc]\s+(?:"[^"]*"|'[^']*'|\S+)|--[A-Za-z-]+(?:=\S+)?))*\s+"#

    private static let patterns: [(Kind, NSRegularExpression, Int)] = [
        // The third value is the group that gets marked; `remove` checks its flags in group 1.
        (.remove, #"\brm((?:\s+-{1,2}[A-Za-z-]+)+)"#, 0),
        (.sudo, #"\bsudo\b"#, 0),
        (.forcePush, git + #"push\b[^;&|\n]*?(--force\b(?!-with-lease)|(?<=\s)-f\b)"#, 1),
        // Just the subcommand is red, not a `-C dir` before it.
        (.resetHard, git + #"(reset\s+--hard)\b"#, 1),
        (.clean, git + #"(clean\s+-[A-Za-z]*f[A-Za-z]*)"#, 1),
        (.drop, #"(?i)\bdrop\s+(?:table|database|schema)\b"#, 0),
        (.chmodOpen, #"\bchmod\s+-R\s+777\b"#, 0),
    ].map { kind, pattern, group in
        // The patterns are constants: a typo is a programming error.
        (kind, try! NSRegularExpression(pattern: pattern), group)
    }
}
