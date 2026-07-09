import Foundation

/// Billing/volume unit for analytics rows. Token-like units may be summed together;
/// credit units stay separate so Kiro millicredits never inflate "token" totals.
enum UsageVolumeUnit: String, Equatable {
    /// Real token counts from CLI session logs.
    case tokens
    /// Kiro plan credits stored as millicredits (credits × 1000) for sub-credit precision.
    case credits
    /// Rough char/4 (or similar) estimates — still token-like for aggregation.
    case estimatedTokens

    /// Whether this unit may contribute to global token volume totals.
    var aggregatesAsTokens: Bool {
        switch self {
        case .tokens, .estimatedTokens: return true
        case .credits: return false
        }
    }
}

struct ModelTokenUsage: Equatable, Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    /// Volume in `volumeUnit` (tokens, millicredits, or estimated tokens).
    let totalTokens: Int
    let estimatedCostUSD: Double
    let requestCount: Int
    let volumeUnit: UsageVolumeUnit

    init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        estimatedCostUSD: Double,
        requestCount: Int,
        volumeUnit: UsageVolumeUnit = .tokens
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.requestCount = requestCount
        self.volumeUnit = volumeUnit
    }
}

extension ProviderCostSnapshot {
    static func make(
        providerID: String,
        sessionTokens: Int,
        sessionCostUSD: Double?,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double?,
        models: [ModelTokenUsage] = [],
        volumeUnit: UsageVolumeUnit = .tokens,
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
            volumeUnit: volumeUnit,
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
        var results: [ProviderCostSnapshot] = []

        // Classic CLI jsonl trees
        let jsonlTypes: [ServiceType] = [.codex, .claude, .gemini, .antigravity]
        results.append(contentsOf: jsonlTypes.compactMap { snapshot(for: $0, now: now, historyDays: historyDays) })

        // Specialized aggregators (Kiro session JSON, Grok signals, OpenCode SQLite, Copilot JB logs)
        if let kiro = LocalKiroCredits.costSnapshot(now: now, historyDays: historyDays) {
            results.append(kiro)
        }
        if let grok = LocalGrokUsage.costSnapshot(now: now, historyDays: historyDays) {
            results.append(grok)
        }
        if let opencode = LocalOpenCodeUsage.costSnapshot(now: now, historyDays: historyDays) {
            results.append(opencode)
        }
        // Prefer specialized Copilot estimate when present; else fall back to generic tree scan.
        if let copilot = LocalCopilotUsage.costSnapshot(now: now, historyDays: historyDays) {
            results.append(copilot)
        } else if let copilot = snapshot(for: .copilot, now: now, historyDays: historyDays) {
            results.append(copilot)
        }

        return results
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
            // Claude Code docs: CLAUDE_CONFIG_DIR relocates ~/.claude (including projects/).
            // Also scan legacy defaults and de-dupe resolved paths.
            var claudeDirs: [URL] = [
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects"),
            ]
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !configDir.isEmpty
            {
                claudeDirs.insert(
                    URL(fileURLWithPath: configDir, isDirectory: true)
                        .appendingPathComponent("projects"),
                    at: 0
                )
            }
            var seen = Set<String>()
            let unique = claudeDirs.filter { url in
                let key = url.standardizedFileURL.resolvingSymlinksInPath().path
                return seen.insert(key).inserted
            }
            return ScanRoots(providerID: "claude", directories: unique)
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
        // CodexBar: rolling window is inclusive — 30-day display starts 29 days before now.
        let lookback = max(0, historyDays - 1)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
        let cutoff = Calendar.current.startOfDay(for: cutoffDate)
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
        case "codex": return "gpt-5.4" // current default family in local sessions
        case "claude": return "claude-sonnet-4"
        default: return providerID
        }
    }

    /// Returns a model name if this line *declares* one (turn_context / assistant), else nil.
    /// CodexBar: model lives on turn_context / session_meta; token_count lines use the last seen model.
    private static func trackModel(from json: [String: Any], providerID: String) -> String? {
        switch providerID {
        case "codex":
            let type = json["type"] as? String
            if let payload = json["payload"] as? [String: Any] {
                // session_meta / turn_context payload.model
                if let model = normalizeModel(stringValue(payload, keys: ["model", "model_name"])) {
                    return model
                }
                if let mode = payload["collaboration_mode"] as? [String: Any],
                   let settings = mode["settings"] as? [String: Any],
                   let model = normalizeModel(stringValue(settings, keys: ["model"]))
                {
                    return model
                }
                // Some builds nest model under info
                if let info = payload["info"] as? [String: Any],
                   let model = normalizeModel(stringValue(info, keys: ["model"]))
                {
                    return model
                }
            }
            // Top-level model on turn_context events
            if type == "turn_context" || type == "session_meta",
               let model = normalizeModel(stringValue(json, keys: ["model"]))
            {
                return model
            }
            return nil
        case "claude":
            // Prefer explicit assistant model for sticky fallback
            if (json["type"] as? String) == "assistant",
               let message = json["message"] as? [String: Any],
               let model = normalizeModel(stringValue(message, keys: ["model"]))
            {
                return model
            }
            return nil
        default:
            return normalizeModel(extractGenericModel(from: json))
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

        // Prefer model stamped on this event if present; else sticky turn_context model.
        let model = normalizeModel(stringValue(payload, keys: ["model"]))
            ?? normalizeModel(stringValue(info, keys: ["model"]))
            ?? fallbackModel
        let nonCachedInput = max(0, inputTokens - cachedInput)
        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: nonCachedInput,
            outputTokens: outputTokens,
            cacheReadTokens: cachedInput
        )

        return LineUsage(
            model: model,
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
        // Skip Claude's internal synthetic/interrupt messages (<synthetic>).
        guard isPlausibleModel(model) else { return nil }

        let input = intValue(usage, keys: ["input_tokens"])
        let output = intValue(usage, keys: ["output_tokens"])
        let cacheCreate = intValue(usage, keys: ["cache_creation_input_tokens"])
        let cacheRead = intValue(usage, keys: ["cache_read_input_tokens"])
        let total = input + output + cacheCreate + cacheRead
        if total == 0 { return nil }

        // CodexBar: cache write = cacheCreation rate (≈1.25× input); cache read discounted.
        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheCreate
        )

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

        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheCreate
        )

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
        TokenPricingCatalog.normalizeModelID(raw)
    }

    /// Rejects session titles, `<synthetic>`, prose, and other non-model strings.
    private static func isPlausibleModel(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.isEmpty || n == "unknown" { return false }
        if n.hasPrefix("<") { return false }        // <synthetic>
        if n.count > 80 { return false }
        if n.contains(" ") { return false }         // titles / sentences
        let families = [
            "gpt", "o1", "o3", "o4", "codex", "claude", "sonnet", "opus", "haiku",
            "gemini", "grok", "glm", "qwen", "kimi", "moonshot", "deepseek",
            "llama", "mistral", "gemma", "flash", "pro", "command", "nova",
            "kiro", "copilot", "opencode", "auto",
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
            if let v = dict[key] as? NSNumber { return v.intValue }
            if let v = dict[key] as? String, let i = Int(v) { return i }
            if let v = dict[key] as? String, let d = Double(v) { return Int(d) }
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
