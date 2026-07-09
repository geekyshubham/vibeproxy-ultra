import Foundation
import Combine

/// User-facing preferences for VibeProxy Ultra, persisted in `UserDefaults`.
/// Kept intentionally small and observable so views update live and services
/// (auto-refresh, wake scheduler, account switching) can read a single source of truth.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: Refresh cadence

    /// How often usage/quota is refreshed, in minutes (1…30).
    @Published var usageRefreshMinutes: Double {
        didSet { persist(usageRefreshMinutes.clamped(to: 1...30), forKey: Keys.usageRefreshMinutes) }
    }

    /// How often provider status pages are polled, in minutes (2…60).
    @Published var statusRefreshMinutes: Double {
        didSet { persist(statusRefreshMinutes.clamped(to: 2...60), forKey: Keys.statusRefreshMinutes) }
    }

    /// History window for local analytics scans, in days.
    @Published var analyticsHistoryDays: Int {
        didSet { persist(analyticsHistoryDays, forKey: Keys.analyticsHistoryDays) }
    }

    // MARK: Analytics / UI customization

    @Published var showCostEstimates: Bool {
        didSet { persist(showCostEstimates, forKey: Keys.showCostEstimates) }
    }

    @Published var showStatusTab: Bool {
        didSet { persist(showStatusTab, forKey: Keys.showStatusTab) }
    }

    @Published var showAnalyticsTab: Bool {
        didSet { persist(showAnalyticsTab, forKey: Keys.showAnalyticsTab) }
    }

    /// Show the menu-bar icon with a colored dot reflecting worst quota pressure.
    @Published var menuBarUsageBadge: Bool {
        didSet { persist(menuBarUsageBadge, forKey: Keys.menuBarUsageBadge) }
    }

    // MARK: Account switching

    /// Quit + relaunch the associated desktop app after switching accounts.
    @Published var restartAppOnSwitch: Bool {
        didSet { persist(restartAppOnSwitch, forKey: Keys.restartAppOnSwitch) }
    }

    /// Ask for confirmation before switching the active native session.
    @Published var confirmBeforeSwitch: Bool {
        didSet { persist(confirmBeforeSwitch, forKey: Keys.confirmBeforeSwitch) }
    }

    // MARK: Wake scheduler

    /// Master switch for the automatic "wake 5h window" scheduler.
    @Published var autoWakeEnabled: Bool {
        didSet { persist(autoWakeEnabled, forKey: Keys.autoWakeEnabled) }
    }

    /// Provider IDs the scheduler is allowed to wake automatically.
    @Published var autoWakeProviderIDs: Set<String> {
        didSet { persist(Array(autoWakeProviderIDs), forKey: Keys.autoWakeProviderIDs) }
    }

    /// Minutes to wait after a quota window resets before firing the keep-alive.
    @Published var autoWakeGraceMinutes: Double {
        didSet { persist(autoWakeGraceMinutes.clamped(to: 0...60), forKey: Keys.autoWakeGraceMinutes) }
    }

    // MARK: Derived

    var usageRefreshInterval: TimeInterval { usageRefreshMinutes.clamped(to: 1...30) * 60 }
    var statusRefreshInterval: TimeInterval { statusRefreshMinutes.clamped(to: 2...60) * 60 }

    /// Providers that can be auto-woken (same set QuotaWakeService supports).
    static let wakeableProviderIDs: [String] = ["codex", "claude", "antigravity", "gemini"]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true

        usageRefreshMinutes = defaults.number(forKey: Keys.usageRefreshMinutes, default: 3)
        statusRefreshMinutes = defaults.number(forKey: Keys.statusRefreshMinutes, default: 10)
        analyticsHistoryDays = defaults.integer(forKey: Keys.analyticsHistoryDays, default: 30)
        showCostEstimates = defaults.bool(forKey: Keys.showCostEstimates, default: true)
        showStatusTab = defaults.bool(forKey: Keys.showStatusTab, default: true)
        showAnalyticsTab = defaults.bool(forKey: Keys.showAnalyticsTab, default: true)
        menuBarUsageBadge = defaults.bool(forKey: Keys.menuBarUsageBadge, default: false)
        restartAppOnSwitch = defaults.bool(forKey: Keys.restartAppOnSwitch, default: true)
        confirmBeforeSwitch = defaults.bool(forKey: Keys.confirmBeforeSwitch, default: true)
        autoWakeEnabled = defaults.bool(forKey: Keys.autoWakeEnabled, default: false)
        autoWakeGraceMinutes = defaults.number(forKey: Keys.autoWakeGraceMinutes, default: 3)

        if let stored = defaults.array(forKey: Keys.autoWakeProviderIDs) as? [String] {
            autoWakeProviderIDs = Set(stored)
        } else {
            autoWakeProviderIDs = ["codex"]
        }

        isLoading = false
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let usageRefreshMinutes = "ultra.usageRefreshMinutes"
        static let statusRefreshMinutes = "ultra.statusRefreshMinutes"
        static let analyticsHistoryDays = "ultra.analyticsHistoryDays"
        static let showCostEstimates = "ultra.showCostEstimates"
        static let showStatusTab = "ultra.showStatusTab"
        static let showAnalyticsTab = "ultra.showAnalyticsTab"
        static let menuBarUsageBadge = "ultra.menuBarUsageBadge"
        static let restartAppOnSwitch = "ultra.restartAppOnSwitch"
        static let confirmBeforeSwitch = "ultra.confirmBeforeSwitch"
        static let autoWakeEnabled = "ultra.autoWakeEnabled"
        static let autoWakeProviderIDs = "ultra.autoWakeProviderIDs"
        static let autoWakeGraceMinutes = "ultra.autoWakeGraceMinutes"
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func integer(forKey key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }

    func number(forKey key: String, default fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
