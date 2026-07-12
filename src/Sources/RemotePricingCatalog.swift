import Foundation

/// Live, auto-updating model list-prices so cost estimates track real pricing instead of a
/// frozen table. Source: **models.dev** (`https://models.dev/api.json`) — the same community
/// feed OpenCode uses. Per-provider JSON with `cost: { input, output, cache_read }` in $/1M tok.
///
/// Precedence: a remote rate (when present) wins in `TokenPricingCatalog.rate(forModel:)`;
/// the built-in static rules remain the offline / unknown-model fallback so the app never
/// shows $0 due to a network failure or a model the feed doesn't list.
///
/// Robustness:
/// - Disk cache (Application Support) is loaded synchronously at launch, so rates are ready
///   before the first cost scan even while a fresh fetch is in flight.
/// - Native provider pricing is preferred over resellers/aggregators for the same model id.
/// - models.dev omits cache-write pricing; Anthropic writes cost 1.25× input (verified
///   convention), so we derive it for claude families to keep cache math accurate.
enum RemotePricingCatalog {
    static let sourceURL = URL(string: "https://models.dev/api.json")!
    /// Refresh at most once per day; the disk cache bridges restarts.
    private static let ttl: TimeInterval = 24 * 3600

    private static let lock = NSLock()
    private static var rates: [String: TokenPricingCatalog.Rate] = [:]
    private static var fetchedAt: Date?

    // MARK: - Lookup (called from TokenPricingCatalog.rate on scan threads)

    /// Live rate for a normalized+dashed model key (e.g. "gpt-5-4", "claude-opus-4-8"), or nil.
    static func rate(forDashedID dashed: String) -> TokenPricingCatalog.Rate? {
        lock.lock(); defer { lock.unlock() }
        return rates[dashed]
    }

    static var lastUpdated: Date? { lock.lock(); defer { lock.unlock() }; return fetchedAt }
    static var modelCount: Int { lock.lock(); defer { lock.unlock() }; return rates.count }

    /// Test hook: inject a rate table to verify remote-overrides-static wiring without a network
    /// fetch. Not used in production paths.
    static func replaceRatesForTesting(_ injected: [String: TokenPricingCatalog.Rate]) {
        lock.lock(); rates = injected; fetchedAt = Date(); lock.unlock()
    }

    // MARK: - Lifecycle

    /// Load the disk cache immediately (cheap) so prices are available at launch, then kick off
    /// a background refresh when stale. Call once from `applicationDidFinishLaunching`.
    static func bootstrap() {
        loadDiskCache()
        Task.detached(priority: .utility) { await refreshIfStale() }
    }

    /// Fetch only when the cache is empty or older than the TTL. Safe to call frequently
    /// (e.g. before each analytics scan) — it short-circuits when fresh.
    static func refreshIfStale() async {
        let state = snapshot()
        let age = state.fetchedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if state.count > 0, age < ttl { return }
        await refresh()
    }

    /// Force a fetch (respecting the user's auto-update toggle).
    static func refresh() async {
        guard AppSettings.shared.autoUpdatePricing else { return }
        var request = URLRequest(url: sourceURL, timeoutInterval: 25)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let parsed = parse(data)
            guard !parsed.isEmpty else { return } // never clobber a good cache with garbage
            let now = Date()
            store(parsed, at: now)
            writeDiskCache(rates: parsed, at: now)
        } catch {
            // Offline / transient: keep the existing cache (or static fallback). No throw.
        }
    }

    // Synchronous locked accessors keep NSLock off the async call-path (Swift 6 safe).
    private static func snapshot() -> (count: Int, fetchedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (rates.count, fetchedAt)
    }

    private static func store(_ newRates: [String: TokenPricingCatalog.Rate], at date: Date) {
        lock.lock(); rates = newRates; fetchedAt = date; lock.unlock()
    }

    // MARK: - Parse models.dev

    /// Parse the models.dev payload into normalized rate keys. Prefers native providers over
    /// resellers so a marked-up mirror never shadows the canonical list price.
    static func parse(_ data: Data) -> [String: TokenPricingCatalog.Rate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: TokenPricingCatalog.Rate] = [:]
        var rankForKey: [String: Int] = [:]

        for (providerID, providerValue) in root {
            guard let provider = providerValue as? [String: Any],
                  let models = provider["models"] as? [String: Any]
            else { continue }
            let rank = providerRank(providerID)

            for (modelID, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = number(cost["input"]),
                      let output = number(cost["output"]),
                      let key = TokenPricingCatalog.dashedKey(modelID)
                else { continue }
                // Skip free/coding-plan $0 rows so they never clobber a real list price
                // (e.g. zai-coding-plan glm-5.2 at 0/0 vs zai at $1.40/$4.40).
                guard input > 0 || output > 0 else { continue }
                // Keep the highest-ranked provider's price for a given model id.
                if let existing = rankForKey[key], existing >= rank { continue }

                let cacheRead = number(cost["cache_read"]) ?? input * 0.1
                // Prefer the feed's cache_write when present; models.dev now ships it for
                // OpenAI/Anthropic. Derive Anthropic 1.25× input only when the field is absent.
                let cacheWrite: Double? = number(cost["cache_write"])
                    ?? (isAnthropicKey(key) ? input * 1.25 : nil)

                out[key] = TokenPricingCatalog.Rate(
                    inputPerMTok: input,
                    outputPerMTok: output,
                    cacheReadPerMTok: cacheRead,
                    cacheWritePerMTok: cacheWrite
                )
                rankForKey[key] = rank
            }
        }
        return out
    }

    private static func isAnthropicKey(_ key: String) -> Bool {
        key.contains("claude") || key.contains("opus") || key.contains("sonnet") || key.contains("haiku")
    }

    /// Native model owners outrank clouds/resellers, which outrank everything else.
    private static func providerRank(_ id: String) -> Int {
        let native: Set<String> = [
            "openai", "anthropic", "google", "xai", "deepseek", "zai", "z-ai", "zhipuai",
            "moonshotai", "alibaba", "meta", "meta-llama", "mistral", "cohere",
        ]
        if native.contains(id) { return 100 }
        let trusted: Set<String> = [
            "google-vertex", "google-vertex-anthropic", "amazon-bedrock", "azure",
            "vercel", "openrouter", "requesty", "fireworks-ai", "together-ai", "deepinfra",
        ]
        if trusted.contains(id) { return 50 }
        return 10
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: - Disk cache

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("VibeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pricing-cache.json")
    }

    private static func writeDiskCache(rates: [String: TokenPricingCatalog.Rate], at date: Date) {
        guard let url = cacheURL else { return }
        var serialized: [String: [String: Double]] = [:]
        for (key, rate) in rates {
            var r: [String: Double] = [
                "in": rate.inputPerMTok, "out": rate.outputPerMTok, "cr": rate.cacheReadPerMTok,
            ]
            if let cw = rate.cacheWritePerMTok { r["cw"] = cw }
            serialized[key] = r
        }
        let payload: [String: Any] = ["fetchedAt": date.timeIntervalSince1970, "rates": serialized]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadDiskCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serialized = root["rates"] as? [String: [String: Double]]
        else { return }
        var loaded: [String: TokenPricingCatalog.Rate] = [:]
        for (key, r) in serialized {
            guard let input = r["in"], let output = r["out"] else { continue }
            loaded[key] = TokenPricingCatalog.Rate(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: r["cr"] ?? input * 0.1,
                cacheWritePerMTok: r["cw"]
            )
        }
        guard !loaded.isEmpty else { return }
        let fetched = (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        lock.lock(); rates = loaded; fetchedAt = fetched; lock.unlock()
    }
}
