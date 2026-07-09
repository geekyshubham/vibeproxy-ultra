import SwiftUI

struct ProviderUsageCardView: View {
    let serviceType: ServiceType
    let accounts: [AuthAccount]
    let usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?
    let cost: ProviderCostSnapshot?
    let isProviderEnabled: Bool
    var proxyPort: Int = 8317
    var onWakeCompleted: ((AuthAccount) -> Void)? = nil

    private var tint: Color { MenuBarDesign.providerTint(for: serviceType) }

    private var activeAccounts: [AuthAccount] {
        accounts.filter { !$0.isDisabled && !$0.isExpired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if accounts.isEmpty {
                Text("No accounts connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                accountsSection
            }
            if isProviderEnabled {
                costSection
            }
        }
        .padding(MenuBarDesign.cardPadding)
        .background(GlassCardBackground(tint: tint))
    }

    private var header: some View {
        HStack(spacing: 8) {
            providerIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceType.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusBadge
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let icon = iconImage(for: serviceType) {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(.template)
                .frame(width: 18, height: 18)
                .foregroundStyle(tint)
        } else if let symbol = systemSymbol(for: serviceType) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
        }
    }

    private var subtitleText: String {
        if accounts.isEmpty { return "Not connected" }
        let active = activeAccounts.count
        if active == accounts.count {
            return "\(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        }
        return "\(active) active · \(accounts.count) total"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !isProviderEnabled {
            Text("Off")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        } else if accounts.contains(where: { usageForAccount($0)?.isRefreshing == true }) {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { account in
                AccountUsageBlock(
                    account: account,
                    usage: usageForAccount(account),
                    tint: tint,
                    showUsage: isProviderEnabled,
                    canWake: isProviderEnabled && QuotaWakeService.supportsWake(serviceType) && !account.isDisabled && !account.isExpired,
                    proxyPort: proxyPort,
                    onWakeCompleted: { onWakeCompleted?(account) }
                )
                if account.id != accounts.last?.id {
                    Divider().opacity(0.2)
                }
            }
        }
    }

    @ViewBuilder
    private var costSection: some View {
        if let cost, cost.sessionTokens > 0 || cost.last30DaysTokens > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local token usage (all sessions)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if cost.sessionTokens > 0 {
                    Text("Session tokens: \(formatTokens(cost.sessionTokens))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if cost.last30DaysTokens > 0 {
                    Text("30-day tokens: \(formatTokens(cost.last30DaysTokens))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func iconImage(for type: ServiceType) -> NSImage? {
        let name: String? = switch type {
        case .antigravity: "icon-antigravity.png"
        case .claude: "icon-claude.png"
        case .codex: "icon-codex.png"
        case .copilot: "icon-copilot.png"
        case .gemini: "icon-gemini.png"
        case .qwen: "icon-qwen.png"
        case .zai: "icon-zai.png"
        case .kiro: "icon-kiro.png"
        case .kimi: "icon-kimi.png"
        case .grok: "icon-grok.png"
        case .cursor, .codebuddy, .gitlab, .kilo: nil
        }
        guard let name else { return nil }
        return IconCatalog.shared.image(named: name, resizedTo: NSSize(width: 18, height: 18), template: true)
    }

    private func systemSymbol(for type: ServiceType) -> String? {
        switch type {
        case .grok: return "sparkle"
        case .kimi: return "moon.stars.fill"
        case .kiro: return "bolt.horizontal.circle.fill"
        case .cursor: return "cursorarrow.click.2"
        case .codebuddy: return "person.2.wave.2.fill"
        case .gitlab: return "chevron.left.forwardslash.chevron.right"
        case .kilo: return "scalemass.fill"
        default: return nil
        }
    }
}

private struct AccountUsageBlock: View {
    let account: AuthAccount
    let usage: ProviderUsageSnapshot?
    let tint: Color
    let showUsage: Bool
    var canWake: Bool = false
    var proxyPort: Int = 8317
    var onWakeCompleted: (() -> Void)? = nil

    @State private var isWaking = false
    @State private var wakeMessage: String?
    @State private var wakeSucceeded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accountColor)
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(account.isDisabled ? Color.secondary.opacity(0.6) : Color.primary)
                        .strikethrough(account.isDisabled)
                    if let planBadge, !accountLabel.contains(planBadge) {
                        Text(planBadge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if account.isExpired {
                    Text("expired")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if account.isDisabled {
                    Text("disabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if usage?.isRefreshing == true || isWaking {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if showUsage {
                if account.isDisabled {
                    Text("Enable this account in Settings to view limits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.isExpired {
                    Text("Re-authenticate in Settings to view limits")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    usageContent
                    if canWake {
                        wakeControls
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var wakeControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                Task { await runWake() }
            } label: {
                Label(
                    isWaking ? "Waking 5h window…" : "Wake 5h window",
                    systemImage: "bolt.horizontal.circle"
                )
                .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(isWaking)
            .help("Send a tiny dummy request so the rolling 5-hour quota window starts or advances for this account.")

            if let wakeMessage {
                Text(wakeMessage)
                    .font(.caption2)
                    .foregroundStyle(wakeSucceeded == true ? MenuBarDesign.success : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runWake() async {
        await MainActor.run {
            isWaking = true
            wakeMessage = nil
            wakeSucceeded = nil
        }
        let result = await QuotaWakeService.wake(account: account, proxyPort: proxyPort)
        await MainActor.run {
            isWaking = false
            switch result {
            case .success(let message):
                wakeSucceeded = true
                wakeMessage = message
                onWakeCompleted?()
            case .failure(let message):
                wakeSucceeded = false
                wakeMessage = message
            }
        }
    }

    private var accountLabel: String {
        // Prefer plain email; plan is shown as a separate badge / sub-account rows.
        if let email = usage?.accountEmail, !email.isEmpty {
            return email
        }
        return account.baseDisplayName
    }

    private var planBadge: String? {
        if let label = usage?.planLabel, !label.isEmpty { return label }
        if let plan = usage?.planType, let pretty = ChatGPTPlanFormatter.displayName(for: plan) {
            return pretty
        }
        return account.planLabel
    }

    private var accountColor: Color {
        if account.isDisabled { return .gray }
        if account.isExpired { return .orange }
        return MenuBarDesign.success
    }

    @ViewBuilder
    private var usageContent: some View {
        if let usage {
            if let error = usage.errorMessage, !error.isEmpty, usage.windows.isEmpty, usage.subAccounts.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usage.isRefreshing && usage.windows.isEmpty && usage.subAccounts.isEmpty {
                Text("Loading limits…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !usage.subAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(usage.subAccounts) { sub in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(sub.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(tint)
                                if let subtitle = sub.subtitle, !subtitle.isEmpty {
                                    Text("· \(subtitle)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !sub.windows.isEmpty {
                                ForEach(Array(sub.windows.enumerated()), id: \.offset) { index, window in
                                    UsageQuotaRow(
                                        title: quotaTitle(window, index: index),
                                        remainingPercent: window.remainingPercent,
                                        resetText: resetText(for: window),
                                        tint: tint
                                    )
                                }
                            } else if let error = sub.errorMessage {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("No quota windows reported")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if sub.id != usage.subAccounts.last?.id {
                            Divider().opacity(0.15)
                        }
                    }
                }
            } else if !usage.windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { index, window in
                        UsageQuotaRow(
                            title: quotaTitle(window, index: index),
                            remainingPercent: window.remainingPercent,
                            resetText: resetText(for: window),
                            tint: tint
                        )
                    }
                    if let error = usage.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(usage.source.map { "Connected via \($0)" } ?? "Usage data unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Usage not loaded yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func quotaTitle(_ window: RateWindow, index: Int) -> String {
        let title = window.displayTitle
        if !title.isEmpty { return title }
        switch index {
        case 0: return "Session"
        case 1: return "Weekly"
        default: return "Limit \(index + 1)"
        }
    }

    private func resetText(for window: RateWindow) -> String? {
        if let description = window.resetDescription, !description.isEmpty {
            return description
        }
        if let resetsAt = window.resetsAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Resets \(formatter.localizedString(for: resetsAt, relativeTo: Date()))"
        }
        return nil
    }
}