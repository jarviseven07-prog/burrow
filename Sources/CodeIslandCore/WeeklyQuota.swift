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
    /// week says nothing about this week, and neither does one taken before
    /// the weekly reset that has come since (health check #21: with Desktop
    /// closed across a reset, the bar showed last week's red). The file has
    /// no reset time, but the samples show the week starting over — usage
    /// falling back — and the next reset is a whole number of weeks later.
    /// While the next reset may or may not have come, the number stays until
    /// the latest moment it could have.
    public static func claudeRemaining(historyJSON data: Data, now: Date = Date()) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["samples"] as? [[String: Any]] else { return nil }
        let samples = raw.compactMap { s -> (t: TimeInterval, used: Double)? in
            guard let t = number(s["t"]), let used = number((s["u"] as? [String: Any])?["sd"]) else { return nil }
            return (t / 1000, used)
        }.sorted { $0.t < $1.t }
        guard let latest = samples.last else { return nil }
        let week: TimeInterval = 7 * 24 * 3600
        let now = now.timeIntervalSince1970
        guard now - latest.t < week else { return nil }
        if let window = claudeResetWindow(samples) {
            guard now < claudeSampleExpiry(samples, window: window) else { return nil }
        }
        return clamp(100 - latest.used)
    }

    /// When in the week the weekly reset falls, as a window (any week):
    /// it is somewhere from `from` to `from + length`. Each fall in use —
    /// Claude's resets drop to about zero, a dip of a few points is not one —
    /// puts a reset between the sample before and the one after. The weekly
    /// reset keeps its time of the week, so the time most of those spans
    /// share is it, and the window ends where the first of them does; an
    /// early, one-off reset shares it with none. Ties go to the latest reset.
    static func claudeResetWindow(_ samples: [(t: TimeInterval, used: Double)]) -> (from: TimeInterval, length: TimeInterval)? {
        let week: TimeInterval = 7 * 24 * 3600
        var spans: [(from: TimeInterval, length: TimeInterval)] = []
        for i in samples.indices.dropFirst() where samples[i].used < samples[i - 1].used - 5 {
            let length = samples[i].t - samples[i - 1].t
            if length < week { spans.append((samples[i - 1].t, length)) }
        }
        // The shared time starts where one of the spans does.
        var best: (from: TimeInterval, count: Int, length: TimeInterval)?
        for candidate in spans {
            var count = 0, length = candidate.length
            for span in spans {
                let offset = (candidate.from - span.from).truncatingRemainder(dividingBy: week)
                let into = offset < 0 ? offset + week : offset
                if into < span.length {
                    count += 1
                    length = min(length, span.length - into)
                }
            }
            if count >= best?.count ?? 0 { best = (candidate.from, count, length) }
        }
        return best.map { ($0.from, $0.length) }
    }

    /// When the latest sample stops being this week's: at the start of the
    /// next reset window after it; or, taken inside a window, a week on if
    /// the reset already showed in that window, else at the window's end
    /// (review of #21: a sample taken just before a late reset kept last
    /// week's number for a week).
    static func claudeSampleExpiry(_ samples: [(t: TimeInterval, used: Double)],
                                   window: (from: TimeInterval, length: TimeInterval)) -> TimeInterval {
        let week: TimeInterval = 7 * 24 * 3600
        guard let latest = samples.last else { return 0 }
        // The first window that has not ended by the latest sample.
        let k = ((latest.t - window.from - window.length) / week).rounded(.up)
        let start = window.from + k * week, end = start + window.length
        if latest.t <= start { return start }
        let resetSeen = samples.indices.dropFirst().contains { i in
            samples[i].t > start && samples[i].used < samples[i - 1].used - 5
        }
        return resetSeen ? start + week : end
    }

    // MARK: Codex

    /// `account/rateLimits/read`'s result: the window that is a week long
    /// (10080 minutes), usually `secondary`. Never the 5-hour one: a reply
    /// without a week-long window has no bar (health check #18). Only when
    /// the reply gives no lengths at all is `secondary` taken as the week.
    public static func codexRemaining(rateLimitsResult result: [String: Any]) -> Double? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = ["secondary", "primary"].compactMap { limits[$0] as? [String: Any] }
        let weekly = windows.contains { number($0["windowDurationMins"]) != nil }
            ? windows.first { number($0["windowDurationMins"]) == 10080 }
            : limits["secondary"] as? [String: Any]
        guard let used = number(weekly?["usedPercent"]) else { return nil }
        return clamp(100 - used)
    }

    // MARK: Antigravity

    /// Antigravity ACP's `/usage` reply (Markdown): every weekly line, e.g.
    /// "- **Weekly Limit Remaining:** 92% remaining (resets …)" or
    /// "- **Gemini 4 Argon Weekly Limit:** 22% remaining". The pet shows
    /// Argon's.
    public static func antigravityRemaining(usageText text: String) -> Double? {
        antigravityBar(antigravityGroups(usageText: text))
    }

    /// The pet's bar on the notch follows Argon (Jarvis, 11-02); without an
    /// Argon group, the tightest one.
    public static func antigravityBar(_ groups: [Group]) -> Double? {
        groups.first { $0.name == "Argon" }?.remaining ?? groups.map(\.remaining).min()
    }

    /// One of Antigravity's quota groups, as the den lists it.
    public struct Group: Equatable, Sendable {
        /// "Gemini Models", "Argon", "Claude·GPT"; another group keeps its own name.
        public let name: String
        public let remaining: Double
        public init(name: String, remaining: Double) {
            self.name = name
            self.remaining = remaining
        }
    }

    /// Each group's weekly line under its "- **Group**" heading, in the
    /// reply's order.
    public static func antigravityGroups(usageText text: String) -> [Group] {
        var groups: [Group] = []
        var heading = ""
        for line in text.split(separator: "\n") {
            if let match = line.range(of: #"^- \*\*([^*:]+)\*\*\s*$"#, options: .regularExpression) {
                heading = String(line[match]).trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
                continue
            }
            guard line.range(of: "weekly", options: .caseInsensitive) != nil,
                  let match = line.range(of: #"(\d+(?:\.\d+)?)%\s*remaining"#, options: .regularExpression),
                  let number = Double(line[match].prefix { $0.isNumber || $0 == "." }) else { continue }
            groups.append(Group(name: shortGroupName(heading), remaining: clamp(number)))
        }
        return groups
    }

    static func shortGroupName(_ heading: String) -> String {
        let lower = heading.lowercased()
        if lower.contains("argon") { return "Argon" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude·GPT" }
        return heading.isEmpty ? "Antigravity" : heading
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
        return (info?["total_balance"] as? String).flatMap(Double.init) ?? number(info?["total_balance"])
    }

    /// `GET openrouter.ai/api/v1/credits`: bought minus used.
    public static func openRouterBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let total = number(d["total_credits"]),
              let used = number(d["total_usage"]) else { return nil }
        return total - used
    }

    /// OpenCode's two balances as the den shows them: "¥71 · $17".
    public static func balanceLabel(deepSeek: Double?, openRouter: Double?) -> String? {
        let parts = [deepSeek.map { "¥\(Int($0.rounded()))" }, openRouter.map { "$\(Int($0.rounded()))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// OpenCode's bar: the tighter of its two balances against its full.
    public static func openCodeRemaining(deepSeek: Double?, openRouter: Double?) -> Double? {
        let parts = [deepSeek.map { $0 / deepSeekFull * 100 }, openRouter.map { $0 / openRouterFull * 100 }]
            .compactMap { $0 }
        return parts.min().map(clamp)
    }

    // MARK: Lookups over time

    /// What the bar shows for one agent: its percentage, the den's words
    /// for it (OpenCode's balances) and its groups (Antigravity's).
    public struct Reading: Equatable, Sendable {
        public var remaining: Double
        public var label: String?
        public var groups: [Group]
        /// Since when lookups have failed and this reading has stood in.
        public var failingSince: Date?
        public init(remaining: Double, label: String? = nil, groups: [Group] = [], failingSince: Date? = nil) {
            self.remaining = remaining
            self.label = label
            self.groups = groups
            self.failingSince = failingSince
        }
    }

    /// One lookup's outcome. `absent` is a tool not installed, not set up,
    /// or with no data to give (no bar); `failed` is one that is there but
    /// did not answer this time (no network, a timeout).
    public enum Lookup: Equatable, Sendable {
        case found(Reading)
        case absent
        case failed
    }

    /// How long a reading stands in for failing lookups (health check #19).
    public static let failedLookupGrace: TimeInterval = 2 * 3600

    /// The readings after one round of lookups: a failure keeps the last
    /// reading until it has failed for `failedLookupGrace`, counted from the
    /// first failure, so a reading from before a sleep survives the first
    /// lookup after waking. An agent not looked up keeps what it had.
    public static func merge(_ previous: [String: Reading], with lookups: [String: Lookup], now: Date) -> [String: Reading] {
        var next = previous
        for (agent, lookup) in lookups {
            switch lookup {
            case .found(var reading):
                reading.failingSince = nil
                next[agent] = reading
            case .absent:
                next[agent] = nil
            case .failed:
                guard var kept = previous[agent] else { continue }
                let since = kept.failingSince ?? now
                if now.timeIntervalSince(since) >= failedLookupGrace {
                    next[agent] = nil
                } else {
                    kept.failingSince = since
                    next[agent] = kept
                }
            }
        }
        return next
    }

    /// A JSON number, whether it arrived as an integer or not.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    private static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
