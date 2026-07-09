import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageStore: UsageStore
    let proxyPort: Int
    let onOpenSettings: () -> Void
    let onToggleServer: () -> Void
    let onCopyURL: () -> Void
    let onOpenDashboard: () -> Void
    let onQuit: () -> Void

    private var visibleProviders: [ServiceType] {
        ServiceType.allCases.filter { authManager.hasAccounts(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: MenuBarDesign.sectionSpacing) {
                    if visibleProviders.allSatisfy({ authManager.accounts(for: $0).isEmpty }) {
                        emptyState
                    }
                    ForEach(visibleProviders, id: \.self) { serviceType in
                            ProviderUsageCardView(
                                serviceType: serviceType,
                                accounts: authManager.accounts(for: serviceType),
                                usageForAccount: { usageStore.snapshot(for: $0) },
                                cost: usageStore.cost(for: serviceType),
                                isProviderEnabled: serverManager.isProviderEnabled(providerKey(for: serviceType)),
                                proxyPort: proxyPort,
                                onWakeCompleted: { _ in
                                    Task {
                                        await usageStore.refreshVisibleProviders(
                                            from: [serviceType],
                                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                                        )
                                    }
                                }
                            )
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
            Task {
                await usageStore.refreshVisibleProviders(
                    from: ServiceType.allCases,
                    accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(serverManager.isRunning ? MenuBarDesign.success : MenuBarDesign.danger)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeProxy Ultra")
                    .font(.headline)
                Text(serverManager.isRunning ? "Running on port \(proxyPort)" : "Server stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if usageStore.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task {
                        await usageStore.refreshVisibleProviders(
                            from: ServiceType.allCases,
                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh usage")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No providers yet")
                .font(.subheadline.weight(.semibold))
            Text("Connect accounts in Settings to see usage, limits, and token stats here.")
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
}