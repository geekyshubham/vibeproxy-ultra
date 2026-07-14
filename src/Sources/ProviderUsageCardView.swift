import SwiftUI

struct ProviderUsageCardView: View {
    let serviceType: ServiceType
    let accounts: [AuthAccount]
    let usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?
    let cost: ProviderCostSnapshot?
    let isProviderEnabled: Bool
    /// Live operational status for this provider (nil = no feed).
    var statusLevel: ProviderStatusLevel? = nil
    var proxyPort: Int = 8317
    var onWakeCompleted: ((AuthAccount) -> Void)? = nil
    /// Detects/switches the live native session (nil disables the Switch UI).
    var nativeSession: NativeSessionManager? = nil
    /// Called after a successful account switch so the parent can re-detect.
    var onSwitchAccount: ((AuthAccount) -> Void)? = nil
    /// When many providers are shown, start collapsed if this is true.
    var startCollapsed: Bool = false

    private var tint: Color { MenuBarDesign.providerTint(for: serviceType) }

    /// Multi-account providers start collapsed; single-account ones open with details.
    @State private var isProviderExpanded = false
    @State private var expandedAccountID: String?
    @State private var showAllAccounts = false

    /// Compact rows only when there are multiple accounts (one account shows full detail).
    private var usesCompactList: Bool { accounts.count > 1 }

    private var isSingleAccount: Bool { accounts.count == 1 }

    private var sortedAccounts: [AuthAccount] {
        accounts.sorted { lhs, rhs in
            // Active first, then by highest usage pressure, then name.
            let lRank = accountSortRank(lhs)
            let rRank = accountSortRank(rhs)
            if lRank != rRank { return lRank < rRank }
            let lUsed = peakUsed(lhs)
            let rUsed = peakUsed(rhs)
            if lUsed != rUsed { return lUsed > rUsed }
            return accountLabel(for: lhs).localizedCaseInsensitiveCompare(accountLabel(for: rhs)) == .orderedAscending
        }
    }

    private var activeAccounts: [AuthAccount] {
        accounts.filter { !$0.isDisabled && !$0.isExpired }
    }

    private var visibleAccounts: [AuthAccount] {
        let sorted = sortedAccounts
        if showAllAccounts || !usesCompactList { return sorted }
        // Show top 3 by priority when collapsed list; expand to see rest.
        return Array(sorted.prefix(3))
    }

