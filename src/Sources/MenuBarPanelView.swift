import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var nativeSession = NativeSessionManager.shared
    @ObservedObject private var settings = AppSettings.shared
    let proxyPort: Int
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
                    switch effectiveTab {
                    case .overview:
                        overviewContent
                    case .status:
                        StatusIncidentsView(usageStore: usageStore, compact: true)
                    case .analytics:
                        AnalyticsDashboardView(usageStore: usageStore, compact: true)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: MenuBarDesign.panelMaxHeight)
            Divider().opacity(0.35)
            footer
        }
        .frame(width: MenuBarDesign.panelWidth)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(serverManager.isRunning ? MenuBarDesign.success.opacity(0.18) : MenuBarDesign.danger.opacity(0.18))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(serverManager.isRunning ? MenuBarDesign.success : MenuBarDesign.danger)
                    .frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeProxy Ultra")
                    .font(.headline)
                // Use String(port) so SwiftUI LocalizedStringKey does not locale-format
                // the integer (e.g. "8,337" instead of "8337").
                Text(serverManager.isRunning ? "Proxy · port \(String(proxyPort))" : "Server stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if usageStore.isRefreshing || usageStore.isRefreshingStatus {
                ProgressView()
                    .controlSize(.small)
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
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh usage, costs & status")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.caption.weight(selectedTab == tab ? .semibold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? MenuBarDesign.accent.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(selectedTab == tab ? MenuBarDesign.accent : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("30-day volume")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatTokens(analytics.totalTokens30d))
                    .font(.system(.body, design: .rounded).weight(.bold))
            }
            Divider().frame(height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Est. API $")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "$%.2f", analytics.totalCostUSD30d))
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(MenuBarDesign.accent)
            }
            Spacer()
            if let top = analytics.topModels.first {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Top model")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(top.model)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(GlassCardBackground(tint: MenuBarDesign.accent))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No providers yet")
                .font(.subheadline.weight(.semibold))
            Text("Connect accounts in Settings to see usage, resets, status, and analytics.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MenuBarDesign.cardPadding)
        .background(GlassCardBackground(tint: MenuBarDesign.accent))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(serverManager.isRunning ? "Stop" : "Start", action: onToggleServer)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(serverManager.isRunning ? MenuBarDesign.danger : MenuBarDesign.success)
            Button("Settings", action: onOpenSettings)
                .controlSize(.small)
            Button("Copy URL", action: onCopyURL)
                .controlSize(.small)
                .disabled(!serverManager.isRunning)
            Spacer()
            Button("Quit", action: onQuit)
                .controlSize(.small)
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
