import Foundation

enum ServiceType: String, CaseIterable {
    case claude
    case codex
    case copilot = "github-copilot"
    case gemini
    case kimi
    case qwen
    case antigravity
    case kiro
    case grok = "xai"
    case zai
    /// CLIProxy OAuth providers also managed by Cockpit Tools
    case cursor
    case codebuddy
    case gitlab
    case kilo
    
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .copilot: return "GitHub Copilot"
        case .gemini: return "Gemini"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .antigravity: return "Antigravity"
        case .kiro: return "Kiro"
        case .grok: return "Grok"
        case .zai: return "Z.AI GLM"
        case .cursor: return "Cursor"
        case .codebuddy: return "CodeBuddy"
        case .gitlab: return "GitLab Duo"
        case .kilo: return "Kilo AI"
        }
    }
}

/// Represents a single authenticated account
struct AuthAccount: Identifiable, Equatable {
    let id: String  // filename
    let email: String?
    let login: String?  // for Copilot
    let type: ServiceType
    let expired: Date?
    let filePath: URL
    let isDisabled: Bool
    /// Subscription / plan label when known (e.g. "ChatGPT Go", "ChatGPT Team").
    let planLabel: String?

    init(
        id: String,
        email: String?,
        login: String?,
        type: ServiceType,
        expired: Date?,
        filePath: URL,
        isDisabled: Bool,
        planLabel: String? = nil
    ) {
        self.id = id
        self.email = email
        self.login = login
        self.type = type
        self.expired = expired
        self.filePath = filePath
        self.isDisabled = isDisabled
        self.planLabel = planLabel
    }
    
    var isExpired: Bool {
        guard let expired = expired else { return false }
        return expired < Date()
    }
    
    var displayName: String {
        let base: String
        if let email = email, !email.isEmpty {
            base = email
        } else if let login = login, !login.isEmpty {
            base = login
        } else {
            base = id
        }
        if let planLabel, !planLabel.isEmpty {
            return "\(base) · \(planLabel)"
        }
        return base
    }

    /// Identity without plan suffix (for matching imports / emails).
    var baseDisplayName: String {
        if let email = email, !email.isEmpty { return email }
        if let login = login, !login.isEmpty { return login }
        return id
    }
    
    static func == (lhs: AuthAccount, rhs: AuthAccount) -> Bool {
        lhs.id == rhs.id
            && lhs.isDisabled == rhs.isDisabled
            && lhs.planLabel == rhs.planLabel
            && lhs.email == rhs.email
    }
}

/// Tracks all accounts for a service type
struct ServiceAccounts: Equatable {
    var type: ServiceType
    var accounts: [AuthAccount] = []
    
    var hasAccounts: Bool { !accounts.isEmpty }
    var activeCount: Int { accounts.filter { !$0.isExpired }.count }
    var expiredCount: Int { accounts.filter { $0.isExpired }.count }
}

