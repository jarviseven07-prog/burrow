import Foundation

public enum EventNormalizer {
    /// Normalize event names to internal PascalCase names. Claude Code, Codex,
    /// OpenCode and Google Antigravity already send them; only a turn that
    /// ends on an API error has its own spelling, and it is still terminal for
    /// the island, so it folds onto Stop.
    public static func normalize(_ name: String) -> String {
        switch name {
        case "stop_failure", "StopFailure": return "Stop"
        default:                            return name
        }
    }
}
