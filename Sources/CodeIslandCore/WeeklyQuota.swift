import Foundation

/// How much of each agent's weekly quota is left, as a percentage (design/v24
/// "D"): one long thin bar under each pet, green while healthy, orange when
/// short, red under 15%. Only the weekly window counts, never the 5-hour one.
///
/// Everything here is parsing; fetching lives in the app (QuotaMonitor).
/// Any source that is missing or unreadable just has no bar.
public enum WeeklyQuota {
    /// The bar's colour band.
    public enum Health: Equatable {
        case good, short, critical
    }

    /// Under 30% left is short, under 15% critical (Jarvis: 低于15%就变成红色).
    public static func health(_ remaining: Double) -> Health {
        remaining < 15 ? .critical : remaining < 30 ? .short : .good
    }

    /// Lit cells out of `cells`: at least one while anything is left.
    public static func litCells(_ remaining: Double, of cells: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(cells, max(1, Int((remaining / 100 * Double(cells)).rounded())))
    }

    // MARK: Claude

    /// Claude Desktop's `plan-usage-history.json`: the latest sample's `sd`
    /// is the weekly (all models) percentage used. A sample older than a
    /// week says nothing about this week.
    public static func claudeRemaining(historyJSON data: Data, now: Date = Date()) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        let latest = samples.max { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }
        guard let latest,
              let t = latest["t"] as? Double,
              let used = (latest["u"] as? [String: Any])?["sd"] as? Double else { return nil }
        guard now.timeIntervalSince1970 - t / 1000 < 7 * 24 * 3600 else { return nil }
        return clamp(100 - used)
    }

    // MARK: Codex

    /// `account/rateLimits/read`'s result: the weekly window is `secondary`
    /// (10080 minutes); fall back to whichever window is a week long.
    public static func codexRemaining(rateLimitsResult result: [String: Any]) -> Double? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = ["secondary", "primary"].compactMap { limits[$0] as? [String: Any] }
        let weekly = windows.first { ($0["windowDurationMins"] as? Double) == 10080 } ?? windows.first
        guard let used = weekly?["usedPercent"] as? Double else { return nil }
        return clamp(100 - used)
    }

    // MARK: Antigravity

    /// Antigravity ACP's `/usage` reply (Markdown): every weekly line, e.g.
    /// "- **Weekly Limit Remaining:** 92% remaining (resets …)" or
    /// "- **Gemini 4 Argon Weekly Limit:** 22% remaining". The pet shows
    /// the tightest group.
    public static func antigravityRemaining(usageText text: String) -> Double? {
        var tightest: Double?
        for line in text.split(separator: "\n") where line.range(of: "weekly", options: .caseInsensitive) != nil {
            guard let match = line.range(of: #"(\d+(?:\.\d+)?)%\s*remaining"#, options: .regularExpression),
                  let number = Double(line[match].prefix { $0.isNumber || $0 == "." }) else { continue }
            tightest = min(tightest ?? number, number)
        }
        return tightest.map(clamp)
    }

    // MARK: OpenCode balances

    /// What counts as a full bar for a balance, which has no ceiling of its
    /// own (design/v24: ¥100 on DeepSeek, $20 on OpenRouter).
    public static let deepSeekFull = 100.0
    public static let openRouterFull = 20.0

    /// `GET api.deepseek.com/user/balance`: the CNY balance (or the first one).
    public static func deepSeekBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]] else { return nil }
        let info = infos.first { $0["currency"] as? String == "CNY" } ?? infos.first
        return (info?["total_balance"] as? String).flatMap(Double.init)
            ?? info?["total_balance"] as? Double
    }

    /// `GET openrouter.ai/api/v1/credits`: bought minus used.
    public static func openRouterBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let total = d["total_credits"] as? Double,
              let used = d["total_usage"] as? Double else { return nil }
        return total - used
    }

    /// OpenCode's bar: the tighter of its two balances against its full.
    public static func openCodeRemaining(deepSeek: Double?, openRouter: Double?) -> Double? {
        let parts = [deepSeek.map { $0 / deepSeekFull * 100 }, openRouter.map { $0 / openRouterFull * 100 }]
            .compactMap { $0 }
        return parts.min().map(clamp)
    }

    private static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
