import Foundation

/// Automatically fires "wake 5h window" keep-alives on a cadence, so a provider's rolling
/// session quota stays warm without manual clicks — analogous to Cockpit Tools' wake scheduler.
///
/// Design:
/// - A lightweight timer ticks every few minutes on the main run loop (cheap eligibility check).
/// - Each supported+enabled account is woken at most once per rolling window (default ~5h),
///   with a short grace delay after enabling.
/// - Last-wake timestamps persist across launches so restarts don't cause a burst.
/// - Network work runs off the main thread; results are published back on main.
final class QuotaWakeScheduler: ObservableObject {
    struct WakeRecord: Equatable {
        let date: Date
        let success: Bool
        let message: String
    }

    /// Most recent auto-wake result per account (for the Settings status list).
    @Published private(set) var lastRecords: [String: WakeRecord] = [:]
    @Published private(set) var isEnabled = false

    private let settings: AppSettings
    private weak var usageStore: UsageStore?
    private var accountsProvider: () -> [ServiceType: [AuthAccount]] = { [:] }
    private var proxyPortProvider: () -> Int = { 8317 }

    private var timer: Timer?
    private var inFlight = Set<String>()
    private var lastWakeAt: [String: Date] = [:]
    private var schedulerStartedAt = Date()

    private let checkInterval: TimeInterval = 300      // evaluate every 5 minutes
    private let initialDelay: TimeInterval = 120       // first wake ~2 min after enabling
    private let defaultWindow: TimeInterval = 5 * 3600 // 5h fallback cadence
    private let lastWakeKey = "ultra.autoWakeLastAt"

    init(settings: AppSettings) {
        self.settings = settings
        loadLastWakeTimes()
    }

    func configure(
        usageStore: UsageStore,
        accountsProvider: @escaping () -> [ServiceType: [AuthAccount]],
        proxyPortProvider: @escaping () -> Int
    ) {
        self.usageStore = usageStore
        self.accountsProvider = accountsProvider
        self.proxyPortProvider = proxyPortProvider
    }

    /// Call on the main thread.
    func start() {
        stop()
        schedulerStartedAt = Date()
        isEnabled = true
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 60 // let macOS coalesce — this is a keep-alive, not real-time.
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isEnabled = false
    }

    /// React quickly (e.g. right after a usage refresh). Main thread.
    func evaluateNow() {
        tick()
    }

    // MARK: - Core (main thread)

    private func tick() {
        guard settings.autoWakeEnabled else { return }
        let now = Date()
        let accounts = accountsProvider()

        for (type, list) in accounts {
            guard let providerID = type.usageProviderID,
                  settings.autoWakeProviderIDs.contains(providerID),
                  QuotaWakeService.supportsWake(type)
            else { continue }
            for account in list where !account.isDisabled && !account.isExpired {
                if shouldWake(account, now: now) {
                    launchWake(account, now: now)
                }
            }
        }
    }

    private func shouldWake(_ account: AuthAccount, now: Date) -> Bool {
        guard !inFlight.contains(account.id) else { return false }
        let interval = wakeInterval(for: account)
        if let last = lastWakeAt[account.id] {
            return now.timeIntervalSince(last) >= interval
        }
        // Never woken this account: wait a short grace after enabling, then fire once.
        return now.timeIntervalSince(schedulerStartedAt) >= initialDelay
    }

    /// Cadence for an account: prefer its real session-window length, else 5h.
    private func wakeInterval(for account: AuthAccount) -> TimeInterval {
        let grace = settings.autoWakeGraceMinutes.clamped(to: 0...60) * 60
        guard let usage = usageStore?.snapshot(for: account) else {
            return defaultWindow + grace
        }
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        let sessionWindow = windows.first { QuotaWakeService.isSessionOrFiveHourWindow($0) }
        if let minutes = sessionWindow?.windowMinutes, minutes > 0 {
            // Clamp to a sane 1h…6h range so odd data can't cause hammering.
            let seconds = TimeInterval(min(max(minutes, 60), 360)) * 60
            return seconds + grace
        }
        return defaultWindow + grace
    }

    private func launchWake(_ account: AuthAccount, now: Date) {
        inFlight.insert(account.id)
        // Record the attempt up-front so a slow/failed wake can't retry every tick.
        lastWakeAt[account.id] = now
        persistLastWakeTimes()

        let port = proxyPortProvider()
        Task { [weak self] in
            let result = await QuotaWakeService.wake(account: account, proxyPort: port)
            DispatchQueue.main.async {
                self?.applyResult(account, result)
            }
        }
    }

    private func applyResult(_ account: AuthAccount, _ result: QuotaWakeService.WakeResult) {
        inFlight.remove(account.id)
        switch result {
        case .success(let message):
            lastRecords[account.id] = WakeRecord(date: Date(), success: true, message: message)
            NSLog("[AutoWake] %@ woke %@", account.type.displayName, account.baseDisplayName)
        case .failure(let message):
            lastRecords[account.id] = WakeRecord(date: Date(), success: false, message: message)
            // Back off failed accounts by half a window so we don't spam a broken endpoint.
            lastWakeAt[account.id] = Date().addingTimeInterval(-wakeInterval(for: account) / 2)
            persistLastWakeTimes()
            NSLog("[AutoWake] Failed to wake %@: %@", account.baseDisplayName, message)
        }
    }

    // MARK: - Persistence

    private func loadLastWakeTimes() {
        guard let stored = UserDefaults.standard.dictionary(forKey: lastWakeKey) as? [String: Double] else { return }
        lastWakeAt = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func persistLastWakeTimes() {
        let encoded = lastWakeAt.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(encoded, forKey: lastWakeKey)
    }
}
