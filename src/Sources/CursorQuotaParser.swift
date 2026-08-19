import Foundation

/// Maps Cursor `/api/usage-summary` JSON into quota windows.
///
/// Cursor's `*PercentUsed` fields are **percent remaining**, not percent used
/// (a barely-used free plan reports `totalPercentUsed ≈ 94`). Treating them as
/// used made a burnt-down plan look like 0% usage. Prefer `used`/`limit` cents
/// when present; otherwise invert the remaining-percent fields.
enum CursorQuotaParser {
    static func windows(from json: [String: Any], billingCycleEnd: Date? = nil) -> [RateWindow] {
        let reset = billingCycleEnd
            ?? parseDate(json["billingCycleEnd"] as? String)
            ?? parseDate(json["billing_cycle_end"] as? String)
        let resetLine = reset.map { ResetCountdownFormatter.resetLine(for: $0) }

        let individual = json["individualUsage"] as? [String: Any]
            ?? json["individual_usage"] as? [String: Any]
        let team = json["teamUsage"] as? [String: Any]
            ?? json["team_usage"] as? [String: Any]
        let plan = (individual?["plan"] as? [String: Any])
            ?? (json["planUsage"] as? [String: Any])
            ?? (json["plan_usage"] as? [String: Any])
        let overall = individual?["overall"] as? [String: Any]
        let onDemand = (individual?["onDemand"] as? [String: Any])
            ?? (individual?["on_demand"] as? [String: Any])
        let teamOnDemand = (team?["onDemand"] as? [String: Any])
            ?? (team?["on_demand"] as? [String: Any])
        let pooled = (team?["pooled"] as? [String: Any])

        var windows: [RateWindow] = []

        if let window = window(
            from: plan ?? overall,
            percentKeys: ["totalPercentUsed", "total_percent_used"],
            label: "Total Usage",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if let window = window(
            from: plan,
            percentKeys: ["autoPercentUsed", "auto_percent_used"],
            label: "Auto + Composer",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if let window = window(
            from: plan,
            percentKeys: ["apiPercentUsed", "api_percent_used"],
            label: "API Usage",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if windows.isEmpty, let window = window(
            from: pooled,
            percentKeys: ["totalPercentUsed", "total_percent_used"],
            label: "Team Pool",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }

        let odSource: [String: Any]? = {
            if let onDemand, (onDemand["enabled"] as? Bool) != false {
                return onDemand
            }
            return teamOnDemand
        }()
        if let window = window(
            from: odSource,
            percentKeys: ["onDemandPercentUsed", "on_demand_percent_used"],
            label: "On-Demand",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }

        return windows
    }

    /// `usedPercent` in 0...100. Prefers cents `used`/`limit`; otherwise inverts remaining %.
    static func usedPercent(from object: [String: Any]?, remainingPercentKeys: [String]) -> Double? {
        guard let object else { return nil }
        if let used = number(object, keys: ["used", "totalSpend", "total_spend", "includedSpend"]),
           let limit = number(object, keys: ["limit", "total"]),
           limit > 0
        {
            return min(100, max(0, used / limit * 100))
        }
        for key in remainingPercentKeys {
            if let remaining = number(object, keys: [key]) {
                let pct = remaining <= 1 ? remaining * 100 : remaining
                if pct >= 0, pct <= 100 {
                    return min(100, max(0, 100 - pct))
                }
            }
        }
        return nil
    }

    private static func window(
        from object: [String: Any]?,
        percentKeys: [String],
        label: String,
        resetsAt: Date?,
        resetDescription: String?
    ) -> RateWindow? {
        guard let used = usedPercent(from: object, remainingPercentKeys: percentKeys) else {
            return nil
        }
        let remaining = number(object ?? [:], keys: ["remaining"])
        let total = number(object ?? [:], keys: ["limit", "total"])
        return RateWindow(
            usedPercent: used,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            label: label,
            remainingValue: remaining,
            totalValue: total,
            unitLabel: (remaining != nil || total != nil) ? "incl." : nil,
            displayStyle: .percent
        )
    }

    private static func number(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
