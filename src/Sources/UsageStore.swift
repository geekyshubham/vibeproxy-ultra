import Foundation

final class UsageStore: ObservableObject {
    @Published private(set) var usageByAccountID: [String: ProviderUsageSnapshot] = [:]
    @Published private(set) var costByProvider: [String: ProviderCostSnapshot] = [:]
    @Published private(set) var providerStatuses: [ProviderStatusSnapshot] = []
    @Published private(set) var analytics: AnalyticsOverview?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingStatus = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastStatusRefreshAt: Date?
    /// Account IDs still waiting on a network usage response.
    @Published private(set) var pendingAccountIDs: Set<String> = []

    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var timer: Timer?
    private var statusTimer: Timer?
    private var accountsProvider: () -> [ServiceType: [AuthAccount]] = { [:] }
    private var refreshGeneration: UInt64 = 0

    func configure(accountsProvider: @escaping () -> [ServiceType: [AuthAccount]]) {
        self.accountsProvider = accountsProvider
    }

    /// Last time we ran the expensive local session/cost filesystem scan.
    private var lastCostScanAt: Date?
    private let costScanMinInterval: TimeInterval = 15 * 60

    func startAutoRefresh(immediate: Bool = true) {
        let interval = AppSettings.shared.usageRefreshInterval
        let statusInterval = AppSettings.shared.statusRefreshInterval
        timer?.invalidate()
        // Interval is user-configurable (default 3 min). 90s was thrashing CPU with full re-fetches.
        let usageTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshVisibleProviders(from: ServiceType.allCases, accounts: self.accountsProvider()) }
        }
        // Tolerance lets macOS coalesce timers → fewer wakeups, lower idle CPU.
        usageTimer.tolerance = interval * 0.2
        timer = usageTimer

        statusTimer?.invalidate()
        let stTimer = Timer.scheduledTimer(withTimeInterval: statusInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshStatus() }
        }
        stTimer.tolerance = statusInterval * 0.2
        statusTimer = stTimer

        guard immediate else { return }
        // Don't block the caller on the first full sweep — results stream in.
        Task { await refreshVisibleProviders(from: ServiceType.allCases, accounts: accountsProvider()) }
        Task { await refreshStatus() }
    }

    /// Re-schedule timers after the user changes refresh cadence (no immediate refresh burst).
    func applyRefreshSettings() {
        startAutoRefresh(immediate: false)
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        statusTimer?.invalidate()
        statusTimer = nil
        refreshTask?.cancel()
        statusTask?.cancel()
    }

    func refreshStatus() async {
        statusTask?.cancel()
        await MainActor.run { isRefreshingStatus = true }

        let accounts = accountsProvider()
        // Only providers that currently have at least one account.
        let connected = Set(accounts.compactMap { type, list -> ServiceType? in
            list.isEmpty ? nil : type
        })

        var credentials = ProviderStatusService.ProbeCredentials()
        // Collect Grok/xAI OAuth tokens for authenticated health checks (never logged).
        if let grokAccounts = accounts[.grok] {
            var tokens: [String] = []
            for account in grokAccounts where !account.isDisabled {
                if let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
                   let token = payload["access_token"] as? String,
                   !token.isEmpty
                {
                    tokens.append(token)
                }
            }
            if !tokens.isEmpty {
                credentials.accessTokensBySourceKey["grok"] = tokens
            }
        }

        statusTask = Task { [weak self] in
            let statuses = await ProviderStatusService.fetch(
                forConnected: connected,
                credentials: credentials
            )
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.providerStatuses = statuses
                self.isRefreshingStatus = false
                self.lastStatusRefreshAt = Date()
            }
        }
        await statusTask?.value
    }

    /// Operational status for a given Ultra provider (Overview dots).
    func statusLevel(for serviceType: ServiceType) -> ProviderStatusLevel? {
        providerStatuses.first { $0.serviceTypes.contains(serviceType) }?.level
    }

    func statusSnapshot(for serviceType: ServiceType) -> ProviderStatusSnapshot? {
        providerStatuses.first { $0.serviceTypes.contains(serviceType) }
    }

    /// Concurrently fetch usage for every visible account.
    /// Each account is published to the UI as soon as its API response arrives
    /// (fast providers appear first; slow ones keep showing a spinner).
    func refreshVisibleProviders(from serviceTypes: [ServiceType], accounts: [ServiceType: [AuthAccount]] = [:]) async {
        // Avoid overlapping full sweeps (timer + manual refresh + onAppear).
        if isRefreshing {
            return
        }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration

        let targets: [(ServiceType, AuthAccount)] = serviceTypes.flatMap { type in
            guard type.usageProviderID != nil else { return [(ServiceType, AuthAccount)]() }
            return (accounts[type] ?? [])
                .filter { !$0.isDisabled && !$0.isExpired }
                .map { (type, $0) }
        }

        guard !targets.isEmpty else {
            await MainActor.run {
                isRefreshing = false
                pendingAccountIDs = []
            }
            return
        }

        let pendingIDs = Set(targets.map(\.1.id))

        await MainActor.run {
            isRefreshing = true
            pendingAccountIDs = pendingIDs
            for (type, account) in targets {
                guard let providerID = type.usageProviderID else { continue }
                // Keep last-known numbers visible while the new request is in flight.
                if let existing = usageByAccountID[account.id],
                   (!existing.windows.isEmpty || !existing.subAccounts.isEmpty || existing.errorMessage != nil)
                {
                    usageByAccountID[account.id] = ProviderUsageSnapshot(
                        id: existing.id,
                        providerID: existing.providerID,
                        source: existing.source,
                        windows: existing.windows,
                        subAccounts: existing.subAccounts,
                        accountEmail: existing.accountEmail ?? account.email ?? account.login,
                        planType: existing.planType,
                        planLabel: existing.planLabel,
                        rateLimitResets: existing.rateLimitResets,
                        updatedAt: existing.updatedAt,
                        errorMessage: existing.errorMessage,
                        isRefreshing: true
                    )
                } else {
                    usageByAccountID[account.id] = .empty(
                        authAccountID: account.id,
                        providerID: providerID,
                        accountEmail: account.email ?? account.login,
                        refreshing: true
                    )
                }
            }
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            // Usage + cost run together. Usage updates stream into the UI one-by-one.
            await withTaskGroup(of: Void.self) { group in
                for (type, account) in targets {
                    group.addTask {
                        let usage = await NativeUsageFetcher.fetchUsage(
                            for: type,
                            authFile: account.filePath,
                            authAccountID: account.id
                        )
                        // Drop stale results if a newer refresh was started.
                        guard !Task.isCancelled else { return }
                        await self.publishUsage(usage, generation: generation, accountID: account.id)
                    }
                }

                await group.waitForAll()
            }

            // Expensive local JSONL scans (Codex/Claude trees) — throttle hard.
            // This was the main CPU hog when run on every 90s refresh for every provider.
            let shouldScanCosts: Bool = await MainActor.run {
                if let last = self.lastCostScanAt,
                   Date().timeIntervalSince(last) < self.costScanMinInterval
                {
                    return false
                }
                return true
            }
            if shouldScanCosts {
                let historyDays = await MainActor.run { AppSettings.shared.analyticsHistoryDays }
                let allCosts = await Task.detached(priority: .utility) {
                    LocalTokenCostScanner.allProviderSnapshots(historyDays: historyDays)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    for cost in allCosts {
                        self.costByProvider[cost.providerID] = cost
                    }
                    self.analytics = AnalyticsEngine.overview(from: Array(self.costByProvider.values))
                    self.lastCostScanAt = Date()
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear the global spinner for the latest generation.
                guard generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                self.pendingAccountIDs = []
                self.lastRefreshAt = Date()
            }
        }

        // Waiters still block until the sweep completes, but the UI updates earlier
        // via intermediate MainActor publishes above.
        await refreshTask?.value
    }

    func snapshot(for account: AuthAccount) -> ProviderUsageSnapshot? {
        usageByAccountID[account.id]
    }

    func cost(for serviceType: ServiceType) -> ProviderCostSnapshot? {
        guard let id = serviceType.usageProviderID else { return nil }
        return costByProvider[id]
    }

    func clearCachedUsage() {
        usageByAccountID = [:]
        costByProvider = [:]
        analytics = nil
        lastRefreshAt = nil
        pendingAccountIDs = []
        isRefreshing = false
    }

    /// Worst status level among tracked providers (for menu header badge).
    var overallStatusLevel: ProviderStatusLevel {
        providerStatuses.map(\.level).min(by: { $0.sortRank < $1.sortRank }) ?? .unknown
    }

    var activeIncidentCount: Int {
        providerStatuses.reduce(0) { $0 + $1.incidents.count }
    }

    // MARK: - Streaming publishes

    @MainActor
    private func publishUsage(_ usage: ProviderUsageSnapshot, generation: UInt64, accountID: String) {
        guard generation == refreshGeneration else { return }
        usageByAccountID[accountID] = sanitize(usage)
        pendingAccountIDs.remove(accountID)
        // Global spinner stays until every account finishes (or a new refresh starts).
        if pendingAccountIDs.isEmpty {
            isRefreshing = false
            lastRefreshAt = Date()
        }
    }

    @MainActor
    private func publishCost(_ cost: ProviderCostSnapshot?, providerID: String, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        if let cost {
            costByProvider[providerID] = cost
            analytics = AnalyticsEngine.overview(from: Array(costByProvider.values))
        }
    }

    private func enrichWindows(_ windows: [RateWindow]) -> [RateWindow] {
        windows.map { window in
            guard let resetsAt = window.resetsAt else { return window }
            if let existing = window.resetDescription, !existing.isEmpty { return window }
            return RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: window.windowMinutes,
                resetsAt: resetsAt,
                resetDescription: ResetCountdownFormatter.resetLine(for: resetsAt),
                label: window.label,
                remainingValue: window.remainingValue,
                totalValue: window.totalValue,
                unitLabel: window.unitLabel,
                displayStyle: window.displayStyle
            )
        }
    }

    private func sanitize(_ snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        let windows = enrichWindows(snapshot.windows)
        let subAccounts = snapshot.subAccounts.map { sub in
            ProviderUsageSubAccount(
                id: sub.id,
                title: sub.title,
                subtitle: sub.subtitle,
                planType: sub.planType,
                windows: enrichWindows(sub.windows),
                errorMessage: sub.errorMessage
            )
        }

        guard let message = snapshot.errorMessage?.lowercased(),
              (message.contains("install") && message.contains("usage"))
                || message.contains("cli not found")
                || message.contains("command not found")
        else {
            // Ensure completed snapshots are not stuck in refreshing UI state.
            return ProviderUsageSnapshot(
                id: snapshot.id,
                providerID: snapshot.providerID,
                source: snapshot.source,
                windows: windows,
                subAccounts: subAccounts,
                accountEmail: snapshot.accountEmail,
                planType: snapshot.planType,
                planLabel: snapshot.planLabel,
                rateLimitResets: snapshot.rateLimitResets,
                updatedAt: snapshot.updatedAt ?? Date(),
                errorMessage: snapshot.errorMessage,
                isRefreshing: false
            )
        }

        return ProviderUsageSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            source: snapshot.source,
            windows: windows,
            subAccounts: subAccounts,
            accountEmail: snapshot.accountEmail,
            planType: snapshot.planType,
            planLabel: snapshot.planLabel,
            rateLimitResets: snapshot.rateLimitResets,
            updatedAt: snapshot.updatedAt,
            errorMessage: "Usage limits unavailable — refresh or re-authenticate in Settings",
            isRefreshing: false
        )
    }
}
