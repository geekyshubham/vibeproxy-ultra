import Foundation

struct ModelTokenUsage: Equatable, Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let requestCount: Int
}

extension ProviderCostSnapshot {
    static func make(
        providerID: String,
        sessionTokens: Int,
        sessionCostUSD: Double?,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double?,
        models: [ModelTokenUsage] = [],
        updatedAt: Date? = Date()
    ) -> ProviderCostSnapshot {
        ProviderCostSnapshot(
            id: providerID,
            providerID: providerID,
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            models: models,
            updatedAt: updatedAt
        )
    }
}

/// Scans local CLI session logs (Codex `rollout-*.jsonl`, Claude `projects/**/*.jsonl`, …)
/// to estimate token volume, per-model breakdown, and API-equivalent $ per provider.
///
/// Correctness notes (these were the source of the "wrong info / random models" bug):
/// - Codex stores usage in `payload.info.last_token_usage` (per-turn delta) and
///   `payload.info.total_token_usage` (cumulative). We sum the *deltas* so we never
///   double count, and attribute them to the model from the preceding `turn_context`.
/// - Claude stores per-assistant-message usage in `message.usage` — summing is correct.
/// - Model names are validated so session titles (`slug`), `<synthetic>`, and other
///   junk never appear as "models".
/// - Providers only scan their own log trees (no gemini/antigravity overlap), and files
///   are de-duplicated by resolved path.
enum LocalTokenCostScanner {
    struct ScanRoots {
        let providerID: String
        let directories: [URL]
    }

    static func snapshot(for serviceType: ServiceType, now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let roots = roots(for: serviceType)
        guard !roots.directories.isEmpty else { return nil }
        let detail = scan(providerID: roots.providerID, directories: roots.directories, now: now, historyDays: historyDays)
        guard detail.sessionTokens > 0 || detail.last30DaysTokens > 0 else { return nil }
        return ProviderCostSnapshot.make(
            providerID: roots.providerID,
            sessionTokens: detail.sessionTokens,
            sessionCostUSD: detail.sessionCostUSD,
            last30DaysTokens: detail.last30DaysTokens,
            last30DaysCostUSD: detail.last30DaysCostUSD,
            models: detail.models,
            updatedAt: now
        )
    }

