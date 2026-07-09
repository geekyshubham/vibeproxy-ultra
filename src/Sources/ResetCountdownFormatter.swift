import Foundation

enum ResetCountdownFormatter {
    /// CodexBar-style compact countdown: "in 3h 12m", "in 45m", "in 2d 4h".
    static func countdown(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "resetting now" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days >= 2 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if days == 1 {
            return hours > 0 ? "in 1d \(hours)h" : "in 1d"
        }
        if hours >= 1 {
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        if minutes >= 1 {
            return "in \(minutes)m"
        }
        return "in <1m"
    }

    /// Full reset line for UI: "Resets in 3h 12m · Tue 4:20 PM"
    static func resetLine(for date: Date, now: Date = Date()) -> String {
        let relative = countdown(until: date, now: now)
        let absolute = absoluteTime(date)
        return "Resets \(relative) · \(absolute)"
    }

    static func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    static func shortUsedRemaining(usedPercent: Double) -> String {
        let used = min(100, max(0, usedPercent))
        let remaining = max(0, 100 - used)
        if used > 0, used < 1 {
            return "<1% used · \(Int(remaining.rounded()))% left"
        }
        return "\(Int(used.rounded()))% used · \(Int(remaining.rounded()))% left"
    }
}
