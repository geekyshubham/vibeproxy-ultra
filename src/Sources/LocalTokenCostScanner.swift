import Foundation

enum LocalTokenCostScanner {
    static func codexSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let counts = scanJSONLTokenCounts(in: home, now: now, historyDays: historyDays)
        guard counts.session > 0 || counts.last30Days > 0 else { return nil }
        return ProviderCostSnapshot(
            id: "codex",
            providerID: "codex",
            sessionTokens: counts.session,
            sessionCostUSD: nil,
            last30DaysTokens: counts.last30Days,
            last30DaysCostUSD: nil,
            updatedAt: now
        )
    }

    static func claudeSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let counts = scanJSONLTokenCounts(in: home, now: now, historyDays: historyDays)
        guard counts.session > 0 || counts.last30Days > 0 else { return nil }
        return ProviderCostSnapshot(
            id: "claude",
            providerID: "claude",
            sessionTokens: counts.session,
            sessionCostUSD: nil,
            last30DaysTokens: counts.last30Days,
            last30DaysCostUSD: nil,
            updatedAt: now
        )
    }

    private struct TokenCounts {
        let session: Int
        let last30Days: Int
    }

    private static func scanJSONLTokenCounts(
        in root: URL,
        now: Date,
        historyDays: Int
    ) -> TokenCounts {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return TokenCounts(session: 0, last30Days: 0)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let startOfDay = Calendar.current.startOfDay(for: now)

        var sessionTokens = 0
        var historyTokens = 0

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TokenCounts(session: 0, last30Days: 0)
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate
            else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let content = String(data: data, encoding: .utf8)
            else { continue }

            let lineTokens = content
                .split(whereSeparator: \.isNewline)
                .reduce(0) { partial, line in
                    partial + tokensInJSONLLine(String(line))
                }

            if modified >= startOfDay {
                sessionTokens += lineTokens
            }
            if modified >= cutoff {
                historyTokens += lineTokens
            }
        }

        return TokenCounts(session: sessionTokens, last30Days: historyTokens)
    }

    private static func tokensInJSONLLine(_ line: String) -> Int {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }

        if let usage = json["usage"] as? [String: Any] {
            return intTokenSum(usage)
        }
        if let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any]
        {
            return intTokenSum(usage)
        }
        if let record = json["record"] as? [String: Any],
           let usage = record["usage"] as? [String: Any]
        {
            return intTokenSum(usage)
        }
        return 0
    }

    private static func intTokenSum(_ usage: [String: Any]) -> Int {
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        return input + output + cacheRead + cacheCreate
    }
}