class AuthManager: ObservableObject {
    @Published var serviceAccounts: [ServiceType: ServiceAccounts] = [:]
    
    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [withFractional, standard]
    }()
    
    init() {
        // Initialize empty accounts for all service types
        for type in ServiceType.allCases {
            serviceAccounts[type] = ServiceAccounts(type: type)
        }
    }
    
    func accounts(for type: ServiceType) -> [AuthAccount] {
        serviceAccounts[type]?.accounts ?? []
    }
    
    func hasAccounts(for type: ServiceType) -> Bool {
        serviceAccounts[type]?.hasAccounts ?? false
    }
    
    func checkAuthStatus() {
        let scanned = scanAuthDirectory()
        applyAccounts(scanned)
    }

    private func scanAuthDirectory() -> [ServiceType: [AuthAccount]] {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")

        var newAccounts: [ServiceType: [AuthAccount]] = [:]
        for type in ServiceType.allCases {
            newAccounts[type] = []
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil)
            NSLog("[AuthStatus] Scanning %d files in auth directory", files.count)

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      let serviceType = ServiceType(rawValue: type.lowercased())
                else {
                    continue
                }

                let email = json["email"] as? String
                let login = json["login"] as? String ?? json["username"] as? String
                let isDisabled = json["disabled"] as? Bool ?? false
                let planLabel = Self.extractPlanLabel(from: json, serviceType: serviceType)

                // IMPORTANT: `expired` / `expires_at` in auth files is usually the short-lived
                // *access token* expiry (~1h). CLIProxy refreshes via refresh_token automatically.
                // Only treat the account as needing re-auth when the session cannot be refreshed.
                let expiredDate = Self.sessionExpiryDate(from: json, serviceType: serviceType)

                let account = AuthAccount(
                    id: file.lastPathComponent,
                    email: email,
                    login: login,
                    type: serviceType,
                    expired: expiredDate,
                    filePath: file,
                    isDisabled: isDisabled,
                    planLabel: planLabel
                )

                newAccounts[serviceType]?.append(account)
                NSLog("[AuthStatus] Found %@ auth: %@", serviceType.displayName, account.displayName)
            }
        } catch {
            NSLog("[AuthStatus] Error checking auth status: %@", error.localizedDescription)
        }

        return newAccounts
    }

    private func applyAccounts(_ newAccounts: [ServiceType: [AuthAccount]]) {
        let update = {
            for type in ServiceType.allCases {
                self.serviceAccounts[type] = ServiceAccounts(
                    type: type,
                    accounts: newAccounts[type] ?? []
                )
            }
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
    
    /// Toggle the disabled state of a specific account's auth file
    func toggleAccountDisabled(_ account: AuthAccount) -> Bool {
        do {
            let data = try Data(contentsOf: account.filePath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[AuthStatus] Failed to parse auth file as JSON: %@", account.filePath.path)
                return false
            }
            let currentlyDisabled = json["disabled"] as? Bool ?? false
            if !currentlyDisabled {
                let enabledCount = serviceAccounts[account.type]?.accounts.filter { !$0.isDisabled }.count ?? 0
                guard enabledCount > 1 else {
                    NSLog("[AuthStatus] Refusing to disable last enabled account for %@", account.type.rawValue)
                    return false
                }
            }
            json["disabled"] = !currentlyDisabled
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try updatedData.write(to: account.filePath, options: .atomic)
            NSLog("[AuthStatus] Toggled disabled=%d for: %@", !currentlyDisabled, account.filePath.path)
            checkAuthStatus()
            return true
        } catch {
            NSLog("[AuthStatus] Failed to toggle disabled state: %@", error.localizedDescription)
            return false
        }
    }
    
    /// Delete a specific account's auth file
    func deleteAccount(_ account: AuthAccount) -> Bool {
        do {
            try FileManager.default.removeItem(at: account.filePath)
            NSLog("[AuthStatus] Deleted auth file: %@", account.filePath.path)
            // Refresh status
            checkAuthStatus()
            return true
        } catch {
            NSLog("[AuthStatus] Failed to delete auth file: %@", error.localizedDescription)
            return false
        }
    }

    /// Returns a date only when the *session* is truly unusable (needs re-login).
    /// Access-token timestamps alone do not count if a refresh token is present.
    private static func sessionExpiryDate(from json: [String: Any], serviceType: ServiceType) -> Date? {
        // API-key providers never expire from access-token clocks.
        if serviceType == .zai {
            return nil
        }

        let refreshToken = nonEmptyString(json["refresh_token"])
            ?? nonEmptyString(json["refreshToken"])
            ?? nonEmptyString(json["refresh"])

        // If the proxy can refresh, ignore short-lived access token expiry for UI/usage.
        if let refreshToken {
            // Only mark expired when the refresh token itself is past JWT exp (rare).
            if let refreshExp = jwtExpiry(from: refreshToken), refreshExp < Date() {
                return refreshExp
            }
            return nil
        }

        // No refresh token: session dies with the access token (or stored expiry).
        if let access = nonEmptyString(json["access_token"])
            ?? nonEmptyString(json["accessToken"])
            ?? nonEmptyString(json["key"]),
           let accessExp = jwtExpiry(from: access)
        {
            return accessExp
        }

        return parseDateString(json["expired"] as? String)
            ?? parseDateString(json["expires_at"] as? String)
            ?? parseDateString(json["expiresAt"] as? String)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDateString(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        // Some files use "yyyy-MM-dd'T'HH:mm:ssZ" without colon in offset, already covered by ISO8601.
        // Fallback: epoch seconds / millis encoded as string.
        if let epoch = Double(value) {
            if epoch > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: epoch / 1000)
            }
            if epoch > 1_000_000_000 {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        return nil
    }

    private static func jwtExpiry(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let exp = json["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = json["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let exp = json["exp"] as? String, let value = Double(exp) {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    /// Best-effort plan label from stored auth JSON / JWT (no network).
    private static func extractPlanLabel(from json: [String: Any], serviceType: ServiceType) -> String? {
        switch serviceType {
        case .codex:
            if let plan = json["plan_type"] as? String, !plan.isEmpty {
                return ChatGPTPlanFormatter.displayName(for: plan)
            }
            let token = (json["access_token"] as? String) ?? (json["id_token"] as? String)
            if let plan = planTypeFromOpenAIJWT(token) {
                return ChatGPTPlanFormatter.displayName(for: plan)
            }
            return nil
        case .copilot:
            if let plan = json["plan_type"] as? String ?? json["copilot_plan"] as? String {
                return plan
            }
            return nil
        default:
            if let plan = json["plan_type"] as? String, !plan.isEmpty {
                return plan
            }
            return nil
        }
    }

    private static func planTypeFromOpenAIJWT(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String,
           !plan.isEmpty
        {
            return plan
        }
        if let plan = json["chatgpt_plan_type"] as? String, !plan.isEmpty {
            return plan
        }
        return nil
    }
}