    static func codexSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        snapshot(for: .codex, now: now, historyDays: historyDays)
    }

    static func claudeSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        snapshot(for: .claude, now: now, historyDays: historyDays)
    }

    /// All providers with local logs we know how to scan.
    static func allProviderSnapshots(now: Date = Date(), historyDays: Int = 30) -> [ProviderCostSnapshot] {
        // Only providers whose local log formats we actually understand. Adding the
        // rest just wasted CPU walking empty/foreign trees and risked double counts.
        let types: [ServiceType] = [.codex, .claude, .gemini, .copilot, .antigravity]
        return types.compactMap { snapshot(for: $0, now: now, historyDays: historyDays) }
    }

    // MARK: - Roots

    private static func roots(for serviceType: ServiceType) -> ScanRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch serviceType {
        case .codex:
            return ScanRoots(providerID: "codex", directories: [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ])
        case .claude:
            return ScanRoots(providerID: "claude", directories: [
                home.appendingPathComponent(".claude/projects"),
            ])
        case .gemini:
            return ScanRoots(providerID: "gemini", directories: [
                home.appendingPathComponent(".gemini/tmp"),
                home.appendingPathComponent(".config/gemini"),
            ])
        case .copilot:
            return ScanRoots(providerID: "copilot", directories: [
                home.appendingPathComponent(".copilot"),
                home.appendingPathComponent(".config/github-copilot"),
            ])
        case .antigravity:
            // NOTE: do NOT include ~/.gemini here — it double-counted Gemini usage.
            return ScanRoots(providerID: "antigravity", directories: [
                home.appendingPathComponent(".antigravity"),
            ])
        default:
            return ScanRoots(providerID: serviceType.usageProviderID ?? serviceType.rawValue, directories: [])
        }
    }

    // MARK: - Aggregation types

    private struct AggregateDetail {
        var sessionTokens = 0
        var last30DaysTokens = 0
        var sessionCostUSD = 0.0
        var last30DaysCostUSD = 0.0
        var models: [ModelTokenUsage] = []
    }

    private struct ModelBucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    /// One usage record extracted from a single log line.
    private struct LineUsage {
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let total: Int
        let cost: Double
        let timestamp: Date?
    }

    /// Per-file parsed result, cached by (path, mtime, size) so unchanged files are
    /// never re-parsed. Keeps CPU flat even with large 30-day histories.
    /// Buckets are kept per-day so the 30-day cutoff (and "today") are applied at
    /// aggregation time — the cache stays valid across day boundaries.
    private struct FileAggregate {
        let mtime: Date
        let size: Int
        /// day-start epoch (local) -> (model -> bucket)
        var perDayModels: [Int: [String: ModelBucket]]
    }

    private static let cacheLock = NSLock()
    private static var fileCache: [String: FileAggregate] = [:]

    // MARK: - Scan

    private static func scan(providerID: String, directories: [URL], now: Date, historyDays: Int) -> AggregateDetail {
        let fileManager = FileManager.default
        let cutoff = Calendar.current.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let todayKey = dayKey(for: now)
        let cutoffDay = dayKey(for: cutoff)

        var totalBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0
        var seenPaths = Set<String>()
        var liveKeys = Set<String>()

        for root in directories where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "json" else { continue }

                // De-dup overlapping roots / symlinks.
                let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(canonical).inserted else { continue }

                guard let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let size = values.fileSize ?? 0

                // Skip files last touched before the history window and huge dumps.
                guard modified >= cutoff else { continue }
                if size > 60_000_000 { continue }

                liveKeys.insert(canonical)
                let aggregate = fileAggregate(
                    path: canonical,
                    url: fileURL,
                    providerID: providerID,
                    mtime: modified,
                    size: size,
                    cutoff: cutoff
                )

                // Only count days within the history window; attribute "today" precisely.
                for (day, models) in aggregate.perDayModels where day >= cutoffDay {
                    let isToday = (day == todayKey)
                    for (model, bucket) in models {
                        var merged = totalBuckets[model] ?? ModelBucket()
                        merged.input += bucket.input
                        merged.output += bucket.output
                        merged.cacheRead += bucket.cacheRead
                        merged.total += bucket.total
                        merged.requests += bucket.requests
                        merged.cost += bucket.cost
                        totalBuckets[model] = merged

                        historyTokens += bucket.total
                        historyCost += bucket.cost
                        if isToday {
                            sessionTokens += bucket.total
                            sessionCost += bucket.cost
                        }
                    }
                }
            }
        }

        pruneCache(keeping: liveKeys, roots: directories)

        let models = totalBuckets
            .map { key, bucket in
                ModelTokenUsage(
                    model: key,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    totalTokens: bucket.total,
                    estimatedCostUSD: bucket.cost,
                    requestCount: bucket.requests
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.estimatedCostUSD > rhs.estimatedCostUSD
            }

        return AggregateDetail(
            sessionTokens: sessionTokens,
            last30DaysTokens: historyTokens,
            sessionCostUSD: sessionCost,
            last30DaysCostUSD: historyCost,
            models: models
        )
    }

    private static func fileAggregate(
        path: String,
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        cutoff: Date
    ) -> FileAggregate {
        cacheLock.lock()
        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let parsed = parseFile(url: url, providerID: providerID, mtime: mtime, size: size, cutoff: cutoff)

        cacheLock.lock()
        fileCache[path] = parsed
        cacheLock.unlock()
        return parsed
    }

    private static func parseFile(
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        cutoff: Date
    ) -> FileAggregate {
        var perDayModels: [Int: [String: ModelBucket]] = [:]

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8)
        else {
            return FileAggregate(mtime: mtime, size: size, perDayModels: perDayModels)
        }

        // Track the active model across a Codex session (usage lines carry no model).
        var currentModel = defaultModel(for: providerID)

        for line in content.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard let lineData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let model = trackModel(from: json, providerID: providerID) {
                currentModel = model
            }

            guard let usage = extractUsage(
                from: json,
                providerID: providerID,
                fallbackModel: currentModel
            ) else { continue }

            // Attribute to the day the line happened (falls back to file mtime).
            let day = dayKey(for: usage.timestamp ?? mtime)
            var dayModels = perDayModels[day] ?? [:]
            var bucket = dayModels[usage.model] ?? ModelBucket()
            bucket.input += usage.input
            bucket.output += usage.output
            bucket.cacheRead += usage.cacheRead
            bucket.total += usage.total
            bucket.requests += 1
            bucket.cost += usage.cost
            dayModels[usage.model] = bucket
            perDayModels[day] = dayModels
        }

        return FileAggregate(mtime: mtime, size: size, perDayModels: perDayModels)
    }

    // MARK: - Per-provider extraction

    private static func defaultModel(for providerID: String) -> String {
        switch providerID {
        case "codex": return "gpt-5"
        case "claude": return "claude"
        default: return providerID
        }
    }

    /// Returns a model name if this line *declares* one (turn_context / assistant), else nil.
    private static func trackModel(from json: [String: Any], providerID: String) -> String? {
        switch providerID {
        case "codex":
            // turn_context / session_meta carry the active model under payload.
            if let payload = json["payload"] as? [String: Any] {
                if let model = normalizeModel(stringValue(payload, keys: ["model"])) { return model }
                if let mode = payload["collaboration_mode"] as? [String: Any],
                   let settings = mode["settings"] as? [String: Any],
                   let model = normalizeModel(stringValue(settings, keys: ["model"]))
                {
                    return model
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func extractUsage(
        from json: [String: Any],
        providerID: String,
        fallbackModel: String
    ) -> LineUsage? {
        switch providerID {
        case "codex":
            return extractCodexUsage(from: json, fallbackModel: fallbackModel)
        case "claude":
            return extractClaudeUsage(from: json)
        default:
            return extractGenericUsage(from: json, fallbackModel: fallbackModel)
        }
    }

    /// Codex: `payload.info.last_token_usage` (per-turn delta). We deliberately use the
    /// delta, not the cumulative `total_token_usage`, so multi-turn sessions aren't inflated.
    private static func extractCodexUsage(from json: [String: Any], fallbackModel: String) -> LineUsage? {
        guard (json["type"] as? String) == "event_msg",
              let payload = json["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return nil }

        let usageDict = (info["last_token_usage"] as? [String: Any])
        // Use only the per-turn delta. total_token_usage is cumulative for the whole
        // session, so summing it across token_count events would massively double count.
        guard let usageDict else { return nil }

        let inputTokens = intValue(usageDict, keys: ["input_tokens"])
        let cachedInput = intValue(usageDict, keys: ["cached_input_tokens"])
        let outputTokens = intValue(usageDict, keys: ["output_tokens"])
        var total = intValue(usageDict, keys: ["total_tokens"])
        if total == 0 { total = inputTokens + outputTokens }
        if total == 0 { return nil }

        let rate = TokenPricingCatalog.rate(forModel: fallbackModel)
        let nonCachedInput = max(0, inputTokens - cachedInput)
        let cost = Double(nonCachedInput) / 1_000_000 * rate.inputPerMTok
            + Double(cachedInput) / 1_000_000 * rate.cacheReadPerMTok
            + Double(outputTokens) / 1_000_000 * rate.outputPerMTok

        return LineUsage(
            model: fallbackModel,
            input: inputTokens,
            output: outputTokens,
            cacheRead: cachedInput,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
    }

    /// Claude: per assistant message under `message.usage`.
    private static func extractClaudeUsage(from json: [String: Any]) -> LineUsage? {
        guard (json["type"] as? String) == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = normalizeModel(stringValue(message, keys: ["model"])) ?? "claude"
        // Skip Claude's internal synthetic/interrupt messages.
        guard isPlausibleModel(model) else { return nil }

        let input = intValue(usage, keys: ["input_tokens"])
        let output = intValue(usage, keys: ["output_tokens"])
        let cacheCreate = intValue(usage, keys: ["cache_creation_input_tokens"])
        let cacheRead = intValue(usage, keys: ["cache_read_input_tokens"])
        let total = input + output + cacheCreate + cacheRead
        if total == 0 { return nil }

        let rate = TokenPricingCatalog.rate(forModel: model)
        // Cache creation bills roughly at input price; cache read is heavily discounted.
        let cost = Double(input + cacheCreate) / 1_000_000 * rate.inputPerMTok
            + Double(cacheRead) / 1_000_000 * rate.cacheReadPerMTok
            + Double(output) / 1_000_000 * rate.outputPerMTok

        return LineUsage(
            model: model,
            input: input + cacheCreate,
            output: output,
            cacheRead: cacheRead,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
    }

    /// Best-effort for other providers. Only counts lines with both a usage dict and a
    /// *plausible* model, so session titles / junk never show up as "random models".
    private static func extractGenericUsage(from json: [String: Any], fallbackModel: String) -> LineUsage? {
        guard let usage = genericUsageDict(from: json) else { return nil }
        let model = normalizeModel(extractGenericModel(from: json)) ?? fallbackModel
        guard isPlausibleModel(model) else { return nil }

        let input = intValue(usage, keys: ["input_tokens", "prompt_tokens", "inputTokens", "promptTokens"])
        let output = intValue(usage, keys: ["output_tokens", "completion_tokens", "outputTokens", "completionTokens"])
        let cacheRead = intValue(usage, keys: [
            "cache_read_input_tokens", "cache_read_tokens", "cacheReadInputTokens", "cached_tokens",
        ])
        let cacheCreate = intValue(usage, keys: ["cache_creation_input_tokens", "cache_creation_tokens"])
        let total = input + output + cacheRead + cacheCreate
        if total == 0 { return nil }

        let rate = TokenPricingCatalog.rate(forModel: model)
        let cost = Double(input + cacheCreate) / 1_000_000 * rate.inputPerMTok
            + Double(cacheRead) / 1_000_000 * rate.cacheReadPerMTok
            + Double(output) / 1_000_000 * rate.outputPerMTok

        return LineUsage(
            model: model,
            input: input + cacheCreate,
            output: output,
            cacheRead: cacheRead,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
    }

    private static func genericUsageDict(from json: [String: Any]) -> [String: Any]? {
        if let usage = json["usage"] as? [String: Any] { return usage }
        if let message = json["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
            return usage
        }
        if let response = json["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
            return usage
        }
        if let body = json["body"] as? [String: Any], let usage = body["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private static func extractGenericModel(from json: [String: Any]) -> String? {
        // NOTE: "slug" intentionally excluded — it is a session title in Claude logs and
        // was the main cause of bogus "models" in analytics.
        if let direct = stringValue(json, keys: ["model", "model_name", "modelName"]) { return direct }
        if let message = json["message"] as? [String: Any],
           let m = stringValue(message, keys: ["model", "model_name"]) { return m }
        if let request = json["request"] as? [String: Any],
           let m = stringValue(request, keys: ["model", "model_name"]) { return m }
        return nil
    }

    // MARK: - Model helpers

    private static func normalizeModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Strip provider prefixes like "openai/gpt-4o" or "[Codex] gpt-5".
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return name.isEmpty ? nil : name
    }

    /// Rejects session titles, `<synthetic>`, prose, and other non-model strings.
    private static func isPlausibleModel(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.isEmpty || n == "unknown" { return false }
        if n.hasPrefix("<") { return false }        // <synthetic>
        if n.count > 60 { return false }
        if n.contains(" ") { return false }         // titles / sentences
        let families = [
            "gpt", "o1", "o3", "o4", "codex", "claude", "sonnet", "opus", "haiku",
            "gemini", "grok", "glm", "qwen", "kimi", "moonshot", "deepseek",
            "llama", "mistral", "gemma", "flash", "pro", "command", "nova",
        ]
        return families.contains { n.contains($0) }
    }

    // MARK: - Primitive helpers

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String, !s.isEmpty {
            return isoFormatterWithFraction.date(from: s) ?? isoFormatter.date(from: s)
        }
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        }
        if let ms = value as? Int {
            let d = Double(ms)
            return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
        }
        return nil
    }

    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func intValue(_ dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let v = dict[key] as? Int { return v }
            if let v = dict[key] as? Double { return Int(v) }
            if let v = dict[key] as? String, let i = Int(v) { return i }
        }
        return 0
    }

    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// Drop cache entries for files that no longer exist under the scanned roots,
    /// so the in-memory cache can't grow unbounded over time.
    private static func pruneCache(keeping liveKeys: Set<String>, roots: [URL]) {
        let rootPaths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        fileCache = fileCache.filter { path, _ in
            // Keep entries outside these roots (other providers) untouched.
            let belongsToScan = rootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            return !belongsToScan || liveKeys.contains(path)
        }
    }
}
