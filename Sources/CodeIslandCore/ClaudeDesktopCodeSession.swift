import Foundation

/// Claude Code sessions run from Claude Desktop's Code tab.
///
/// Claude Desktop starts each Code-tab session's CLI with its own id for that
/// session in `CLAUDE_CODE_HOST_SESSION_ID` (`local_<uuid>`). The hook's
/// `session_id` is the CLI's id, which Claude Desktop's links do not accept, so
/// this host id is the only handle that reaches one specific session.
public enum ClaudeDesktopCodeSession {
    /// Environment variable Claude Desktop sets on a Code-tab session's CLI.
    public static let hostSessionEnvKey = "CLAUDE_CODE_HOST_SESSION_ID"

    /// Whether `id` has the shape Claude Desktop's URL handler accepts for
    /// `?session=` — `^local_[A-Za-z0-9-]{1,64}$` (verified in the shipped app
    /// bundle, v2.9939). Anything else is refused there, so it is dropped here.
    public static func isValidHostSessionId(_ id: String) -> Bool {
        let prefix = "local_"
        guard id.hasPrefix(prefix) else { return false }
        let body = id.dropFirst(prefix.count)
        guard (1...64).contains(body.count) else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
    }

    /// `claude://code/continue?session=<id>` — Claude Desktop routes this to
    /// that session's screen; its own Dock menu and Spotlight entries use the
    /// same link. Nil for anything that is not a well-formed host id, so a
    /// click never opens a guessed URL.
    public static func deepLinkURL(hostSessionId: String) -> URL? {
        guard isValidHostSessionId(hostSessionId) else { return nil }
        return URL(string: "claude://code/continue?session=\(hostSessionId)")
    }

    /// Claude Desktop keeps one record per Code-tab session at
    /// `claude-code-sessions/<account>/<org>/<host id>.json` in its support
    /// directory. Nil when there is none (or the id is malformed).
    public static func recordPath(hostSessionId: String, supportDirectory: String,
                                  fileManager: FileManager = .default) -> String? {
        guard isValidHostSessionId(hostSessionId) else { return nil }
        let root = (supportDirectory as NSString).appendingPathComponent("claude-code-sessions")
        let file = hostSessionId + ".json"
        for account in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] {
            let accountDir = (root as NSString).appendingPathComponent(account)
            for org in (try? fileManager.contentsOfDirectory(atPath: accountDir)) ?? [] {
                let path = ((accountDir as NSString).appendingPathComponent(org) as NSString).appendingPathComponent(file)
                if fileManager.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    /// The session's name as Claude Desktop's sidebar shows it: the record's
    /// top-level `title`, trimmed; nil when missing or blank.
    public static func title(fromRecord data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["title"] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
