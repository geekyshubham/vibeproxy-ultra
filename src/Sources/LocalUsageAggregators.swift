import Foundation
import SQLite3

private func analyticsCutoffStart(now: Date, historyDays: Int) -> Date {
    let lookback = max(0, historyDays - 1)
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
    return Calendar.current.startOfDay(for: cutoffDate)
}

// MARK: - Kiro local credits (session JSON metering)

/// Reads `~/.kiro/sessions/cli/*.json` turn metadata (`metering_usage` credit arrays).
/// The GetUsageLimits API often under-reports free-tier burn; local metering matches kiro-cli.
enum LocalKiroCredits {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, dayCredits: [Int: Double], dayModels: [Int: [String: (credits: Double, requests: Int)]])] = [:]

    /// Credits consumed in sessions updated on/after `since` (inclusive).
    static func creditsUsed(since: Date, now: Date = Date()) -> Double {
        let dayMap = creditByDay(now: now, cutoffStart: Calendar.current.startOfDay(for: since))
        let sinceKey = dayKey(for: since)
        return dayMap.filter { $0.key >= sinceKey }.values.reduce(0, +)
    }

    /// Analytics snapshot from **local session metering** over the rolling `historyDays` window.
    ///
    /// CodexBar convention: `kiro-cli /usage` is **billing-period quota** only (menu bar).
    /// It must not overwrite rolling analytics — a period reset (`creditsUsed == 0`) would zero
    /// history, and mid-period CLI totals are a different time base than last-N-days.
    /// Cost is always API-equivalent `credits × $0.04` (not overage invoice $).
    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit) -> ProviderCostSnapshot? {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let byDay = detailedByDay(now: now, cutoffStart: cutoffStart)
        let today = dayKey(for: now)
        let cutoff = dayKey(for: cutoffStart)

        var modelBuckets: [String: (credits: Double, requests: Int)] = [:]
        var sessionCredits = 0.0
        var historyCredits = 0.0

        for (day, models) in byDay where day >= cutoff {
            for (model, bucket) in models {
                var acc = modelBuckets[model] ?? (0, 0)
                acc.credits += bucket.credits
                acc.requests += bucket.requests
                modelBuckets[model] = acc
                historyCredits += bucket.credits
                if day == today { sessionCredits += bucket.credits }
            }
        }

        guard historyCredits > 0.001 || !modelBuckets.isEmpty else {
            return nil
        }

        let models = modelBuckets.map { model, bucket in
            let credits = bucket.credits
            // Millicredits for sub-credit precision; volumeUnit=.credits keeps them out of token totals.
            let milli = Int((credits * 1000).rounded())
            let cost = max(0, credits) * usdPerCredit
            let displayModel = TokenPricingCatalog.normalizeModelID(model) ?? model
            return ModelTokenUsage(
                model: displayModel,
                inputTokens: milli,
                outputTokens: 0,
                cacheReadTokens: 0,
                totalTokens: milli,
                estimatedCostUSD: cost,
                requestCount: bucket.requests,
                volumeUnit: .credits
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        let historyCost = max(0, historyCredits) * usdPerCredit
        let sessionCost = max(0, sessionCredits) * usdPerCredit

        return ProviderCostSnapshot.make(
            providerID: "kiro",
            sessionTokens: Int((sessionCredits * 1000).rounded()),
            sessionCostUSD: sessionCost,
            last30DaysTokens: Int((historyCredits * 1000).rounded()),
            last30DaysCostUSD: historyCost,
            models: models.isEmpty
                ? [
                    ModelTokenUsage(
                        model: "kiro",
                        inputTokens: Int((historyCredits * 1000).rounded()),
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        totalTokens: Int((historyCredits * 1000).rounded()),
                        estimatedCostUSD: historyCost,
                        requestCount: 1,
                        volumeUnit: .credits
                    )
                ]
                : models,
            volumeUnit: .credits,
            updatedAt: now
        )
    }

    private static func creditByDay(now: Date, cutoffStart: Date) -> [Int: Double] {
        detailedByDay(now: now, cutoffStart: cutoffStart).mapValues { models in
            models.values.reduce(0) { $0 + $1.credits }
        }
    }

    private static func detailedByDay(now: Date, cutoffStart: Date) -> [Int: [String: (credits: Double, requests: Int)]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".kiro/sessions/cli")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }

        var result: [Int: [String: (credits: Double, requests: Int)]] = [:]
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json" else { continue }
            // Skip companion jsonl / nested dirs' non-session files by basename UUID-ish check later.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            guard mtime >= cutoffStart, size > 50, size < 80_000_000 else { continue }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let parsed = parseSessionFile(path: path, url: url, mtime: mtime, size: size)
            for (day, models) in parsed.dayModels {
                var dayMap = result[day] ?? [:]
                for (model, bucket) in models {
                    var acc = dayMap[model] ?? (0, 0)
                    acc.credits += bucket.credits
                    acc.requests += bucket.requests
                    dayMap[model] = acc
                }
                result[day] = dayMap
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()
        return result
    }

    private static func parseSessionFile(
        path: String,
        url: URL,
        mtime: Date,
        size: Int
    ) -> (dayCredits: [Int: Double], dayModels: [Int: [String: (credits: Double, requests: Int)]]) {
        cacheLock.lock()
        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return (cached.dayCredits, cached.dayModels)
        }
        cacheLock.unlock()

        var dayCredits: [Int: Double] = [:]
        var dayModels: [Int: [String: (credits: Double, requests: Int)]] = [:]

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ([:], [:])
        }

        let sessionState = json["session_state"] as? [String: Any]
        let modelInfo = (sessionState?["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        let model = (modelInfo?["model_id"] as? String)
            ?? (modelInfo?["model_name"] as? String)
            ?? "kiro"

        let turns = ((sessionState?["conversation_metadata"] as? [String: Any])?["user_turn_metadatas"] as? [[String: Any]])
            ?? []

        // A resumed/rewritten session has mtime=today but may hold turns from earlier days.
        // Fall back to the session's stable created_at day (written once), NOT the file's
        // rewrite time, so prior-day turns can't spill into "today". Per-turn end_timestamp
        // still wins when present.
        let fallbackDay = (json["created_at"] as? String).flatMap(parseKiroDate).map { dayKey(for: $0) }
            ?? dayKey(for: mtime)
        for turn in turns {
            let credits = sumCredits(turn["metering_usage"])
            guard credits > 0 else { continue }
            let tsDay = resolveTurnDayKey(endTimestamp: turn["end_timestamp"] as? String, fallbackDayKey: fallbackDay)
            dayCredits[tsDay, default: 0] += credits
            var models = dayModels[tsDay] ?? [:]
            var bucket = models[model] ?? (0, 0)
            bucket.credits += credits
            bucket.requests += 1
            models[model] = bucket
            dayModels[tsDay] = models
        }

        cacheLock.lock()
        fileCache[path] = (mtime, size, dayCredits, dayModels)
        cacheLock.unlock()
        return (dayCredits, dayModels)
    }

    private static func sumCredits(_ raw: Any?) -> Double {
        guard let list = raw as? [[String: Any]] else { return 0 }
        var total = 0.0
        for item in list {
            let unit = (item["unit"] as? String)?.lowercased() ?? ""
            guard unit.contains("credit") else { continue }
            if let n = item["value"] as? Double { total += n }
            else if let n = item["value"] as? Int { total += Double(n) }
            else if let n = item["value"] as? NSNumber { total += n.doubleValue }
        }
        return total
    }

    /// Parse a Kiro ISO8601 timestamp (plain or 6-digit fractional microseconds).
    static func parseKiroDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.kiro.date(from: raw) ?? ISO8601DateFormatter.kiroFractional.date(from: raw)
    }

    /// Day bucket for a turn: its own `end_timestamp` when parseable, otherwise the session's
    /// stable fallback day (created_at, never the file's mtime). `internal` for the self-check.
    static func resolveTurnDayKey(endTimestamp: String?, fallbackDayKey: Int) -> Int {
        if let end = endTimestamp, let date = parseKiroDate(end) {
            return dayKey(for: date)
        }
        return fallbackDayKey
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

private extension ISO8601DateFormatter {
    static let kiro: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let kiroFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Grok CLI (signals.json)

enum LocalGrokUsage {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, tokens: Int, cost: Double, model: String, day: Int, requests: Int)] = [:]

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".grok/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let today = dayKey(for: now)
        var modelBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            // Prefer summary.json updated_at/created_at when present so a session whose
            // signals.json wasn't rewritten still lands on the day it was last active.
            let activity = sessionActivityDate(sessionDir: url.deletingLastPathComponent()) ?? mtime
            guard activity >= cutoff || mtime >= cutoff else { continue }
            let size = values.fileSize ?? 0
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)

            let parsed = parseSignals(path: path, url: url, mtime: mtime, activity: activity, size: size)
            guard parsed.tokens > 0 else { continue }

            var bucket = modelBuckets[parsed.model] ?? ModelBucket()
            bucket.total += parsed.tokens
            bucket.input += parsed.tokens
            bucket.cost += parsed.cost
            bucket.requests += parsed.requests
            modelBuckets[parsed.model] = bucket

            historyTokens += parsed.tokens
            historyCost += parsed.cost
            if parsed.day == today {
                sessionTokens += parsed.tokens
                sessionCost += parsed.cost
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()

        guard historyTokens > 0 else { return nil }
        let models = modelBuckets.map { model, b in
            ModelTokenUsage(
                model: model,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cacheRead,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests,
                volumeUnit: .estimatedTokens
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return ProviderCostSnapshot.make(
            providerID: "grok",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: models,
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    private struct ModelBucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    /// Best activity timestamp for a Grok session dir: summary `updated_at` → `created_at` → nil.
    private static func sessionActivityDate(sessionDir: URL) -> Date? {
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let updated = json["updated_at"] as? String, let d = parseGrokDate(updated) { return d }
        if let created = json["created_at"] as? String, let d = parseGrokDate(created) { return d }
        return nil
    }

    private static func parseGrokDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.kiro.date(from: raw) ?? ISO8601DateFormatter.kiroFractional.date(from: raw)
    }

    private static func parseSignals(path: String, url: URL, mtime: Date, activity: Date, size: Int) -> (tokens: Int, cost: Double, model: String, day: Int, requests: Int) {
        // Day = last activity (summary updated_at / signals mtime). Whole-session estimate
        // lands on that day — multi-day split would need per-turn updates.jsonl sums.
        let day = dayKey(for: activity)
        cacheLock.lock()
        if let c = fileCache[path], c.mtime == mtime, c.size == size {
            // Re-bucket when activity day moved but signals body is unchanged.
            if c.day != day {
                fileCache[path] = (mtime, size, c.tokens, c.cost, c.model, day, c.requests)
            }
            cacheLock.unlock()
            return (c.tokens, c.cost, c.model, day, c.requests)
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (0, 0, "grok", day, 0)
        }

        let before = intValue(json["totalTokensBeforeCompaction"])
        let context = intValue(json["contextTokensUsed"])
        let turns = intValue(json["assistantMessageCount"])
        // `contextTokensUsed` is the FINAL context-window occupancy (a snapshot), not tokens
        // consumed; `before + context` therefore severely undercounts an agentic session that
        // re-sends its growing context every turn. Estimate cumulative usage from turn count.
        let tokens = estimatedCumulativeTokens(before: before, context: context, turns: turns)
        // Each assistant message ≈ one API round-trip; the old code hard-coded 1 request/session.
        let requests = max(1, turns)
        let model: String = {
            if let primary = TokenPricingCatalog.normalizeModelID(json["primaryModelId"] as? String) {
                return primary
            }
            if let used = json["modelsUsed"] as? [String] {
                var counts: [String: Int] = [:]
                for m in used {
                    if let n = TokenPricingCatalog.normalizeModelID(m) { counts[n, default: 0] += 1 }
                }
                if let top = counts.max(by: { $0.value < $1.value })?.key { return top }
            }
            return "grok-4.5"
        }()
        // No in/out split in signals — 70/30 on *this* model’s list price.
        let input = Int(Double(tokens) * 0.7)
        let output = tokens - input
        let cost = TokenPricingCatalog.estimateUSD(model: model, inputTokens: input, outputTokens: output)

        cacheLock.lock()
        fileCache[path] = (mtime, size, tokens, cost, model, day, requests)
        cacheLock.unlock()
        return (tokens, cost, model, day, requests)
    }

    /// Estimate cumulative tokens for a Grok session from its final context occupancy and
    /// turn count. Each agentic turn re-sends the whole (growing) context, so cumulative
    /// input ≈ the area under a 0→`context` ramp over `turns` responses, plus any
    /// pre-compaction spans already summed in `before`.
    /// ponytail: triangular-growth heuristic (assumes ~linear context growth, no mid-session
    /// shrink); the exact figure would require summing per-turn deltas from updates.jsonl.
    /// `internal` so the self-check can pin it above the old snapshot floor.
    static func estimatedCumulativeTokens(before: Int, context: Int, turns: Int) -> Int {
        let t = max(1, turns)
        let ramp = Int(Double(max(0, context)) * Double(t + 1) / 2.0)
        return max(0, before + ramp)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        return 0
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

// MARK: - OpenCode (SQLite session table)

enum LocalOpenCodeUsage {
    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/opencode.db"),
        ]
        guard let dbURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let todayStart = Calendar.current.startOfDay(for: now)

        // OpenCode timestamps are epoch MILLISECONDS on current builds; older DBs used seconds.
        // Detect the unit once from the max value rather than the old "retry in seconds when
        // history is empty" heuristic — that heuristic misfired on an idle DB (ms values always
        // clear a seconds-scaled cutoff) and dumped the entire history into "today".
        var maxUpdated: Int64 = 0
        var maxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(time_updated) FROM session;", -1, &maxStmt, nil) == SQLITE_OK {
            if sqlite3_step(maxStmt) == SQLITE_ROW { maxUpdated = sqlite3_column_int64(maxStmt, 0) }
        }
        sqlite3_finalize(maxStmt)
        let scale: Int64 = timeUpdatedIsMilliseconds(maxUpdated) ? 1000 : 1
        let cutoff = Int64(cutoffStart.timeIntervalSince1970) * scale
        let todayStartTs = Int64(todayStart.timeIntervalSince1970) * scale

        let sql = """
        SELECT model, tokens_input, tokens_output, tokens_cache_read, tokens_reasoning,
               cost, time_updated
        FROM session
        WHERE time_updated >= ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        struct Bucket {
            var input = 0
            var output = 0
            var cache = 0
            var total = 0
            var cost = 0.0
            var requests = 0
        }
        var models: [String: Bucket] = [:]
        var historyTokens = 0
        var historyCost = 0.0

        // 30-day history + per-model breakdown come from the cumulative `session` row.
        while sqlite3_step(stmt) == SQLITE_ROW {
            let modelRaw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "{}"
            // OpenCode stores `{"id":"glm-5.2","providerID":"opencode-go"}` - price by id.
            let model = TokenPricingCatalog.normalizeModelID(parseOpenCodeModel(modelRaw))
                ?? parseOpenCodeModel(modelRaw)
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            let cache = Int(sqlite3_column_int64(stmt, 3))
            let reasoning = Int(sqlite3_column_int64(stmt, 4))
            let storedCost = sqlite3_column_double(stmt, 5)

            let total = input + output + cache + reasoning
            guard total > 0 || storedCost > 0 else { continue }

            // Prefer OpenCode's own cost when > 0 (already model-aware); else list-price by model id.
            let cost = storedCost > 0
                ? storedCost
                : TokenPricingCatalog.estimateUSD(
                    model: model,
                    inputTokens: input,
                    outputTokens: output + reasoning,
                    cacheReadTokens: cache
                )

            var bucket = models[model] ?? Bucket()
            bucket.input += input
            bucket.output += output + reasoning
            bucket.cache += cache
            bucket.total += total
            bucket.cost += cost
            bucket.requests += 1
            models[model] = bucket

            historyTokens += total
            historyCost += cost
        }

        // "Today" must come from the per-turn `message` table, not the cumulative session row:
        // a resumed/multi-day session touched today would otherwise dump its whole lifetime
        // total into today's bucket. Falls back to (0,0) on older DBs with no `message` table.
        let (sessionTokens, sessionCost) = openCodeTodayTotals(db: db, todayStartTs: todayStartTs)

        guard historyTokens > 0 || historyCost > 0 else { return nil }

        let modelRows = models.map { name, b in
            ModelTokenUsage(
                model: name,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cache,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return ProviderCostSnapshot.make(
            providerID: "opencode",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: modelRows,
            updatedAt: now
        )
    }

    /// OpenCode stores model as JSON: `{"id":"glm-5.2","providerID":"opencode-go",...}`
    private static func parseOpenCodeModel(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let id = json["id"] as? String, !id.isEmpty {
                let provider = (json["providerID"] as? String) ?? ""
                return provider.isEmpty ? id : "\(provider)/\(id)"
            }
        }
        return raw.isEmpty ? "opencode" : raw
    }

    /// OpenCode changed epoch units across versions: values above ~1e11 are milliseconds
    /// (seconds wouldn't reach that until ~year 5138), below are seconds. `internal` for tests.
    static func timeUpdatedIsMilliseconds(_ maxValue: Int64) -> Bool {
        maxValue > 100_000_000_000
    }

    /// Sum today's assistant-message tokens/cost from the per-turn `message` table (each row's
    /// `data` is a JSON blob with `role`, `tokens{input,output,reasoning,cache{read}}`, `cost`).
    /// Returns (0, 0) when the table/columns are absent (older OpenCode) so callers just show
    /// no "today" rather than mis-attributing a cumulative session total.
    private static func openCodeTodayTotals(db: OpaquePointer, todayStartTs: Int64) -> (tokens: Int, cost: Double) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM message WHERE time_created >= ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return (0, 0)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, todayStartTs)

        var tokens = 0
        var cost = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0),
                  let data = String(cString: c).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "assistant"
            else { continue }
            let tk = json["tokens"] as? [String: Any] ?? [:]
            let cache = tk["cache"] as? [String: Any] ?? [:]
            let input = (tk["input"] as? NSNumber)?.intValue ?? 0
            let output = (tk["output"] as? NSNumber)?.intValue ?? 0
            let reasoning = (tk["reasoning"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (cache["read"] as? NSNumber)?.intValue ?? 0
            tokens += input + output + reasoning + cacheRead
            cost += (json["cost"] as? NSNumber)?.doubleValue ?? 0
        }
        return (tokens, cost)
    }
}

// MARK: - GitHub Copilot (JB panel transcripts — token estimate from message text)

enum LocalCopilotUsage {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, requests: Int, days: [Int: Int])] = [:]
    /// Skip pathological multi‑MB transcripts (still count via cache once parsed).
    private static let maxFileBytes = 8_000_000

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/jb")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let today = dayKey(for: now)
        var sessionTokens = 0
        var historyTokens = 0
        var requests = 0
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate, mtime >= cutoff
            else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileBytes else { continue }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let parsed = parseFile(path: path, url: url, mtime: mtime, size: size)
            let fileTokens = parsed.days.values.reduce(0, +)
            guard fileTokens > 0 else { continue }
            historyTokens += fileTokens
            requests += parsed.requests
            sessionTokens += parsed.days[today] ?? 0
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()

        guard historyTokens > 0 else { return nil }
        // Copilot subscription — estimate mid-tier chat pricing for API-equivalent.
        let cost = TokenPricingCatalog.estimateUSD(
            model: "gpt-4o",
            inputTokens: Int(Double(historyTokens) * 0.6),
            outputTokens: Int(Double(historyTokens) * 0.4)
        )
        let sessionCost = historyTokens > 0
            ? cost * (Double(sessionTokens) / Double(historyTokens))
            : 0

        return ProviderCostSnapshot.make(
            providerID: "copilot",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: cost,
            models: [
                ModelTokenUsage(
                    model: "github-copilot (est.)",
                    inputTokens: Int(Double(historyTokens) * 0.6),
                    outputTokens: Int(Double(historyTokens) * 0.4),
                    cacheReadTokens: 0,
                    totalTokens: historyTokens,
                    estimatedCostUSD: cost,
                    requestCount: requests,
                    volumeUnit: .estimatedTokens
                )
            ],
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    private static func parseFile(path: String, url: URL, mtime: Date, size: Int) -> (requests: Int, days: [Int: Int]) {
        cacheLock.lock()
        if let c = fileCache[path], c.mtime == mtime, c.size == size {
            cacheLock.unlock()
            return (c.requests, c.days)
        }
        cacheLock.unlock()

        let mtimeDay = dayKey(for: mtime)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (0, [:])
        }
        var days: [Int: Int] = [:]
        var requests = 0
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            guard type == "assistant.message" || type == "user.message" else { continue }
            let text = copilotText(from: json["data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // ~4 chars/token rough estimate when Copilot doesn't log usage.
            let tokens = max(1, Int((Double(text.utf8.count) / 4.0).rounded(.up)))
            // Bucket by the message's OWN timestamp; an append-only transcript reopened today
            // must not retag its whole history as "today" (the old file-mtime bug).
            let day = copilotDayKey(timestamp: json["timestamp"] as? String, fallbackDayKey: mtimeDay)
            days[day, default: 0] += tokens
            requests += 1
        }

        cacheLock.lock()
        fileCache[path] = (mtime, size, requests, days)
        cacheLock.unlock()
        return (requests, days)
    }

    private static let copilotISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Day bucket for a Copilot message: its own ISO8601 `timestamp` when present, else the
    /// file mtime day. `internal` for the self-check.
    static func copilotDayKey(timestamp: String?, fallbackDayKey: Int) -> Int {
        if let ts = timestamp, let date = copilotISO.date(from: ts) {
            return dayKey(for: date)
        }
        return fallbackDayKey
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func copilotText(from raw: Any?) -> String {
        guard let data = raw as? [String: Any] else { return "" }
        if let content = data["content"] as? String { return content }
        if let text = data["text"] as? String { return text }
        if let parts = data["content"] as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined(separator: "\n")
        }
        return ""
    }
}