    private var hiddenCount: Int {
        max(0, sortedAccounts.count - visibleAccounts.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isProviderExpanded {
                if accounts.isEmpty {
                    Text("No accounts connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    accountsSection
                    if hiddenCount > 0 {
                        Button {
                            withAnimation(DS.Motion.expand) { showAllAccounts = true }
                        } label: {
                            Text("Show \(hiddenCount) more account\(hiddenCount == 1 ? "" : "s")…")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                        }
                        .buttonStyle(.plain)
                    } else if showAllAccounts && usesCompactList && sortedAccounts.count > 3 {
                        Button {
                            withAnimation(DS.Motion.expand) {
                                showAllAccounts = false
                                // Keep selection if still visible
                                if let id = expandedAccountID,
                                   !visibleAccounts.contains(where: { $0.id == id })
                                {
                                    expandedAccountID = visibleAccounts.first?.id
                                }
                            }
                        } label: {
                            Text("Show fewer")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isProviderEnabled {
                    costSection
                }
            } else {
                // Collapsed summary chips
                collapsedSummary
            }
        }
        .padding(MenuBarDesign.cardPadding)
        .cardSurface(tint: tint)
        .hoverHighlight(tint)
        .onAppear {
            showAllAccounts = false
            if isSingleAccount {
                // One account: expand provider and show full usage immediately.
                isProviderExpanded = true
                expandedAccountID = accounts.first?.id
            } else {
                // Multiple accounts: everything collapsed until the user opens it.
                isProviderExpanded = false
                expandedAccountID = nil
            }
            _ = startCollapsed
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(DS.Motion.expand) {
                isProviderExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                // Operational status dot (green / yellow / red) beside the provider.
                Circle()
                    .fill(MenuBarDesign.statusDotColor(statusLevel))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .help(MenuBarDesign.statusDotHelp(statusLevel))
                    .accessibilityLabel(MenuBarDesign.statusDotHelp(statusLevel))

                providerIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(serviceType.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let statusLevel {
                            Text(statusLevel.displayName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MenuBarDesign.statusDotColor(statusLevel))
                                .lineLimit(1)
                        }
                    }
                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                statusBadge
                Image(systemName: isProviderExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isProviderExpanded ? "Collapse provider" : "Expand provider")
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
        let pressure = peakUsedAcrossAccounts
        var parts: [String] = []
        if active == accounts.count {
            parts.append("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
        } else {
            parts.append("\(active) active · \(accounts.count) total")
        }
        if pressure > 0 {
            parts.append("peak \(Int(pressure.rounded()))% used")
        }
        return parts.joined(separator: " · ")
    }

    private var peakUsedAcrossAccounts: Double {
        accounts.map { peakUsed($0) }.max() ?? 0
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
        } else if peakUsedAcrossAccounts >= 90 {
            Text("Hot")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MenuBarDesign.danger.opacity(0.18), in: Capsule())
                .foregroundStyle(MenuBarDesign.danger)
        }
    }

    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sortedAccounts.prefix(4)) { account in
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(for: account))
                        .frame(width: 5, height: 5)
                    Text(accountLabel(for: account))
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let summary = compactUsageSummary(for: account) {
                        Text(summary)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(MenuBarDesign.usageTint(remainingPercent: 100 - peakUsed(account)))
                    }
                }
            }
            if sortedAccounts.count > 4 {
                Text("+\(sortedAccounts.count - 4) more — expand to manage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleAccounts) { account in
                let isExpanded = !usesCompactList || expandedAccountID == account.id
                AccountUsageBlock(
                    account: account,
                    usage: usageForAccount(account),
                    tint: tint,
                    showUsage: isProviderEnabled,
                    compact: usesCompactList && !isExpanded,
                    isExpanded: isExpanded,
                    canWake: isProviderEnabled
                        && !account.isDisabled
                        && !account.isExpired
                        && QuotaWakeService.shouldShowWake(
                            for: serviceType,
                            usage: usageForAccount(account)
                        ),
                    serviceType: serviceType,
                    nativeSession: nativeSession,
                    proxyPort: proxyPort,
                    onToggleExpand: usesCompactList ? {
                        withAnimation(DS.Motion.expand) {
                            if expandedAccountID == account.id {
                                expandedAccountID = nil
                            } else {
                                expandedAccountID = account.id
                            }
                        }
                    } : nil,
                    onWakeCompleted: { onWakeCompleted?(account) },
                    onSwitchAccount: { onSwitchAccount?(account) }
                )

                if account.id != visibleAccounts.last?.id {
                    Divider().opacity(0.15)
                }
            }
        }
    }

    // MARK: - Cost

    @ViewBuilder
    private var costSection: some View {
        if let cost, cost.sessionTokens > 0 || cost.last30DaysTokens > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Divider().opacity(0.2)
                HStack {
                    Text(cost.volumeUnit == .credits ? "Credits & est. cost" : "Tokens & est. cost")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("local logs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    if cost.sessionTokens > 0 {
                        costPill(label: "Today", volume: cost.sessionTokens, unit: cost.volumeUnit, usd: cost.sessionCostUSD)
                    }
                    if cost.last30DaysTokens > 0 {
                        costPill(label: "30d", volume: cost.last30DaysTokens, unit: cost.volumeUnit, usd: cost.last30DaysCostUSD)
                    }
                }
                if let top = cost.models.first {
                    Text("Top model: \(top.model) · \(formatVolume(top.totalTokens, unit: top.volumeUnit))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
    }

    private func costPill(label: String, volume: Int, unit: UsageVolumeUnit, usd: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(formatVolume(volume, unit: unit))
                .font(.caption.weight(.semibold).monospacedDigit())
            if let usd, AppSettings.shared.showCostEstimates {
                Text(formatUSD(usd))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
            }
        }
    }

    private func formatVolume(_ count: Int, unit: UsageVolumeUnit) -> String {
        switch unit {
        case .credits:
            let credits = Double(count) / 1000.0
            if credits >= 1000 { return String(format: "%.1fK cr", credits / 1000) }
            if credits >= 10 { return String(format: "%.0f cr", credits) }
            if credits >= 1 { return String(format: "%.1f cr", credits) }
            if credits > 0 { return String(format: "%.2f cr", credits) }
            return "0 cr"
        case .estimatedTokens:
            return formatTokens(count) + " est"
        case .tokens:
            return formatTokens(count)
        }
    }

    // MARK: - Helpers

    private func accountSortRank(_ account: AuthAccount) -> Int {
        if account.isExpired { return 2 }
        if account.isDisabled { return 1 }
        return 0
    }

    private func peakUsed(_ account: AuthAccount) -> Double {
        guard let usage = usageForAccount(account) else { return 0 }
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        return windows.map(\.usedPercent).max() ?? 0
    }

    private func accountLabel(for account: AuthAccount) -> String {
        if let email = usageForAccount(account)?.accountEmail, !email.isEmpty { return email }
        return account.baseDisplayName
    }

    private func compactUsageSummary(for account: AuthAccount) -> String? {
        if account.isExpired { return "expired" }
        if account.isDisabled { return "off" }
        let used = peakUsed(account)
        if used <= 0 {
            if usageForAccount(account)?.isRefreshing == true { return "…" }
            return nil
        }
        return "\(Int(used.rounded()))%"
    }

    private func dotColor(for account: AuthAccount) -> Color {
        if account.isDisabled { return .gray }
        if account.isExpired { return .orange }
        let used = peakUsed(account)
        return MenuBarDesign.usageTint(remainingPercent: 100 - used)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatUSD(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
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

// MARK: - Account row

private struct AccountUsageBlock: View {
    let account: AuthAccount
    let usage: ProviderUsageSnapshot?
    let tint: Color
    let showUsage: Bool
    var compact: Bool = false
    var isExpanded: Bool = true
    var canWake: Bool = false
    var serviceType: ServiceType = .codex
    var nativeSession: NativeSessionManager? = nil
    var proxyPort: Int = 8317
    var onToggleExpand: (() -> Void)? = nil
    var onWakeCompleted: (() -> Void)? = nil
    var onSwitchAccount: (() -> Void)? = nil

    @State private var isWaking = false
    @State private var wakeMessage: String?
    @State private var wakeSucceeded: Bool?
    @State private var isSwitching = false
    @State private var switchMessage: String?
    @State private var switchSucceeded: Bool?
    @State private var pendingSwitchConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always-visible header row (tap to expand in compact mode)
            Button {
                onToggleExpand?()
            } label: {
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
                        if !compact, let planBadge, !accountLabel.contains(planBadge) {
                            Text(planBadge)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(tint)
                                .lineLimit(1)
                        } else if compact, let oneLiner = compactOneLiner {
                            Text(oneLiner)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    currentChip
                    trailingBadges
                    if onToggleExpand != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onToggleExpand == nil)

            if isExpanded && showUsage {
                if account.isDisabled {
                    Text("Enable this account in Settings to view limits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.isExpired {
                    Text("Re-authenticate in Settings to view limits")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    if let planBadge, !accountLabel.contains(planBadge) {
                        Text(planBadge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                    usageContent
                    if canWake {
                        wakeControls
                    }
                    switchControls
                }
            }
        }
    }

    @ViewBuilder
    private var trailingBadges: some View {
        if account.isExpired {
            Text("expired")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if account.isDisabled {
            Text("off")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if usage?.isRefreshing == true || isWaking {
            ProgressView()
                .controlSize(.mini)
        } else if let used = peakUsed, used > 0 {
            Text("\(Int(used.rounded()))%")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(MenuBarDesign.usageTint(remainingPercent: 100 - used))
                .help("Peak window usage")
        }
    }

    private var compactOneLiner: String? {
        if account.isExpired { return "needs re-auth" }
        if account.isDisabled { return "disabled" }
        if let resets = usage?.rateLimitResets, resets.availableCount > 0 {
            return "\(resets.availableCount) reset\(resets.availableCount == 1 ? "" : "s") left"
        }
        if let plan = planBadge { return plan }
        if let reset = nextResetText { return reset }
        return nil
    }

    private var peakUsed: Double? {
        guard let usage else { return nil }
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        guard !windows.isEmpty else { return nil }
        return windows.map(\.usedPercent).max()
    }

    private var nextResetText: String? {
        guard let usage else { return nil }
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        guard let soonest = windows.compactMap(\.resetsAt).min() else { return nil }
        return "resets \(ResetCountdownFormatter.countdown(until: soonest))"
    }

    @ViewBuilder
    private var wakeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { @MainActor in await runWake() }
            } label: {
                HStack(spacing: 6) {
                    if isWaking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt.horizontal.circle.fill")
                    }
                    Text(isWaking ? "Waking 5h window…" : "Wake 5h window")
                        .font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(tint)
            .disabled(isWaking)
            .contentShape(Rectangle())
            .help("Send a tiny dummy request so the rolling 5-hour quota window starts or advances for this account.")

            if let wakeMessage {
                Text(wakeMessage)
                    .font(.caption2)
                    .foregroundStyle(wakeSucceeded == true ? MenuBarDesign.success : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @MainActor
    private func runWake() async {
        isWaking = true
        wakeMessage = "Sending dummy request…"
        wakeSucceeded = nil

        let accountSnapshot = account
        let port = proxyPort
        let result = await Task.detached(priority: .userInitiated) {
            await QuotaWakeService.wake(account: accountSnapshot, proxyPort: port)
        }.value

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

    // MARK: - Native session switching

    private var multiSubscription: Bool {
        (usage?.subAccounts.count ?? 0) >= 2 && serviceType == .codex
    }

    private var isCurrentNative: Bool {
        // For multi-sub Codex, the login may be "current" while a *different* workspace
        // is pinned — don't show a single Active chip that hides subscription switches.
        if multiSubscription { return false }
        return nativeSession?.isCurrent(account) ?? false
    }

    private var canSwitch: Bool {
        guard let ns = nativeSession, ns.supportsSwitching(serviceType) else { return false }
        return !account.isExpired && !account.isDisabled && !isCurrentNative
    }

    private func isActiveSubscription(_ sub: ProviderUsageSubAccount) -> Bool {
        nativeSession?.isCurrentSubscription(account, chatGPTAccountID: sub.id) ?? false
    }

    private func canSwitchSubscription(_ sub: ProviderUsageSubAccount) -> Bool {
        guard let ns = nativeSession, ns.supportsSwitching(serviceType) else { return false }
        guard !account.isExpired, !account.isDisabled else { return false }
        return !isActiveSubscription(sub)
    }

    @ViewBuilder
    private var currentChip: some View {
        if multiSubscription, let active = usage?.subAccounts.first(where: { isActiveSubscription($0) }) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 8))
                Text(active.title).font(.system(size: 9, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(MenuBarDesign.success)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MenuBarDesign.success.opacity(0.16), in: Capsule())
            .help("Native \(serviceType.displayName) is on this subscription.")
        } else if isCurrentNative {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 8))
                Text("Active").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(MenuBarDesign.success)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MenuBarDesign.success.opacity(0.16), in: Capsule())
            .help("This account is the live session in the native \(serviceType.displayName) app on this Mac.")
        }
    }

    @ViewBuilder
    private var switchControls: some View {
        // Multi-subscription: per-sub rows have their own Switch buttons.
        if multiSubscription {
            if let switchMessage {
                Text(switchMessage)
                    .font(.caption2)
                    .foregroundStyle(switchSucceeded == true ? MenuBarDesign.success : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else if isCurrentNative {
            Label("Current Mac session", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(MenuBarDesign.success)
        } else if canSwitch {
            VStack(alignment: .leading, spacing: 4) {
                if pendingSwitchConfirm {
                    HStack(spacing: 6) {
                        Text("Make this the active session?")
                            .font(.caption2)
                        Spacer(minLength: 0)
                        Button("Cancel") { pendingSwitchConfirm = false }
                            .buttonStyle(.plain)
                            .font(.caption2)
                        Button("Switch") {
                            pendingSwitchConfirm = false
                            Task { @MainActor in await performSwitch(chatGPTAccountID: nil, label: nil) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(tint)
                    }
                } else {
                    Button {
                        if AppSettings.shared.confirmBeforeSwitch {
                            pendingSwitchConfirm = true
                        } else {
                            Task { @MainActor in await performSwitch(chatGPTAccountID: nil, label: nil) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSwitching {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.left.arrow.right.circle.fill")
                            }
                            Text(isSwitching ? "Switching…" : "Switch to this account")
                                .font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(tint)
                    .disabled(isSwitching)
                    .help("Make this the active \(serviceType.displayName) session on this Mac (writes native auth, kills & relaunches the desktop app like Cockpit).")
                }

                if let switchMessage {
                    Text(switchMessage)
                        .font(.caption2)
                        .foregroundStyle(switchSucceeded == true ? MenuBarDesign.success : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func subscriptionSwitchControls(for sub: ProviderUsageSubAccount) -> some View {
        if isActiveSubscription(sub) {
            Label("Active subscription", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(MenuBarDesign.success)
        } else if canSwitchSubscription(sub) {
            Button {
                Task { @MainActor in
                    await performSwitch(chatGPTAccountID: sub.id, label: sub.title)
                }
            } label: {
                HStack(spacing: 6) {
                    if isSwitching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                    }
                    Text(isSwitching ? "Switching…" : "Switch to \(sub.title)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(tint)
            .disabled(isSwitching)
            .help("Pin this ChatGPT subscription (writes tokens.account_id=\(sub.id)) and restart Codex so it uses \(sub.title), not Go.")
        }
    }

    @MainActor
    private func performSwitch(chatGPTAccountID: String?, label: String?) async {
        guard let ns = nativeSession else { return }
        isSwitching = true
        switchMessage = nil
        switchSucceeded = nil
        let result = await ns.switchTo(
            account,
            chatGPTAccountID: chatGPTAccountID,
            subscriptionLabel: label,
            restartApp: AppSettings.shared.restartAppOnSwitch
        )
        isSwitching = false
        switch result {
        case .switched(let message):
            switchSucceeded = true
            switchMessage = message
            onSwitchAccount?()
        case .failure(let message):
            switchSucceeded = false
            switchMessage = message
        }
    }

    private var accountLabel: String {
        // Always prefer the auth-file identity so multi-account lists stay distinct.
        // (Usage payloads can stamp a shared SuperGrok email onto every Grok row.)
        let fromFile = account.baseDisplayName
        if !fromFile.isEmpty, fromFile != account.id {
            return fromFile
        }
        if let email = usage?.accountEmail, !email.isEmpty { return email }
        return fromFile
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
        if let used = peakUsed {
            return MenuBarDesign.usageTint(remainingPercent: 100 - used)
        }
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
                    if let resets = usage.rateLimitResets {
                        rateLimitResetsBadge(resets, tint: tint)
                    }
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
                                Spacer(minLength: 0)
                                if isActiveSubscription(sub) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(MenuBarDesign.success)
                                        .help("Native Codex is pinned to this subscription")
                                }
                            }
                            if !sub.windows.isEmpty {
                                ForEach(Array(sub.windows.enumerated()), id: \.offset) { index, window in
                                    UsageQuotaRow(
                                        title: quotaTitle(window, index: index),
                                        usedPercent: window.usedPercent,
                                        resetText: resetText(for: window),
                                        tint: tint,
                                        metricText: window.primaryMetricText
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
                            // One Switch per subscription so Go vs Team/Enterprise is explicit.
                            if multiSubscription {
                                subscriptionSwitchControls(for: sub)
                            }
                        }
                        if sub.id != usage.subAccounts.last?.id {
                            Divider().opacity(0.15)
                        }
                    }
                }
            } else if !usage.windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let resets = usage.rateLimitResets {
                        rateLimitResetsBadge(resets, tint: tint)
                    }
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { index, window in
                        UsageQuotaRow(
                            title: quotaTitle(window, index: index),
                            usedPercent: window.usedPercent,
                            resetText: resetText(for: window),
                            tint: tint,
                            metricText: window.primaryMetricText
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
            return ResetCountdownFormatter.resetLine(for: resetsAt)
        }
        return nil
    }

    /// Cockpit-style chip: how many manual ChatGPT/Codex rate-limit resets remain.
    @ViewBuilder
    private func rateLimitResetsBadge(_ resets: CodexRateLimitResetCredits, tint: Color) -> some View {
        let hasResets = resets.availableCount > 0
        HStack(spacing: 8) {
            Image(systemName: hasResets ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasResets ? tint : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(resets.summaryLine)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hasResets ? .primary : .secondary)
                if let title = resets.sampleTitle, !title.isEmpty, hasResets {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hasResets ? tint.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hasResets ? tint.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("Manual rate-limit resets from ChatGPT/Codex (same inventory as Cockpit Tools)")
    }
}
