import Foundation

enum NativeUsageFetcher {
    static func fetchUsage(
        for serviceType: ServiceType,
        authFile: URL,
        authAccountID: String
    ) async -> ProviderUsageSnapshot {
        let providerID = serviceType.usageProviderID ?? serviceType.rawValue

        guard var payload = readAuthPayload(at: authFile) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not read auth credentials")
        }

        payload = enrichPayload(payload, for: serviceType)

        switch serviceType {
        case .codex:
            return await fetchCodexUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .claude:
            return await fetchClaudeUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .copilot:
            return await fetchCopilotUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .gemini:
            return await fetchGeminiUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .antigravity:
            return await fetchAntigravityUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .grok:
            return await fetchGrokUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .kiro:
            return await fetchKiroUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .zai:
            return await fetchZaiUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .kimi:
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                error: "Live usage limits are not available for Kimi yet"
            )
        case .qwen, .cursor, .codebuddy, .gitlab, .kilo:
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: stringValue(payload, keys: ["email", "username", "login"]),
                error: nil
            )
        }
    }

    static func fetchCost(for serviceType: ServiceType) async -> ProviderCostSnapshot? {
        switch serviceType {
        case .codex:
            return LocalTokenCostScanner.codexSnapshot()
        case .claude:
            return LocalTokenCostScanner.claudeSnapshot()
        default:
            return nil
        }
    }

    /// Prefer refresh-aware messaging: short-lived access tokens are not a full logout.
    private static func sessionInvalidMessage(
        payload: [String: Any],
        reauthHint: String = "re-authenticate in Settings"
    ) -> String {
        let hasRefresh = stringValue(payload, keys: ["refresh_token", "refreshToken", "refresh"]) != nil
        if hasRefresh {
            return "Access token is refreshing — try again in a moment (no re-login needed)"
        }
        return "Session expired — \(reauthHint)"
    }

    // MARK: - Codex

    private static func fetchCodexUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let storedAccountID = stringValue(payload, keys: ["account_id"])
            ?? chatgptAccountIDFromJWT(accessToken)
            ?? chatgptAccountIDFromJWT(stringValue(payload, keys: ["id_token"]))
        let email = stringValue(payload, keys: ["email"])
            ?? JWTEmailExtractor.email(from: stringValue(payload, keys: ["id_token"]))
            ?? JWTEmailExtractor.email(from: accessToken)
        let jwtPlan = chatgptPlanTypeFromJWT(accessToken)
            ?? chatgptPlanTypeFromJWT(stringValue(payload, keys: ["id_token"]))

        // One OAuth login can own multiple ChatGPT subscriptions/workspaces (Go + Team/Enterprise).
        let memberships = await fetchChatGPTAccountMemberships(accessToken: accessToken)
        let targets = codexUsageTargets(
            memberships: memberships,
            storedAccountID: storedAccountID,
            jwtPlan: jwtPlan
        )

        var subAccounts: [ProviderUsageSubAccount] = []
        for target in targets {
            if let result = await requestCodexUsagePayload(
                accessToken: accessToken,
                chatGPTAccountID: target.accountID
            ) {
                let planType = result.planType ?? target.planType ?? jwtPlan
                let title = ChatGPTPlanFormatter.subscriptionTitle(
                    planType: planType,
                    workspaceName: target.workspaceName,
                    structure: target.structure
                )
                subAccounts.append(
                    ProviderUsageSubAccount(
                        id: target.accountID ?? title,
                        title: title,
                        subtitle: codexMembershipSubtitle(structure: target.structure, role: target.role),
                        planType: planType,
                        windows: result.windows,
                        errorMessage: nil
                    )
                )
            } else {
                let title = ChatGPTPlanFormatter.subscriptionTitle(
                    planType: target.planType ?? jwtPlan,
                    workspaceName: target.workspaceName,
                    structure: target.structure
                )
                subAccounts.append(
                    ProviderUsageSubAccount(
                        id: target.accountID ?? title,
                        title: title,
                        subtitle: codexMembershipSubtitle(structure: target.structure, role: target.role),
                        planType: target.planType ?? jwtPlan,
                        windows: [],
                        errorMessage: "Could not load limits for this subscription"
                    )
                )
            }
        }

        // Prefer showing every discovered subscription when there are 2+ memberships.
        if subAccounts.count >= 2 {
            let primary = subAccounts.first(where: { !$0.windows.isEmpty }) ?? subAccounts[0]
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: primary.windows,
                subAccounts: subAccounts,
                accountEmail: email,
                planType: primary.planType,
                planLabel: primary.title,
                updatedAt: Date(),
                errorMessage: subAccounts.allSatisfy({ $0.windows.isEmpty })
                    ? "Could not fetch Codex usage limits"
                    : nil,
                isRefreshing: false
            )
        }

        if let only = subAccounts.first, !only.windows.isEmpty {
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: only.windows,
                subAccounts: [],
                accountEmail: email,
                planType: only.planType,
                planLabel: only.title,
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        }

        // Fallback: direct usage call without memberships list.
        if let result = await requestCodexUsagePayload(
            accessToken: accessToken,
            chatGPTAccountID: storedAccountID
        ), !result.windows.isEmpty {
            let planType = result.planType ?? jwtPlan
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: result.windows,
                subAccounts: [],
                accountEmail: email,
                planType: planType,
                planLabel: ChatGPTPlanFormatter.displayName(for: planType),
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: email,
            error: "Could not fetch Codex usage limits"
        )
    }

    private struct CodexUsageTarget {
        let accountID: String?
        let planType: String?
        let workspaceName: String?
        let structure: String?
        let role: String?
    }

    private struct CodexUsagePayload {
        let windows: [RateWindow]
        let planType: String?
    }

    private static func codexUsageTargets(
        memberships: [CodexUsageTarget],
        storedAccountID: String?,
        jwtPlan: String?
    ) -> [CodexUsageTarget] {
        if !memberships.isEmpty {
            let paid = memberships.filter { ($0.planType ?? "").lowercased() != "free" }
            // Show every paid/subscription membership; fall back to all if only free exists.
            let preferred = paid.isEmpty ? memberships : paid
            // Stable order: non-free first, then by title-ish fields.
            return preferred.sorted { lhs, rhs in
                let lFree = (lhs.planType ?? "").lowercased() == "free"
                let rFree = (rhs.planType ?? "").lowercased() == "free"
                if lFree != rFree { return !lFree && rFree }
                return (lhs.workspaceName ?? lhs.planType ?? "") < (rhs.workspaceName ?? rhs.planType ?? "")
            }
        }

        return [
            CodexUsageTarget(
                accountID: storedAccountID,
                planType: jwtPlan,
                workspaceName: nil,
                structure: nil,
                role: nil
            )
        ]
    }

    private static func codexMembershipSubtitle(structure: String?, role: String?) -> String? {
        var parts: [String] = []
        if let structure, !structure.isEmpty {
            parts.append(structure.capitalized)
        }
        if let role, !role.isEmpty {
            let cleaned = role.replacingOccurrences(of: "-", with: " ")
            parts.append(cleaned)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func fetchChatGPTAccountMemberships(accessToken: String) async -> [CodexUsageTarget] {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/accounts/check") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = json["accounts"] as? [[String: Any]]
            else {
                return []
            }

            return accounts.compactMap { entry -> CodexUsageTarget? in
                let id = stringValue(entry, keys: ["id", "account_id", "chatgpt_account_id"])
                guard let id, !id.isEmpty else { return nil }
                return CodexUsageTarget(
                    accountID: id,
                    planType: stringValue(entry, keys: ["plan_type", "chatgpt_plan_type"]),
                    workspaceName: stringValue(entry, keys: ["name", "organization_name", "workspace_name"]),
                    structure: stringValue(entry, keys: ["structure", "account_structure", "kind"]),
                    role: stringValue(entry, keys: ["account_user_role", "role"])
                )
            }
        } catch {
            return []
        }
    }

    private static func requestCodexUsagePayload(
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> CodexUsagePayload? {
        let endpoints = [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/backend-api/api/codex/usage",
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            if let payload = await requestCodexUsagePayload(
                url: url,
                accessToken: accessToken,
                chatGPTAccountID: chatGPTAccountID
            ) {
                return payload
            }
        }
        return nil
    }

    private static func requestCodexUsagePayload(
        url: URL,
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> CodexUsagePayload? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 {
                return nil
            }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            let rateLimit = json["rate_limit"] as? [String: Any]
            let codeReview = json["code_review_rate_limit"] as? [String: Any]
            var windows: [RateWindow] = []
            if let rateLimit {
                if let primary = mapCodexWindow(rateLimit["primary_window"] as? [String: Any], fallbackLabel: "Session") {
                    windows.append(primary)
                }
                if let secondary = mapCodexWindow(rateLimit["secondary_window"] as? [String: Any], fallbackLabel: "Weekly") {
                    windows.append(secondary)
                }
            }
            if let codeReview {
                if let primary = mapCodexWindow(
                    codeReview["primary_window"] as? [String: Any],
                    fallbackLabel: "Code review"
                ) {
                    windows.append(
                        RateWindow(
                            usedPercent: primary.usedPercent,
                            windowMinutes: primary.windowMinutes,
                            resetsAt: primary.resetsAt,
                            resetDescription: primary.resetDescription,
                            label: "Code review"
                        )
                    )
                }
            }

            guard !windows.isEmpty else { return nil }
            return CodexUsagePayload(
                windows: windows,
                planType: stringValue(json, keys: ["plan_type"])
            )
        } catch {
            return nil
        }
    }

    private static func mapCodexWindow(_ window: [String: Any]?, fallbackLabel: String) -> RateWindow? {
        guard let window else { return nil }
        let usedPercent = doubleValue(window, keys: ["used_percent"]) ?? 0
        let resetAt = intValue(window, keys: ["reset_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? intValue(window, keys: ["reset_after_seconds"]).map { Date().addingTimeInterval(TimeInterval($0)) }
        let windowSeconds = intValue(window, keys: ["limit_window_seconds"]) ?? 0
        let minutes = windowSeconds > 0 ? windowSeconds / 60 : nil
        let label: String
        if let minutes {
            if minutes <= 360 { label = "Session (\(max(1, minutes / 60))h)" }
            else if minutes <= 10_080 { label = "Weekly" }
            else { label = fallbackLabel }
        } else {
            label = fallbackLabel
        }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: resetAt,
            resetDescription: nil,
            label: label
        )
    }

    private static func chatgptAccountIDFromJWT(_ token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_account_id", "account_id"])
    }

    private static func chatgptPlanTypeFromJWT(_ token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_plan_type"])
    }

    private static func openAIAuthClaims(from token: String?) -> [String: Any]? {
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
        return json["https://api.openai.com/auth"] as? [String: Any]
    }

    // MARK: - Z.AI GLM Coding Plan

    /// Fetches Coding Plan quota from the same monitor API used by ZCode / z.ai dashboard.
    /// Endpoint: `GET https://api.z.ai/api/monitor/usage/quota/limit`
    private static func fetchZaiUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let apiKey = stringValue(payload, keys: ["api_key", "apiKey", "key", "access_token"]) else {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: stringValue(payload, keys: ["email"]),
                error: "Missing Z.AI API key"
            )
        }

        let label = stringValue(payload, keys: ["email", "label"]) ?? maskAPIKey(apiKey)
        let endpoints = [
            "https://api.z.ai/api/monitor/usage/quota/limit",
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
        ]

        for endpoint in endpoints {
            if let snapshot = await requestZaiQuota(
                endpoint: endpoint,
                apiKey: apiKey,
                authAccountID: authAccountID,
                providerID: providerID,
                accountLabel: label
            ) {
                return snapshot
            }
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: label,
            error: "Could not fetch Z.AI Coding Plan limits"
        )
    }

    private static func requestZaiQuota(
        endpoint: String,
        apiKey: String,
        authAccountID: String,
        providerID: String,
        accountLabel: String
    ) async -> ProviderUsageSnapshot? {
        guard let url = URL(string: endpoint) else { return nil }

        // Z.AI accepts both `Bearer <key>` and raw key Authorization styles.
        for authorization in ["Bearer \(apiKey)", apiKey] {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            request.setValue("VibeProxyUltra/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .empty(
                        authAccountID: authAccountID,
                        providerID: providerID,
                        accountEmail: accountLabel,
                        error: "Z.AI API key rejected — check the key in Settings"
                    )
                }
                guard (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Success envelope: { success, code, data: { limits, level } }
                let success = (json["success"] as? Bool) ?? ((json["code"] as? Int) == 200)
                guard success else { continue }

                let dataObj = json["data"] as? [String: Any] ?? json
                let limits = dataObj["limits"] as? [[String: Any]] ?? []
                let level = stringValue(dataObj, keys: ["level", "plan", "planType", "plan_type"])
                let planLabel = zaiPlanDisplayName(level)

                let windows = mapZaiQuotaLimits(limits)
                guard !windows.isEmpty else {
                    return .empty(
                        authAccountID: authAccountID,
                        providerID: providerID,
                        accountEmail: accountLabel,
                        error: "No Z.AI quota windows reported for this key"
                    )
                }

                let sourceHost = url.host?.contains("bigmodel") == true ? "BigModel" : "Z.AI"
                return ProviderUsageSnapshot(
                    id: authAccountID,
                    providerID: providerID,
                    source: "\(sourceHost) Coding Plan",
                    windows: windows,
                    subAccounts: [],
                    accountEmail: accountLabel,
                    planType: level,
                    planLabel: planLabel,
                    updatedAt: Date(),
                    errorMessage: nil,
                    isRefreshing: false
                )
            } catch {
                continue
            }
        }
        return nil
    }

    /// Maps Z.AI monitor limit rows into labeled RateWindows.
    /// unit 3 + TOKENS_LIMIT → 5-hour prompt/token window
    /// unit 6 + TOKENS_LIMIT → weekly window
    /// TIME_LIMIT → MCP tools (monthly)
    static func mapZaiQuotaLimits(_ limits: [[String: Any]]) -> [RateWindow] {
        var fiveHour: RateWindow?
        var weekly: RateWindow?
        var mcp: RateWindow?
        var extras: [RateWindow] = []

        for limit in limits {
            let type = (stringValue(limit, keys: ["type"]) ?? "").uppercased()
            let unit = intValue(limit, keys: ["unit"]) ?? 0
            let number = intValue(limit, keys: ["number"]) ?? 0
            let usedPercent = doubleValue(limit, keys: ["percentage"]) ?? 0
            let resetsAt = intValue(limit, keys: ["nextResetTime"]).map { millis -> Date in
                // Values can be ms or seconds; treat large numbers as ms.
                if millis > 10_000_000_000 {
                    return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
                }
                return Date(timeIntervalSince1970: TimeInterval(millis))
            }

            if type == "TOKENS_LIMIT" && unit == 3 && number == 5 {
                fiveHour = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 5 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "5-hour"
                )
            } else if type == "TOKENS_LIMIT" && unit == 6 {
                weekly = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "Weekly"
                )
            } else if type == "TIME_LIMIT" {
                mcp = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 30 * 24 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "MCP (monthly)"
                )
            } else {
                let label: String
                if type == "TOKENS_LIMIT" {
                    label = "Tokens (\(number)\(unitLabel(unit)))"
                } else if !type.isEmpty {
                    label = type.replacingOccurrences(of: "_", with: " ").capitalized
                } else {
                    label = "Quota"
                }
                extras.append(
                    RateWindow(
                        usedPercent: usedPercent,
                        windowMinutes: nil,
                        resetsAt: resetsAt,
                        resetDescription: nil,
                        label: label
                    )
                )
            }
        }

        return [fiveHour, weekly, mcp].compactMap { $0 } + extras
    }

    private static func unitLabel(_ unit: Int) -> String {
        switch unit {
        case 3: return "h"
        case 5: return "mo"
        case 6: return "w"
        default: return ""
        }
    }

    private static func zaiPlanDisplayName(_ level: String?) -> String? {
        guard let level, !level.isEmpty else { return nil }
        switch level.lowercased() {
        case "lite": return "Coding Plan Lite"
        case "pro": return "Coding Plan Pro"
        case "max": return "Coding Plan Max"
        default: return "Coding Plan \(level.capitalized)"
        }
    }

    private static func maskAPIKey(_ apiKey: String) -> String {
        guard apiKey.count > 12 else { return apiKey }
        return String(apiKey.prefix(8)) + "…" + String(apiKey.suffix(4))
    }

    // MARK: - Claude

    private static func fetchClaudeUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let email = stringValue(payload, keys: ["email"])
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            if http.statusCode == 429 {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Rate limited — try again shortly")
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let primary = mapClaudeWindow(json["five_hour"] as? [String: Any], defaultMinutes: 300, label: "5-hour")
            let secondary = mapClaudeWindow(json["seven_day"] as? [String: Any], defaultMinutes: 10_080, label: "Weekly")
            let sevenDaySonnet = mapClaudeWindow(
                json["seven_day_sonnet"] as? [String: Any],
                defaultMinutes: 10_080,
                label: "Weekly (Sonnet)"
            )
            let sevenDayOpus = mapClaudeWindow(
                json["seven_day_opus"] as? [String: Any],
                defaultMinutes: 10_080,
                label: "Weekly (Opus)"
            )
            let windows = [primary, secondary, sevenDayOpus, sevenDaySonnet].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Claude OAuth",
                windows: windows,
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota windows reported" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    private static func mapClaudeWindow(_ window: [String: Any]?, defaultMinutes: Int, label: String) -> RateWindow? {
        guard let window else { return nil }
        let utilization = doubleValue(window, keys: ["utilization"]) ?? 0
        let resetsAt = parseISO8601(stringValue(window, keys: ["resets_at"]))
        return RateWindow(
            usedPercent: utilization,
            windowMinutes: defaultMinutes,
            resetsAt: resetsAt,
            resetDescription: nil,
            label: label
        )
    }

    // MARK: - Copilot

    private static func fetchCopilotUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let login = stringValue(payload, keys: ["username", "login", "email"])
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeProxyUltra/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let snapshots = json["quota_snapshots"] as? [String: Any]
            let resetDate = parseCopilotResetDate(stringValue(json, keys: ["quota_reset_date"]))
            let premium = mapCopilotQuota(
                snapshots?["premium_interactions"] as? [String: Any],
                resetsAt: resetDate,
                label: "Premium"
            )
            let chat = mapCopilotQuota(
                snapshots?["chat"] as? [String: Any],
                resetsAt: resetDate,
                label: "Chat"
            )
            let completions = mapCopilotQuota(
                snapshots?["completions"] as? [String: Any],
                resetsAt: resetDate,
                label: "Completions"
            )
            let windows = [premium, chat, completions].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "GitHub Copilot",
                windows: windows,
                accountEmail: login,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data for this plan" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    private static func mapCopilotQuota(_ snapshot: [String: Any]?, resetsAt: Date?, label: String) -> RateWindow? {
        guard let snapshot else { return nil }
        let remaining = doubleValue(snapshot, keys: ["remaining"]) ?? 0
        let entitlement = doubleValue(snapshot, keys: ["entitlement"]) ?? 0
        guard entitlement > 0 else { return nil }
        let usedPercent = max(0, min(100, 100 - (remaining / entitlement * 100)))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: nil,
            label: label
        )
    }

    private static func parseCopilotResetDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    // MARK: - Gemini

    private static func fetchGeminiUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        await fetchCloudCodeUsage(
            authAccountID: authAccountID,
            providerID: providerID,
            accessToken: extractGeminiAccessToken(from: payload),
            projectID: stringValue(payload, keys: ["project_id"]),
            email: stringValue(payload, keys: ["email"]),
            source: "Gemini OAuth",
            authPayload: payload
        )
    }

    private static func extractGeminiAccessToken(from payload: [String: Any]) -> String? {
        if let token = stringValue(payload, keys: ["access_token"]) {
            return token
        }
        if let tokenObj = payload["token"] as? [String: Any] {
            return stringValue(tokenObj, keys: ["access_token", "accessToken"])
        }
        return nil
    }

    // MARK: - Antigravity

    private static func fetchAntigravityUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        await fetchCloudCodeUsage(
            authAccountID: authAccountID,
            providerID: providerID,
            accessToken: stringValue(payload, keys: ["access_token"]),
            projectID: stringValue(payload, keys: ["project_id"]),
            email: stringValue(payload, keys: ["email"]),
            source: "Antigravity OAuth",
            authPayload: payload
        )
    }

    private static func fetchCloudCodeUsage(
        authAccountID: String,
        providerID: String,
        accessToken: String?,
        projectID: String?,
        email: String?,
        source: String,
        authPayload: [String: Any] = [:]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken, !accessToken.isEmpty else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let bodyData: Data
        if let projectID, !projectID.isEmpty {
            bodyData = Data("{\"project\": \"\(projectID)\"}".utf8)
        } else {
            bodyData = Data("{}".utf8)
        }

        // Cockpit-style: summary groups (Gemini vs Claude/Opus) are the accurate shared pools.
        // Per-model buckets are a fallback / detail layer.
        async let summaryJSON = postCloudCodeJSON(
            path: "v1internal:retrieveUserQuotaSummary",
            accessToken: accessToken,
            body: bodyData
        )
        async let detailJSON = postCloudCodeJSON(
            path: "v1internal:retrieveUserQuota",
            accessToken: accessToken,
            body: bodyData
        )

        let summary = await summaryJSON
        let detail = await detailJSON

        if summary.status == 401 || detail.status == 401 {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: sessionInvalidMessage(payload: authPayload)
            )
        }

        if let summaryBody = summary.json {
            let groups = cloudCodeQuotaGroups(from: summaryBody)
            if !groups.isEmpty {
                // Flatten primary windows for the top-level bars (most important first).
                var flatWindows: [RateWindow] = []
                for group in groups {
                    flatWindows.append(contentsOf: group.windows)
                }
                return ProviderUsageSnapshot(
                    id: authAccountID,
                    providerID: providerID,
                    source: source,
                    windows: flatWindows,
                    subAccounts: groups,
                    accountEmail: email,
                    planType: nil,
                    planLabel: nil,
                    updatedAt: Date(),
                    errorMessage: nil,
                    isRefreshing: false
                )
            }
        }

        if let detailBody = detail.json {
            let windows = cloudCodeQuotaWindows(from: detailBody)
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: source,
                windows: windows,
                subAccounts: [],
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data available" : nil,
                isRefreshing: false
            )
        }

        if let status = summary.status ?? detail.status, status != 200 {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: "Usage API returned HTTP \(status)"
            )
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: email,
            error: summary.error ?? detail.error ?? "Could not parse usage response"
        )
    }

    private struct CloudCodeHTTPResult {
        let status: Int?
        let json: [String: Any]?
        let error: String?
    }

    private static func postCloudCodeJSON(
        path: String,
        accessToken: String,
        body: Data
    ) async -> CloudCodeHTTPResult {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/\(path)") else {
            return CloudCodeHTTPResult(status: nil, json: nil, error: "Invalid usage URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.setValue("gl-node/22.21.1", forHTTPHeaderField: "X-Goog-Api-Client")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CloudCodeHTTPResult(status: nil, json: nil, error: "Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                return CloudCodeHTTPResult(status: http.statusCode, json: nil, error: nil)
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return CloudCodeHTTPResult(status: http.statusCode, json: json, error: nil)
        } catch {
            return CloudCodeHTTPResult(status: nil, json: nil, error: error.localizedDescription)
        }
    }

    /// Maps `retrieveUserQuotaSummary` groups into sub-accounts
    /// (e.g. "Gemini Models" vs "Claude and GPT models" each with 5h + weekly bars).
    static func cloudCodeQuotaGroups(from json: [String: Any]) -> [ProviderUsageSubAccount] {
        guard let groups = json["groups"] as? [[String: Any]] else { return [] }

        return groups.compactMap { group -> ProviderUsageSubAccount? in
            let groupTitle = stringValue(group, keys: ["displayName", "name"])
                ?? "Model group"
            let description = stringValue(group, keys: ["description"])
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            let windows: [RateWindow] = buckets.compactMap { bucket in
                // Summary fractions are remaining, not used.
                let remaining = doubleValue(bucket, keys: ["remainingFraction"]) ?? 1
                let usedPercent = max(0, min(100, (1 - remaining) * 100))
                let resetTime = stringValue(bucket, keys: ["resetTime"])
                if let resetTime, resetTime.hasPrefix("1970-") { return nil }

                let bucketLabel = stringValue(bucket, keys: ["displayName", "window", "bucketId"])
                    ?? "Limit"
                let windowMinutes: Int?
                let window = (stringValue(bucket, keys: ["window"]) ?? "").lowercased()
                if window.contains("5h") || window.contains("five") || bucketLabel.lowercased().contains("five") {
                    windowMinutes = 300
                } else if window.contains("week") || bucketLabel.lowercased().contains("week") {
                    windowMinutes = 10_080
                } else {
                    windowMinutes = nil
                }

                // Prefix with group so flat + grouped UIs stay clear:
                // "Claude · Five Hour Limit", "Gemini · Weekly Limit"
                let shortGroup: String
                let lower = groupTitle.lowercased()
                if lower.contains("claude") || lower.contains("gpt") || lower.contains("3p") {
                    shortGroup = "Claude/Opus"
                } else if lower.contains("gemini") {
                    shortGroup = "Gemini"
                } else {
                    shortGroup = groupTitle
                }

                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: windowMinutes,
                    resetsAt: parseISO8601(resetTime),
                    resetDescription: stringValue(bucket, keys: ["description"]),
                    label: "\(shortGroup) · \(bucketLabel)"
                )
            }

            guard !windows.isEmpty else { return nil }
            return ProviderUsageSubAccount(
                id: groupTitle,
                title: groupTitle,
                subtitle: description,
                planType: nil,
                windows: windows,
                errorMessage: nil
            )
        }
    }

    // MARK: - Kiro

    private static func fetchKiroUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let region = stringValue(payload, keys: ["region"]) ?? "us-east-1"
        let email = stringValue(payload, keys: ["email"])
        guard let url = URL(string: "https://codewhisperer.\(region).amazonaws.com/getUsageLimits") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("AmazonCodeWhispererService.GetUsageLimits", forHTTPHeaderField: "x-amz-target")
        request.httpBody = Data("{\"origin\":\"KIRO_CLI\"}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let breakdown = json["usageBreakdownList"] as? [[String: Any]] ?? []
            let credit = breakdown.first { stringValue($0, keys: ["resourceType"]) == "CREDIT" }
                ?? breakdown.first
            let primary = mapKiroUsageBreakdown(credit, fallbackReset: json["nextDateReset"], label: "Credits")
            let windows = [primary].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Kiro OAuth",
                windows: windows,
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data available" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    private static func mapKiroUsageBreakdown(
        _ breakdown: [String: Any]?,
        fallbackReset: Any?,
        label: String
    ) -> RateWindow? {
        guard let breakdown else { return nil }
        let currentUsage = doubleValue(breakdown, keys: ["currentUsage", "currentUsageWithPrecision"]) ?? 0
        let usageLimit = doubleValue(breakdown, keys: ["usageLimit", "usageLimitWithPrecision"]) ?? 0
        guard usageLimit > 0 else { return nil }

        let usedPercent = max(0, min(100, currentUsage / usageLimit * 100))
        let resetEpoch = doubleValue(breakdown, keys: ["nextDateReset"])
            ?? (fallbackReset as? Double)
            ?? (fallbackReset as? Int).map(Double.init)
        let resetsAt = resetEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 43_200,
            resetsAt: resetsAt,
            resetDescription: nil,
            label: label
        )
    }

    // MARK: - Grok

    private static func fetchGrokUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token", "key"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let email = stringValue(payload, keys: ["email"])
        guard let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("VibeProxyUltra/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(
                        payload: payload,
                        reauthHint: "run `grok login` or re-authenticate in Settings"
                    )
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Billing API returned HTTP \(http.statusCode)")
            }

            if let grpcError = grokGRPCError(from: data, payload: payload) {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: grpcError)
            }

            guard let parsed = parseGrokBillingResponse(data) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse billing usage")
            }

            let primary = RateWindow(
                usedPercent: parsed.usedPercent,
                windowMinutes: nil,
                resetsAt: parsed.resetsAt,
                resetDescription: nil,
                label: "Grok credits"
            )

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "xAI OAuth",
                windows: [primary],
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func enrichPayload(_ payload: [String: Any], for serviceType: ServiceType) -> [String: Any] {
        var merged = payload

        switch serviceType {
        case .codex:
            if let local = readCodexAppPayload() {
                for (key, value) in local where merged[key] == nil {
                    merged[key] = value
                }
            }
        case .claude:
            if merged["access_token"] == nil, let local = readClaudeAppPayload() {
                merged.merge(local) { _, new in new }
            }
        case .grok:
            if let local = readGrokAppPayload() {
                for (key, value) in local where merged[key] == nil {
                    merged[key] = value
                }
            }
        default:
            break
        }

        return merged
    }

    private static func readCodexAppPayload() -> [String: Any]? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let root = readAuthPayload(at: authURL),
              let tokens = root["tokens"] as? [String: Any]
        else { return nil }

        var payload: [String: Any] = [:]
        if let value = tokens["access_token"] as? String { payload["access_token"] = value }
        if let value = tokens["refresh_token"] as? String { payload["refresh_token"] = value }
        if let value = tokens["id_token"] as? String { payload["id_token"] = value }
        if let value = tokens["account_id"] as? String { payload["account_id"] = value }
        if let email = JWTEmailExtractor.email(from: tokens["id_token"] as? String) {
            payload["email"] = email
        }
        return payload.isEmpty ? nil : payload
    }

    private static func readGrokAppPayload() -> [String: Any]? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard let root = readAuthPayload(at: authURL) else { return nil }

        let entry: [String: Any]?
        let oidcPrefix = "https://auth.x.ai::"
        if let match = root.first(where: { $0.key.hasPrefix(oidcPrefix) }),
           let value = match.value as? [String: Any]
        {
            entry = value
        } else if let legacy = root["https://accounts.x.ai/sign-in"] as? [String: Any] {
            entry = legacy
        } else {
            entry = root.compactMap { _, value -> [String: Any]? in
                guard let dict = value as? [String: Any], dict["key"] != nil else { return nil }
                return dict
            }.first
        }

        guard let entry,
              let accessToken = entry["key"] as? String,
              !accessToken.isEmpty
        else { return nil }

        var payload: [String: Any] = [
            "access_token": accessToken,
            "key": accessToken,
        ]
        if let email = entry["email"] as? String, !email.isEmpty {
            payload["email"] = email
        }
        if let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        if let expiresAt = entry["expires_at"] as? String, !expiresAt.isEmpty {
            payload["expired"] = expiresAt
        }
        return payload
    }

    private static func readClaudeAppPayload() -> [String: Any]? {
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")

        let data: Data?
        if let fileData = try? Data(contentsOf: credentialsURL) {
            data = fileData
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            data = output.isEmpty ? nil : output
        }

        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }

        var payload: [String: Any] = ["access_token": accessToken]
        if let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        if let email = oauth["email"] as? String, !email.isEmpty {
            payload["email"] = email
        }
        if let expiresAt = oauth["expiresAt"] as? Double {
            payload["expired"] = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: expiresAt / 1000)
            )
        }
        return payload
    }

    static func readAuthPayload(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func doubleValue(_ json: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = json[key] as? Double { return value }
            if let value = json[key] as? Int { return Double(value) }
            if let value = json[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func intValue(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = json[key] as? Int { return value }
            if let value = json[key] as? Double { return Int(value) }
            if let value = json[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatters: [ISO8601DateFormatter] = {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return [withFractional, standard]
        }()
        for formatter in formatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: - Cloud Code quota helpers

    /// Groups Cloud Code / Gemini / Antigravity quota buckets into human-readable
    /// model-family rows (Gemini Pro, Gemini Flash, Claude Opus, Claude Sonnet, …).
    static func cloudCodeQuotaWindows(from json: [String: Any]) -> [RateWindow] {
        var candidates: [(family: CloudCodeModelFamily, window: RateWindow)] = []

        if let buckets = json["buckets"] as? [[String: Any]] {
            for bucket in buckets {
                guard let modelID = stringValue(bucket, keys: ["modelId", "model_id", "name"]),
                      let window = mapCloudCodeBucket(bucket, label: "")
                else { continue }
                let family = CloudCodeModelFamily.classify(modelID: modelID)
                candidates.append((family, window.withLabel(family.displayName)))
            }
        }

        if candidates.isEmpty, let models = json["models"] as? [[String: Any]] {
            for model in models {
                let modelID = stringValue(model, keys: ["name", "modelId", "model", "displayName"]) ?? "model"
                guard let quotaInfo = model["quotaInfo"] as? [String: Any] ?? model["quota"] as? [String: Any],
                      let window = mapCloudCodeQuotaInfo(quotaInfo, label: "")
                else { continue }
                let family = CloudCodeModelFamily.classify(modelID: modelID)
                candidates.append((family, window.withLabel(family.displayName)))
            }
        }

        // Keep the most constrained window per family, ordered for readability.
        var bestByFamily: [CloudCodeModelFamily: RateWindow] = [:]
        for candidate in candidates {
            if let existing = bestByFamily[candidate.family] {
                if candidate.window.usedPercent > existing.usedPercent {
                    bestByFamily[candidate.family] = candidate.window
                }
            } else {
                bestByFamily[candidate.family] = candidate.window
            }
        }

        let ordered = CloudCodeModelFamily.displayOrder.compactMap { bestByFamily[$0] }
        let extras = bestByFamily
            .filter { !CloudCodeModelFamily.displayOrder.contains($0.key) }
            .map(\.value)
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
        return ordered + extras
    }

    private static func mapCloudCodeBucket(_ bucket: [String: Any], label: String) -> RateWindow? {
        guard let resetTime = stringValue(bucket, keys: ["resetTime"]),
              !resetTime.hasPrefix("1970-")
        else { return nil }

        let remaining = doubleValue(bucket, keys: ["remainingFraction"]) ?? 1
        let usedPercent = max(0, min(100, (1 - remaining) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 1_440,
            resetsAt: parseISO8601(resetTime),
            resetDescription: nil,
            label: label.isEmpty ? nil : label
        )
    }

    private static func mapCloudCodeQuotaInfo(_ quotaInfo: [String: Any], label: String) -> RateWindow? {
        if let resetTime = stringValue(quotaInfo, keys: ["resetTime"]), resetTime.hasPrefix("1970-") {
            return nil
        }
        let remaining = doubleValue(quotaInfo, keys: ["remainingFraction"]) ?? 1
        let usedPercent = max(0, min(100, (1 - remaining) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 1_440,
            resetsAt: parseISO8601(stringValue(quotaInfo, keys: ["resetTime"])),
            resetDescription: nil,
            label: label.isEmpty ? nil : label
        )
    }
}

// MARK: - Cloud Code model families

enum CloudCodeModelFamily: Hashable {
    case claudeOpus
    case claudeSonnet
    case claudeOther
    case gpt
    case geminiPro
    case geminiFlash
    case geminiOther
    case other(String)

    static let displayOrder: [CloudCodeModelFamily] = [
        .claudeOpus,
        .claudeSonnet,
        .claudeOther,
        .gpt,
        .geminiPro,
        .geminiFlash,
        .geminiOther,
    ]

    var displayName: String {
        switch self {
        case .claudeOpus: return "Claude Opus"
        case .claudeSonnet: return "Claude Sonnet"
        case .claudeOther: return "Claude"
        case .gpt: return "GPT-OSS"
        case .geminiPro: return "Gemini Pro"
        case .geminiFlash: return "Gemini Flash"
        case .geminiOther: return "Gemini"
        case .other(let name): return name
        }
    }

    static func classify(modelID: String) -> CloudCodeModelFamily {
        let id = modelID.lowercased()
        if id.contains("claude") || id.contains("anthropic") {
            if id.contains("opus") { return .claudeOpus }
            if id.contains("sonnet") { return .claudeSonnet }
            return .claudeOther
        }
        if id.contains("opus") {
            return .claudeOpus
        }
        if id.contains("sonnet") {
            return .claudeSonnet
        }
        if id.contains("gpt") || id.hasPrefix("chat_") {
            return .gpt
        }
        if id.contains("flash") || id.hasPrefix("tab_") {
            return .geminiFlash
        }
        if id.contains("pro") && (id.contains("gemini") || id.contains("agent")) {
            return .geminiPro
        }
        if id.contains("pro") {
            return .geminiPro
        }
        if id.contains("gemini") || id.contains("gemma") {
            return .geminiOther
        }
        return .other(prettyModelName(modelID))
    }

    private static func prettyModelName(_ modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "models/", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private extension RateWindow {
    func withLabel(_ label: String) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            label: label
        )
    }
}

// Keep helper methods that lived below the old closing brace reachable via extension on NativeUsageFetcher.
extension NativeUsageFetcher {
    // MARK: - Grok billing protobuf helpers (continued after Cloud Code section)

    // MARK: - Grok billing protobuf helpers

    private struct GrokBillingParseResult {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private static func grokGRPCError(from data: Data, payload: [String: Any] = [:]) -> String? {
        let trailerFields = grokGRPCWebTrailerFields(from: data)
        guard let rawStatus = trailerFields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else { return nil }

        let message = trailerFields["grpc-message"]?
            .replacingOccurrences(of: "+", with: " ")
            ?? "Billing request failed"
        if status == 16 || message.localizedCaseInsensitiveContains("unauthenticated") {
            return sessionInvalidMessage(
                payload: payload,
                reauthHint: "run `grok login` or re-authenticate in Settings"
            )
        }
        return message
    }

    private static func parseGrokBillingResponse(_ data: Data, now: Date = Date()) -> GrokBillingParseResult? {
        var payloads = grokGRPCWebDataFrames(from: data)
        if payloads.isEmpty, grokLooksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { return nil }

        var scan = GrokProtobufScan()
        for payload in payloads {
            scan.merge(grokScanProtobuf(payload, depth: 0))
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1 && field.value.isFinite && field.value >= 0 && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min() ?? futureResetFields
            .map(\.date)
            .min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6]) ||
                (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        let noUsageYet = parsedPercent == nil &&
            scan.fixed32Fields.isEmpty &&
            reset != nil &&
            hasUsagePeriod

        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else { return nil }
        return GrokBillingParseResult(usedPercent: percent, resetsAt: reset)
    }

    private struct GrokProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: GrokProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func grokLooksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private static func grokGRPCWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    private static func grokGRPCWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0,
               let text = String(data: Data(bytes[start..<end]), encoding: .utf8)
            {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private static func grokScanProtobuf(_ data: Data, depth: Int) -> GrokProtobufScan {
        grokScanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func grokScanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: GrokProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = GrokProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = grokReadVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = grokReadVarint(bytes, index: &index) {
                    scan.varintFields.append(GrokProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = grokReadVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = grokScanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder
                    )
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(GrokProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder
                ))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func grokReadVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}