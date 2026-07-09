import SwiftUI

/// Full-page analytics for Settings + compact strip for the menu bar.
struct AnalyticsDashboardView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var settings = AppSettings.shared
    var compact: Bool = false

    private var overview: AnalyticsOverview? { usageStore.analytics }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            header
            if let overview {
                totalsGrid(overview)
                if !overview.byProvider.isEmpty {
                    providerSection(overview)
                }
                if !overview.topModels.isEmpty {
                    modelsSection(overview)
                }
                footnote
            } else if usageStore.isRefreshing {
                ProgressView("Scanning local session logs…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                emptyState
            }
        }
        .padding(compact ? 0 : 4)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(compact ? "Analytics" : "Usage analytics")
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                Text(settings.showCostEstimates
                    ? "Local token logs · estimated API-equivalent $"
                    : "Local token logs · token volume")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if usageStore.isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func totalsGrid(_ overview: AnalyticsOverview) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCard(
                title: "30-day tokens",
                value: formatTokens(overview.totalTokens30d),
                subtitle: settings.showCostEstimates ? formatUSD(overview.totalCostUSD30d) : ""
            )
            metricCard(
                title: "Today tokens",
                value: formatTokens(overview.totalTokensSession),
                subtitle: settings.showCostEstimates ? formatUSD(overview.totalCostUSDSession) : ""
            )
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MenuBarDesign.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(GlassCardBackground(tint: MenuBarDesign.accent))
    }

    private func providerSection(_ overview: AnalyticsOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By provider")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(overview.byProvider.prefix(compact ? 4 : 12)) { provider in
                providerRow(provider, totalTokens: max(1, overview.totalTokens30d))
            }
        }
    }

    private func providerRow(_ provider: ProviderCostSnapshot, totalTokens: Int) -> some View {
        let share = Double(provider.last30DaysTokens) / Double(totalTokens)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.providerID.capitalized)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formatTokens(provider.last30DaysTokens))
                    .font(.caption.monospacedDigit())
                if let usd = provider.last30DaysCostUSD, settings.showCostEstimates {
                    Text(formatUSD(usd))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(MenuBarDesign.accent.opacity(0.85))
                        .frame(width: max(4, proxy.size.width * share))
                }
            }
            .frame(height: 5)
        }
    }

    private func modelsSection(_ overview: AnalyticsOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most used models")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(overview.topModels.prefix(compact ? 5 : 10)) { model in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.model)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text("\(model.requestCount) requests · \(formatTokens(model.inputTokens)) in / \(formatTokens(model.outputTokens)) out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatTokens(model.totalTokens))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        if settings.showCostEstimates {
                            Text(formatUSD(model.estimatedCostUSD))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(GlassCardBackground(tint: Color.purple))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No local usage history yet")
                .font(.subheadline.weight(.semibold))
            Text("Use Claude Code, Codex, or other tools — Ultra scans local session logs for tokens, models, and estimated API-equivalent spend.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(GlassCardBackground(tint: .secondary))
    }

    private var footnote: some View {
        Text(settings.showCostEstimates
            ? "$ figures are list-price estimates for analytics only — not your subscription invoice. Quota bars above are live plan limits."
            : "Token volume from local session logs. Quota bars above are live plan limits.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.1fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatUSD(_ value: Double) -> String {
        if value < 0.01 && value > 0 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}

struct StatusIncidentsView: View {
    @ObservedObject var usageStore: UsageStore
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(compact ? "Status" : "Provider status & incidents")
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                Spacer()
                if usageStore.isRefreshingStatus {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await usageStore.refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh status pages")
                }
            }

            if usageStore.providerStatuses.isEmpty {
                Text(
                    usageStore.isRefreshingStatus
                        ? "Loading status for your connected providers…"
                        : "No status sources for your connected accounts yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Showing status only for providers you have connected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(usageStore.providerStatuses) { status in
                    statusCard(status)
                }
            }
        }
    }

    private func statusCard(_ status: ProviderStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status.level))
                    .frame(width: 8, height: 8)
                Text(status.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(status.level.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(status.level))
            }

            if let description = status.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.isProbeOnly {
                Text("Inferred from API health (no public statuspage JSON)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !status.incidents.isEmpty {
                ForEach(status.incidents.prefix(compact ? 2 : 5)) { incident in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(MenuBarDesign.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.name)
                                .font(.caption2.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(incident.status + (incident.impact.map { " · \($0)" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let url = status.pageURL {
                Link(status.isProbeOnly ? "Open status page in browser" : "Open status page", destination: url)
                    .font(.caption2)
            }
        }
        .padding(10)
        .background(GlassCardBackground(tint: statusColor(status.level)))
    }

    private func statusColor(_ level: ProviderStatusLevel) -> Color {
        switch level {
        case .none: return MenuBarDesign.success
        case .minor, .maintenance: return MenuBarDesign.warning
        case .major, .critical: return MenuBarDesign.danger
        case .unknown: return .secondary
        }
    }
}
