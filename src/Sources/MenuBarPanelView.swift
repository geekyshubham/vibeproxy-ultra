import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var nativeSession = NativeSessionManager.shared
    @ObservedObject private var settings = AppSettings.shared
    let proxyPort: Int
    /// The exact overall panel height, provided by the controller (which sets the
    /// popover's `contentSize` to match). The scroll area fills the space left after
    /// the header, tab bar, and footer, so content scrolls inside a fixed window
    /// that always fits on screen.
    var panelHeight: CGFloat = MenuBarDesign.panelMaxHeight
    let onOpenSettings: () -> Void
    let onToggleServer: () -> Void
    let onCopyURL: () -> Void
    let onOpenDashboard: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: PanelTab = .overview

    private enum PanelTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case status = "Status"
        case analytics = "Analytics"
        var id: String { rawValue }
    }

    private var visibleProviders: [ServiceType] {        // Providers with more accounts first (easier to find crowded ones), then name.
        ServiceType.allCases
            .filter { authManager.hasAccounts(for: $0) }
            .sorted { lhs, rhs in
                let lc = authManager.accounts(for: lhs).count
                let rc = authManager.accounts(for: rhs).count
                if lc != rc { return lc > rc }
                return lhs.displayName < rhs.displayName
            }
    }

    private var totalAccountCount: Int {
        visibleProviders.reduce(0) { $0 + authManager.accounts(for: $1).count }
    }

    private var availableTabs: [PanelTab] {
        var tabs: [PanelTab] = [.overview]
        if settings.showStatusTab { tabs.append(.status) }
        if settings.showAnalyticsTab { tabs.append(.analytics) }
        return tabs
    }

    private var effectiveTab: PanelTab {
        availableTabs.contains(selectedTab) ? selectedTab : .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: MenuBarDesign.sectionSpacing) {
                    tabContent
                }
                .padding(12)
                .id(effectiveTab)
                .transition(.opacity)
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.35)
            footer
        }
        .frame(width: MenuBarDesign.panelWidth, height: panelHeight)
        .background(GlassPanelBackground())
        .onAppear {
            authManager.checkAuthStatus()
            nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })
            Task {
                await usageStore.refreshVisibleProviders(
                    from: ServiceType.allCases,
                    accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                )
            }
            Task { await usageStore.refreshStatus() }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch effectiveTab {
        case .overview:
            overviewContent
        case .status:
            StatusIncidentsView(usageStore: usageStore, compact: true)
        case .analytics:
            AnalyticsDashboardView(usageStore: usageStore, compact: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PulsingDot(
                color: serverManager.isRunning ? MenuBarDesign.success : MenuBarDesign.danger,
                active: serverManager.isRunning,
                size: 9
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeProxy Ultra")
                    .font(.headline)
                // Use String(port) so SwiftUI LocalizedStringKey does not locale-format
                // the integer (e.g. "8,337" instead of "8337").
                if serverManager.isRunning {
                    HStack(spacing: 5) {
                        Text("Proxy live")
                            .foregroundStyle(MenuBarDesign.success)
                        Text("·").foregroundStyle(.tertiary)
                        Text("port \(String(proxyPort))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                } else {
                    Text("Server stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            refreshControl
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if usageStore.isRefreshing || usageStore.isRefreshingStatus {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            Button {
                Task {
                    await usageStore.refreshVisibleProviders(
                        from: ServiceType.allCases,
                        accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                    )
                    await usageStore.refreshStatus()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconActionButtonStyle())
            .help("Refresh usage, costs & status")
        }
    }

    private var tabPicker: some View {
        SegmentedTabBar(
            tabs: availableTabs,
            selection: Binding(
                get: { effectiveTab },
                set: { selectedTab = $0 }
            ),
            title: { $0.rawValue },
            icon: { tabIcon(for: $0) }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tabIcon(for tab: PanelTab) -> String {
        switch tab {
        case .overview: return "square.grid.2x2.fill"
        case .status: return "dot.radiowaves.left.and.right"
        case .analytics: return "chart.bar.fill"
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewContent: some View {
        if let analytics = usageStore.analytics, analytics.totalTokens30d > 0 {
            overviewPulse(analytics)
        }

        if visibleProviders.allSatisfy({ authManager.accounts(for: $0).isEmpty }) {
            emptyState
        }

        if totalAccountCount > 6 {
            Text("Tip: tap a provider header to collapse · tap an account to expand details")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(visibleProviders, id: \.self) { serviceType in
            ProviderUsageCardView(
                serviceType: serviceType,
                accounts: authManager.accounts(for: serviceType),
                usageForAccount: { usageStore.snapshot(for: $0) },
                cost: usageStore.cost(for: serviceType),
                isProviderEnabled: serverManager.isProviderEnabled(providerKey(for: serviceType)),
                statusLevel: usageStore.statusLevel(for: serviceType),
                proxyPort: proxyPort,
                onWakeCompleted: { _ in
                    Task {
                        await usageStore.refreshVisibleProviders(
                            from: [serviceType],
                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                        )
                    }
                },
                nativeSession: nativeSession,
                onSwitchAccount: { _ in
                    nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })
                    Task {
                        await usageStore.refreshVisibleProviders(
                            from: [serviceType],
                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                        )
                    }
                },
                startCollapsed: true
            )
        }
    }

    private func overviewPulse(_ analytics: AnalyticsOverview) -> some View {
        HStack(spacing: DS.Space.lg) {
            pulseStat(
                icon: "chart.line.uptrend.xyaxis",
                label: "30-day volume",
                value: formatTokens(analytics.totalTokens30d),
                valueColor: .primary
            )
            Divider().frame(height: 30)
            pulseStat(
                icon: "dollarsign.circle",
                label: "Est. API $",
                value: String(format: "$%.2f", analytics.totalCostUSD30d),
                valueColor: MenuBarDesign.accent
            )
            if let top = analytics.topModels.first {
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Top model")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(top.model)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    private func pulseStat(icon: String, label: String, value: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            ZStack {
                Circle()
                    .fill(MenuBarDesign.accent.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MenuBarDesign.accent)
            }
            VStack(spacing: DS.Space.xs) {
                Text("No providers connected yet")
                    .font(.subheadline.weight(.semibold))
                Text("Connect an account to see live usage limits, reset countdowns, status, and analytics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onOpenSettings) {
                Label("Connect a provider", systemImage: "plus.circle.fill")
            }
            .buttonStyle(ProminentActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxl)
        .padding(.horizontal, DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            Button(action: onToggleServer) {
                Label(serverManager.isRunning ? "Stop" : "Start",
                      systemImage: serverManager.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(ProminentActionButtonStyle(
                tint: serverManager.isRunning ? MenuBarDesign.danger : MenuBarDesign.success
            ))
            .help(serverManager.isRunning ? "Stop the local proxy" : "Start the local proxy")

            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(SoftActionButtonStyle())
            .help("Open settings")

            Button(action: onCopyURL) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(SoftActionButtonStyle())
            .disabled(!serverManager.isRunning)
            .help("Copy the proxy URL to the clipboard")

            Spacer(minLength: 0)

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(IconActionButtonStyle(tint: MenuBarDesign.danger))
            .help("Quit VibeProxy Ultra")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func providerKey(for type: ServiceType) -> String {
        switch type {
        case .copilot: return "github-copilot"
        case .grok: return "xai"
        default: return type.rawValue
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
