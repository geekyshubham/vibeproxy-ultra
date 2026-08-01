import Foundation

/// Date-indexed usage types shared by the menu bar panel and the management console.
///
/// Why a separate day model at all: every local aggregator already buckets by
/// `Calendar.current.startOfDay` internally, then throws the per-day detail away and
/// publishes only "today" + "last 30 days" totals (see `LocalTokenCostScanner.scan`
/// and `LocalKiroCredits.costSnapshot`). Answering "what did I use on 12 July" needs
/// that detail kept, and kept across restarts.
///
/// Day keys are `yyyy-MM-dd` strings in the user's current calendar, not epochs.
/// The in-memory scanners key days by local `startOfDay` epoch, which silently shifts
/// if the machine changes timezone — fine for a value recomputed every scan, wrong for
/// something written to disk and re-read months later. ccusage stores date-key strings
/// for the same reason.
struct UsageDayKey: Hashable, Codable, Comparable, CustomStringConvertible {
    let value: String

    init(value: String) {
        self.value = value
    }

    init(date: Date, calendar: Calendar = .current) {
        self.value = UsageDayKey.formatter(for: calendar).string(from: date)
    }

    /// Local start-of-day epoch, matching the key the scanners bucket by.
    init(epoch: Int, calendar: Calendar = .current) {
        self.init(date: Date(timeIntervalSince1970: TimeInterval(epoch)), calendar: calendar)
    }

    func date(calendar: Calendar = .current) -> Date? {
        UsageDayKey.formatter(for: calendar).date(from: value)
    }

    var description: String { value }

    static func < (lhs: UsageDayKey, rhs: UsageDayKey) -> Bool {
        lhs.value < rhs.value
    }

    /// Fixed-format and locale-independent: a user in a non-Gregorian locale must not
    /// get day keys that fail to round-trip.
    private static func formatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// One model's usage on one day for one provider.
struct DailyModelUsage: Codable, Equatable {
    let model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    /// Volume in `volumeUnit` (tokens, millicredits, or estimated tokens).
    var totalVolume: Int
    var estimatedCostUSD: Double
    var requestCount: Int
    let volumeUnit: UsageVolumeUnit

    mutating func merge(_ other: DailyModelUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        totalVolume += other.totalVolume
        estimatedCostUSD += other.estimatedCostUSD
        requestCount += other.requestCount
    }
}

/// How precisely a provider's usage can be attributed to a specific calendar day.
///
/// Not cosmetic: Grok pins a whole session's estimate to its last-activity day
/// ("multi-day split would need per-turn updates.jsonl sums" — LocalUsageAggregators),
/// and Copilot's file cache keeps only `days: [Int: Int]` with no model dimension.
/// Presenting those as exact per-day figures next to Codex/Claude would be dishonest.
enum DailyUsageFidelity: String, Codable, Equatable {
    /// Per-event timestamps bucketed per day, with a real per-model split.
    case exact
    /// Correct day totals, but no trustworthy per-model split for that day.
    case dayTotalsOnly
    /// A whole session's volume attributed to a single day; multi-day sessions smear.
    case sessionApproximate

    var isApproximate: Bool { self != .exact }

    /// Short UI note, or nil when the number needs no caveat.
    var caveat: String? {
        switch self {
        case .exact: return nil
        case .dayTotalsOnly: return "day total only — no per-model split"
        case .sessionApproximate: return "approximate — whole sessions land on one day"
        }
    }
}

/// One provider's usage on one day.
struct DailyProviderUsage: Codable, Equatable {
    let providerID: String
    var models: [DailyModelUsage]
    let volumeUnit: UsageVolumeUnit
    let fidelity: DailyUsageFidelity

    var totalVolume: Int { models.reduce(0) { $0 + $1.totalVolume } }
    var totalCostUSD: Double { models.reduce(0) { $0 + $1.estimatedCostUSD } }
    var requestCount: Int { models.reduce(0) { $0 + $1.requestCount } }

    /// Volume that may be summed into a cross-provider token total.
    var tokenLikeVolume: Int { volumeUnit.aggregatesAsTokens ? totalVolume : 0 }
}

/// Everything the UI needs to answer "what did I use on this date".
struct DailyUsageSummary: Codable, Equatable {
    let day: UsageDayKey
    let providers: [DailyProviderUsage]

    /// Sum of token-like volume only. Kiro millicredits are deliberately excluded —
    /// adding them to tokens would inflate the total by ~1000× per credit.
    var totalTokens: Int { providers.reduce(0) { $0 + $1.tokenLikeVolume } }

    /// Costs are commensurable across every unit, so this total is always meaningful.
    var totalCostUSD: Double { providers.reduce(0) { $0 + $1.totalCostUSD } }

    var totalRequests: Int { providers.reduce(0) { $0 + $1.requestCount } }

    var isEmpty: Bool { providers.allSatisfy { $0.models.isEmpty } }

    /// Providers ranked by API-equivalent cost.
    ///
    /// Cost is the ONLY defensible basis for "which provider did I use most": ranking
    /// Kiro's millicredits against Codex's tokens compares unlike units, and every
    /// aggregator populates `estimatedCostUSD` (Kiro as credits × $0.04 API-equivalent).
    /// Ties break on volume within a unit, then provider ID for a stable order.
    var providersByCost: [DailyProviderUsage] {
        providers
            .filter { !$0.models.isEmpty }
            .sorted {
                if $0.totalCostUSD != $1.totalCostUSD { return $0.totalCostUSD > $1.totalCostUSD }
                if $0.volumeUnit == $1.volumeUnit, $0.totalVolume != $1.totalVolume {
                    return $0.totalVolume > $1.totalVolume
                }
                return $0.providerID < $1.providerID
            }
    }

    /// The provider used most that day, by cost.
    var topProvider: DailyProviderUsage? { providersByCost.first }

    /// Share of the day's total cost attributable to `topProvider`, 0...1.
    /// Nil when the day has no cost signal, so callers show volume instead of a bogus 0%.
    var topProviderCostShare: Double? {
        guard let top = topProvider, totalCostUSD > 0 else { return nil }
        return top.totalCostUSD / totalCostUSD
    }

    /// Models across all providers, ranked by cost then volume.
    /// Credit-unit rows keep their own identity so they never merge with token rows
    /// of the same name (mirrors the merge-key logic in `AnalyticsEngine.overview`).
    var modelsByCost: [(providerID: String, usage: DailyModelUsage)] {
        providers
            .flatMap { provider in provider.models.map { (provider.providerID, $0) } }
            .sorted {
                if $0.1.estimatedCostUSD != $1.1.estimatedCostUSD {
                    return $0.1.estimatedCostUSD > $1.1.estimatedCostUSD
                }
                if $0.1.volumeUnit == $1.1.volumeUnit, $0.1.totalVolume != $1.1.totalVolume {
                    return $0.1.totalVolume > $1.1.totalVolume
                }
                return $0.1.model < $1.1.model
            }
            .map { (providerID: $0.0, usage: $0.1) }
    }

    /// True when any contributing provider can only place usage on a day approximately.
    var hasApproximateData: Bool {
        providers.contains { !$0.models.isEmpty && $0.fidelity.isApproximate }
    }

    static func empty(day: UsageDayKey) -> DailyUsageSummary {
        DailyUsageSummary(day: day, providers: [])
    }
}
