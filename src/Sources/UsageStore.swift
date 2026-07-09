import Foundation

final class UsageStore: ObservableObject {
    @Published private(set) var usageByAccountID: [String: ProviderUsageSnapshot] = [:]
    @Published private(set) var costByProvider: [String: ProviderCostSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    /// Account IDs still waiting on a network usage response.
    @Published private(set) var pendingAccountIDs: Set<String> = []

    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var accountsProvider: () -> [ServiceType: [AuthAccount]] = { [:] }
    private var refreshGeneration: UInt64 = 0

    func configure(accountsProvider: @escaping () -> [ServiceType: [AuthAccount]]) {
        self.accountsProvider = accountsProvider
    }

    func startAutoRefresh(interval: TimeInterval = 90) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshVisibleProviders(from: ServiceType.allCases, accounts: self.accountsProvider()) }
        }
        // Don't block the caller on the first full sweep — results stream in.
        Task { await refreshVisibleProviders(from: ServiceType.allCases, accounts: accountsProvider()) }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
    }

    /// Concurrently fetch usage for every visible account.
    /// Each account is published to the UI as soon as its API response arrives
    /// (fast providers appear first; slow ones keep showing a spinner).
    func refreshVisibleProviders(from serviceTypes: [ServiceType], accounts: [ServiceType: [AuthAccount]] = [:]) async {
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

                // Cost scans are independent; publish as each provider finishes.
                var costProviderIDs = Set<String>()
                for (type, _) in targets {
                    guard let providerID = type.usageProviderID,
                          costProviderIDs.insert(providerID).inserted
                    else { continue }
                    let serviceType = type
                    group.addTask {
                        let cost = await NativeUsageFetcher.fetchCost(for: serviceType)
                        guard !Task.isCancelled else { return }
                        await self.publishCost(cost, providerID: providerID, generation: generation)
                    }
                }

                await group.waitForAll()
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
        lastRefreshAt = nil
        pendingAccountIDs = []
        isRefreshing = false
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
        }
    }

    private func sanitize(_ snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        guard let message = snapshot.errorMessage?.lowercased(),
              (message.contains("install") && message.contains("usage"))
                || message.contains("cli not found")
                || message.contains("command not found")
        else {
            // Ensure completed snapshots are not stuck in refreshing UI state.
            if snapshot.isRefreshing {
                return ProviderUsageSnapshot(
                    id: snapshot.id,
                    providerID: snapshot.providerID,
                    source: snapshot.source,
                    windows: snapshot.windows,
                    subAccounts: snapshot.subAccounts,
                    accountEmail: snapshot.accountEmail,
                    planType: snapshot.planType,
                    planLabel: snapshot.planLabel,
                    updatedAt: snapshot.updatedAt ?? Date(),
                    errorMessage: snapshot.errorMessage,
                    isRefreshing: false
                )
            }
            return snapshot
        }

        return ProviderUsageSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            source: snapshot.source,
            windows: snapshot.windows,
            subAccounts: snapshot.subAccounts,
            accountEmail: snapshot.accountEmail,
            planType: snapshot.planType,
            planLabel: snapshot.planLabel,
            updatedAt: snapshot.updatedAt,
            errorMessage: "Usage limits unavailable — refresh or re-authenticate in Settings",
            isRefreshing: false
        )
    }
}
