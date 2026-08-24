import Foundation

/// On-disk history of per-day usage, so the date picker can answer for days that a
/// fresh scan can no longer see.
///
/// Why this has to exist: `UsageStore` keeps `costByProvider` in memory only, and
/// `LocalTokenCostScanner` skips any log file whose mtime predates the history cutoff.
/// So a day's usage becomes invisible once its session files go untouched and age out —
/// even though that day is still inside the requested window. Persisting each scan's
/// per-day detail lets history accumulate past the limit of any single scan.
///
/// Storage layout mirrors `RemotePricingCatalog`'s disk cache (Application Support /
/// VibeProxy, atomic writes) so there is one convention for cached state in this app.
enum UsageDailyStore {
    /// Bump when the on-disk shape changes; unknown versions are discarded, not guessed at.
    /// v2: same shape as v1, but v1 Claude rows were ~2.4× inflated (duplicate stream lines
    /// summed) and v1 OpenCode rows billed free models at fallback rates, so those providers
    /// are dropped on migration and re-recorded by the next scan.
    private static let schemaVersion = 2

    /// Roughly 13 months, so year-over-year comparisons stay possible while the file
    /// remains bounded (a busy day is a few KB, so this caps out in the low single MB).
    static let retentionDays = 400

    private struct Payload: Codable {
        var version: Int
        var updatedAt: Double
        /// day key -> provider ID -> that provider's usage on that day.
        var days: [String: [String: DailyProviderUsage]]
    }

    private static let lock = NSLock()
    /// Mirrors the file so reads don't hit disk on every UI interaction.
    private static var days: [String: [String: DailyProviderUsage]] = [:]
    private static var loaded = false

    // MARK: - Paths

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("VibeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("usage-daily.json")
    }

    // MARK: - Lifecycle

    /// Load the cache once. Cheap enough to call from app launch.
    static func bootstrap() {
        lock.lock()
        let alreadyLoaded = loaded
        lock.unlock()
        guard !alreadyLoaded else { return }
        load()
    }

    private static func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == schemaVersion || payload.version == 1
        else {
            lock.lock(); loaded = true; lock.unlock()
            return
        }

        var migrated = payload.days
        if payload.version == 1 {
            for (day, providers) in migrated {
                var remaining = providers
                remaining.removeValue(forKey: "claude")
                remaining.removeValue(forKey: "opencode")
                migrated[day] = remaining.isEmpty ? nil : remaining
            }
        }

        lock.lock()
        days = migrated
        loaded = true
        lock.unlock()

        if payload.version == 1 { write(migrated) }
    }

    // MARK: - Recording

    /// Fold a scan's per-day results for one provider into the history.
    ///
    /// Semantics are **replace** per (day, provider), never add: every scan recomputes a
    /// day's totals from the full log files, so accumulating would double-count on the
    /// second scan of the same day. Days the scan didn't report are left untouched, which
    /// is exactly how history outlives the scanner's own visibility window.
    static func record(_ daily: [UsageDayKey: DailyProviderUsage]) {
        guard !daily.isEmpty else { return }
        bootstrap()

        lock.lock()
        for (day, usage) in daily {
            var forDay = days[day.value] ?? [:]
            forDay[usage.providerID] = usage
            days[day.value] = forDay
        }
        pruneLocked()
        let snapshot = days
        lock.unlock()

        write(snapshot)
    }

    /// Record several providers at once (one scan sweep), with a single disk write.
    static func record(providers: [[UsageDayKey: DailyProviderUsage]]) {
        let merged = providers.filter { !$0.isEmpty }
        guard !merged.isEmpty else { return }
        bootstrap()

        lock.lock()
        for daily in merged {
            for (day, usage) in daily {
                var forDay = days[day.value] ?? [:]
                forDay[usage.providerID] = usage
                days[day.value] = forDay
            }
        }
        pruneLocked()
        let snapshot = days
        lock.unlock()

        write(snapshot)
    }

    // MARK: - Queries

    /// Everything known about one calendar day.
    static func summary(for day: UsageDayKey) -> DailyUsageSummary {
        bootstrap()
        lock.lock()
        let forDay = days[day.value] ?? [:]
        lock.unlock()

        // Stable provider order; the UI re-sorts by cost via `providersByCost`.
        let providers = forDay.values.sorted { $0.providerID < $1.providerID }
        return DailyUsageSummary(day: day, providers: providers)
    }

    /// Day keys that hold at least one usage row, most recent first.
    /// Drives the picker's "days with data" affordance so users don't hunt blindly.
    static func availableDays() -> [UsageDayKey] {
        bootstrap()
        lock.lock()
        let keys = days.filter { _, providers in
            providers.values.contains { !$0.models.isEmpty }
        }.keys
        lock.unlock()
        return keys.map { UsageDayKey(value: $0) }.sorted(by: >)
    }

    /// Summaries for an inclusive day range, ascending. Days with no data are omitted;
    /// callers that need a dense series should fill gaps themselves.
    static func summaries(from start: UsageDayKey, to end: UsageDayKey) -> [DailyUsageSummary] {
        bootstrap()
        let (lower, upper) = start <= end ? (start, end) : (end, start)
        lock.lock()
        let matching = days.filter { key, _ in
            key >= lower.value && key <= upper.value
        }
        lock.unlock()

        return matching
            .map { key, providers in
                DailyUsageSummary(
                    day: UsageDayKey(value: key),
                    providers: providers.values.sorted { $0.providerID < $1.providerID }
                )
            }
            .filter { !$0.isEmpty }
            .sorted { $0.day < $1.day }
    }

    /// Oldest day we hold data for — the honest lower bound for the date picker.
    static func earliestDay() -> UsageDayKey? {
        availableDays().last
    }

    // MARK: - Maintenance

    /// Drop days beyond the retention window. Caller must hold `lock`.
    private static func pruneLocked() {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            return
        }
        let cutoff = UsageDayKey(date: cutoffDate).value
        days = days.filter { $0.key >= cutoff }
    }

    private static func write(_ snapshot: [String: [String: DailyProviderUsage]]) {
        guard let url = fileURL else { return }
        let payload = Payload(
            version: schemaVersion,
            updatedAt: Date().timeIntervalSince1970,
            days: snapshot
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Atomic so a crash mid-write can't leave a truncated file that fails to decode
        // and silently wipes accumulated history.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Test hooks

    /// Replace in-memory state without touching disk, for the Verification specs.
    static func replaceForTesting(_ replacement: [UsageDayKey: [DailyProviderUsage]]) {
        lock.lock()
        days = replacement.reduce(into: [:]) { acc, entry in
            acc[entry.key.value] = entry.value.reduce(into: [:]) { inner, usage in
                inner[usage.providerID] = usage
            }
        }
        loaded = true
        lock.unlock()
    }

    /// Fold data in without writing to disk, so specs can verify merge semantics.
    static func recordForTesting(_ daily: [UsageDayKey: DailyProviderUsage]) {
        lock.lock()
        loaded = true
        for (day, usage) in daily {
            var forDay = days[day.value] ?? [:]
            forDay[usage.providerID] = usage
            days[day.value] = forDay
        }
        lock.unlock()
    }

    static func resetForTesting() {
        lock.lock(); days = [:]; loaded = true; lock.unlock()
    }
}
