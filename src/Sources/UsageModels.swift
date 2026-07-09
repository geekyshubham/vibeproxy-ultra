import Foundation

struct RateWindow: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
    /// Human-readable title such as "Claude Opus", "5-hour", or "Premium".
    let label: String?

    init(
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil,
        label: String? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.label = label
    }

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var windowLabel: String {
        if let minutes = windowMinutes, minutes > 0 {
            if minutes < 120 { return "\(minutes)m" }
            if minutes < 2880 { return "\(minutes / 60)h" }
            return "\(minutes / 1440)d"
        }
        return ""
    }

    /// Prefer an explicit label, otherwise fall back to the window duration.
    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        return windowLabel
    }
}

/// One ChatGPT workspace / subscription under a single OAuth login (e.g. Go vs Team).
struct ProviderUsageSubAccount: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let planType: String?
    let windows: [RateWindow]
    let errorMessage: String?
}

struct ProviderUsageIdentity: Codable, Equatable {
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
}

struct ProviderUsagePayload: Codable, Equatable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let updatedAt: Date?
    let identity: ProviderUsageIdentity?
    let accountEmail: String?
}

struct ProviderUsageSnapshot: Equatable, Identifiable {
    let id: String
    let providerID: String
    let source: String?
    /// Ordered quota rows shown in the UI (most important first).
    let windows: [RateWindow]
    /// Multi-subscription rows (ChatGPT Go + Team/Enterprise under one login).
    let subAccounts: [ProviderUsageSubAccount]
    let accountEmail: String?
    /// Raw plan token such as "go", "team", "enterprise".
    let planType: String?
    /// Pretty plan / workspace label for the primary row.
    let planLabel: String?
    let updatedAt: Date?
    let errorMessage: String?
    let isRefreshing: Bool

    var primary: RateWindow? { windows.first }
    var secondary: RateWindow? { windows.count > 1 ? windows[1] : nil }
    var tertiary: RateWindow? { windows.count > 2 ? windows[2] : nil }

    init(
        id: String,
        providerID: String,
        source: String? = nil,
        windows: [RateWindow] = [],
        subAccounts: [ProviderUsageSubAccount] = [],
        accountEmail: String? = nil,
        planType: String? = nil,
        planLabel: String? = nil,
        updatedAt: Date? = nil,
        errorMessage: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.source = source
        self.windows = windows
        self.subAccounts = subAccounts
        self.accountEmail = accountEmail
        self.planType = planType
        self.planLabel = planLabel
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
    }

    /// Back-compat constructor used by existing call sites during migration.
    init(
        id: String,
        providerID: String,
        source: String?,
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?,
        accountEmail: String?,
        updatedAt: Date?,
        errorMessage: String?,
        isRefreshing: Bool
    ) {
        self.init(
            id: id,
            providerID: providerID,
            source: source,
            windows: [primary, secondary, tertiary].compactMap { $0 },
            subAccounts: [],
            accountEmail: accountEmail,
            planType: nil,
            planLabel: nil,
            updatedAt: updatedAt,
            errorMessage: errorMessage,
            isRefreshing: isRefreshing
        )
    }

    static func empty(
        authAccountID: String,
        providerID: String,
        accountEmail: String? = nil,
        error: String? = nil,
        refreshing: Bool = false
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: authAccountID,
            providerID: providerID,
            source: nil,
            windows: [],
            subAccounts: [],
            accountEmail: accountEmail,
            planType: nil,
            planLabel: nil,
            updatedAt: nil,
            errorMessage: error,
            isRefreshing: refreshing
        )
    }
}

struct ProviderCostSnapshot: Equatable, Identifiable {
    let id: String
    let providerID: String
    let sessionTokens: Int
    let sessionCostUSD: Double?
    let last30DaysTokens: Int
    let last30DaysCostUSD: Double?
    let updatedAt: Date?
}

enum ChatGPTPlanFormatter {
    /// Human-readable plan names for Codex / ChatGPT subscription types.
    static func displayName(for planType: String?) -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "go": return "ChatGPT Go"
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "enterprise": return "ChatGPT Enterprise"
        case "business": return "ChatGPT Business"
        case "free": return "ChatGPT Free"
        case "edu", "education": return "ChatGPT Education"
        case "api_key", "api-key": return "API Key"
        default:
            return planType
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    static func subscriptionTitle(planType: String?, workspaceName: String?, structure: String?) -> String {
        let plan = displayName(for: planType) ?? "ChatGPT"
        if let workspaceName, !workspaceName.isEmpty {
            return "\(plan) · \(workspaceName)"
        }
        if let structure, structure.lowercased() == "workspace" {
            return "\(plan) (workspace)"
        }
        if let structure, structure.lowercased() == "personal" {
            return "\(plan) (personal)"
        }
        return plan
    }
}

extension ServiceType {
    var usageProviderID: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .copilot: return "copilot"
        case .antigravity: return "antigravity"
        case .kimi: return "kimi"
        case .kiro: return "kiro"
        case .grok: return "grok"
        case .zai: return "zai"
        case .cursor: return "cursor"
        case .codebuddy: return "codebuddy"
        case .gitlab: return "gitlab"
        case .kilo: return "kilo"
        case .qwen: return nil
        }
    }
}
