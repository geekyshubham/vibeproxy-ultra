import Foundation

/// Sends a tiny "dummy" request so a provider's rolling 5-hour quota window
/// starts / advances on demand (Codex/ChatGPT, Claude, Antigravity, etc.).
enum QuotaWakeService {
    enum WakeResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    /// Providers that have a rolling ~5-hour / session quota we can wake.
    /// Others (Copilot, Grok, Kiro, Z.AI, …) must not show a Wake button at all.
    static func supportsWake(_ type: ServiceType) -> Bool {
        switch type {
        case .codex, .claude, .antigravity, .gemini:
            return true
        default:
            return false
        }
    }

    /// Whether the Wake control should appear for this account right now.
    /// Hidden unless the provider supports 5h wake *and* (when usage is known)
    /// a session/5h window is actually present.
    static func shouldShowWake(for type: ServiceType, usage: ProviderUsageSnapshot?) -> Bool {
        guard supportsWake(type) else { return false }
        guard let usage else { return true } // still loading — show for supported providers
        if usage.isRefreshing, usage.windows.isEmpty, usage.subAccounts.isEmpty {
            return true
        }
        // Loaded usage with no session window → hide the button.
        if usage.windows.isEmpty, usage.subAccounts.isEmpty, usage.errorMessage != nil {
            return false
        }
        return hasSessionOrFiveHourWindow(usage)
    }

    static func hasSessionOrFiveHourWindow(_ usage: ProviderUsageSnapshot) -> Bool {
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        guard !windows.isEmpty else {
            // Supported provider, no window payload yet — keep available.
            return true
        }
        return windows.contains { isSessionOrFiveHourWindow($0) }
    }

    static func isSessionOrFiveHourWindow(_ window: RateWindow) -> Bool {
        if let minutes = window.windowMinutes, minutes > 0, minutes <= 360 {
            return true
        }
        let label = (window.label ?? window.displayTitle).lowercased()
        return label.contains("5h")
            || label.contains("5-hour")
            || label.contains("five")
            || label.contains("session")
    }

    static func wake(account: AuthAccount, proxyPort: Int = 8317) async -> WakeResult {
        // Always refresh first so direct-auth fallbacks use a live access token.
        _ = await TokenRefreshService.refreshAccountFile(account.filePath)

        guard NativeUsageFetcher.readAuthPayload(at: account.filePath) != nil else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }

        // 1) Prefer local proxy with *real* model IDs discovered from /v1/models.
        let models = await resolveWakeModels(for: account.type, proxyPort: proxyPort)
        let proxyResult = await wakeViaLocalProxy(
            models: models,
            proxyPort: proxyPort,
            label: account.type.displayName
        )
        if case .success(let msg) = proxyResult {
            return .success(
                message: "Woke \(account.type.displayName) 5h window for \(account.baseDisplayName). \(msg)"
            )
        }

        // 2) Provider-native fallbacks when proxy routing fails.
        switch account.type {
        case .codex:
            if let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
               let accessToken = stringValue(payload, keys: ["access_token"])
            {
                let accountID = stringValue(payload, keys: ["account_id"])
                    ?? chatgptAccountIDFromJWT(accessToken)
                for model in ["gpt-5.4-mini", "gpt-5.5", "gpt-5.4", "codex-mini-latest"] {
                    if await postCodexResponse(accessToken: accessToken, accountID: accountID, model: model) {
                        return .success(
                            message: "Woke Codex 5h window for \(account.baseDisplayName) via OpenAI (\(model))"
                        )
                    }
                }
            }
        case .claude:
            if let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
               let accessToken = stringValue(payload, keys: ["access_token"]),
               await postClaudeMessage(accessToken: accessToken)
            {
                return .success(message: "Woke Claude 5h window for \(account.baseDisplayName) via Anthropic")
            }
        default:
            break
        }

        return .failure(
            message: "Could not wake \(account.type.displayName) for \(account.baseDisplayName). \(proxyDetail(proxyResult)) Ensure the proxy is running and this account is enabled."
        )
    }

    // MARK: - Model discovery

    /// CLIProxyAPIPlus advertises provider-scoped IDs like `[Codex] gpt-5.4-mini`.
    private static func resolveWakeModels(for type: ServiceType, proxyPort: Int) async -> [String] {
        let ports = uniquePorts(proxyPort)
        var discovered: [String] = []
        for port in ports {
            if let ids = await fetchModelIDs(port: port), !ids.isEmpty {
                discovered = ids
                break
            }
        }

        let prefixes = providerPrefixes(for: type)
        let matching = discovered.filter { id in
            let lower = id.lowercased()
            return prefixes.contains { prefix in
                lower.hasPrefix(prefix) || lower.contains(prefix)
            }
        }

        // Prefer cheap / mini / flash first for a true "dummy" wake.
        let sorted = matching.sorted { lhs, rhs in
            wakePriority(lhs) < wakePriority(rhs)
        }

        var models = Array(sorted.prefix(8))
        // Fallbacks if discovery empty or incomplete.
        for fallback in preferredFallbackModels(for: type) where !models.contains(fallback) {
            models.append(fallback)
        }
        // Last-resort universal cheap models that often route somewhere.
        for fallback in ["gpt-4o-mini", "gpt-5.4-mini", "claude-sonnet-4", "gemini-2.5-flash"]
            where !models.contains(fallback)
        {
            models.append(fallback)
        }
        return models
    }

    private static func providerPrefixes(for type: ServiceType) -> [String] {
        switch type {
        case .codex: return ["[codex]", "codex"]
        case .claude: return ["[claude]", "claude"]
        case .antigravity: return ["[antigravity]", "antigravity"]
        case .gemini: return ["[gemini]", "gemini"]
        case .copilot: return ["[github-copilot]", "github-copilot", "copilot"]
        case .kiro: return ["[kiro]", "kiro"]
        case .zai: return ["[z", "glm", "zai"]
        case .grok: return ["[xai]", "[grok]", "grok", "xai"]
        case .kimi: return ["[kimi]", "kimi", "moonshot"]
        default: return [type.rawValue]
        }
    }

    private static func preferredFallbackModels(for type: ServiceType) -> [String] {
        switch type {
        case .codex:
            return [
                "[Codex] gpt-5.4-mini",
                "[Codex] gpt-5.5",
                "[Codex] gpt-5.4",
                "gpt-5.4-mini",
                "gpt-4o-mini",
            ]
        case .claude:
            return [
                "claude-sonnet-4",
                "claude-sonnet-4-20250514",
                "[Antigravity] claude-sonnet-4-6",
            ]
        case .antigravity:
            return [
                "[Antigravity] gemini-3.5-flash-low",
                "[Antigravity] gemini-3-flash",
                "[Antigravity] gemini-3.1-flash-lite",
                "[Antigravity] claude-sonnet-4-6",
            ]
        case .gemini:
            return [
                "[Antigravity] gemini-3.5-flash-low",
                "gemini-2.5-flash",
                "gemini-2.0-flash",
            ]
        case .copilot:
            return [
                "[github-copilot] gpt-4o-mini",
                "[github-copilot] gpt-5-mini",
                "gpt-4o-mini",
            ]
        case .kiro:
            return [
                "[Kiro] auto",
                "[Kiro] claude-haiku-4-5",
                "[Kiro] claude-sonnet-4",
            ]
        case .zai:
            return ["glm-4.7", "glm-5", "glm-4.6"]
        case .grok:
            return ["grok-3", "grok-2", "grok-3-mini"]
        default:
            return ["gpt-4o-mini"]
        }
    }

    private static func wakePriority(_ model: String) -> Int {
        let m = model.lowercased()
        if m.contains("mini") || m.contains("flash") || m.contains("haiku") || m.contains("lite") || m.contains("auto") {
            return 0
        }
        if m.contains("image") || m.contains("embedding") || m.contains("thinking") || m.contains("opus") {
            return 50
        }
        return 10
    }

    private static func fetchModelIDs(port: Int) async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]]
            else { return nil }
            return list.compactMap { $0["id"] as? String }
        } catch {
            return nil
        }
    }

    // MARK: - Local proxy

    private static func uniquePorts(_ preferred: Int) -> [Int] {
        var seen = Set<Int>()
        return [preferred, 8317, 8318].filter { seen.insert($0).inserted }
    }

    private static func wakeViaLocalProxy(
        models: [String],
        proxyPort: Int,
        label: String
    ) async -> WakeResult {
        let ports = uniquePorts(proxyPort)
        var lastError = "Proxy not reachable on port \(proxyPort). Start the server from the menu bar."

        for port in ports {
            for model in models {
                switch await postLocalCompletion(port: port, model: model) {
                case .success:
                    return .success(message: "via localhost:\(port) · \(model)")
                case .failure(let message):
                    lastError = message
                    // Don't burn timeouts on unknown-model 4xx/5xx — continue quickly.
                    if message.contains("unknown provider") || message.contains("HTTP 40") || message.contains("HTTP 50") {
                        continue
                    }
                }
            }
        }
        return .failure(message: lastError)
    }

    private static func postLocalCompletion(port: Int, model: String) async -> WakeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            return .failure(message: "Invalid proxy URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Keep wake snappy — previous 90s timeouts made the button feel broken.
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer vibeproxy-wake", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Reply with the single word OK."]
            ],
            "max_tokens": 1,
            "stream": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid proxy response")
            }
            if (200...299).contains(http.statusCode) {
                return .success(message: "ok")
            }
            // Rate limit still engages the window.
            if http.statusCode == 429 {
                return .success(message: "ok-rate-limited")
            }
            let snippet = String(data: data.prefix(160), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            return .failure(message: "Proxy HTTP \(http.statusCode) for \(model): \(snippet)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Direct provider fallbacks

    private static func postCodexResponse(accessToken: String, accountID: String?, model: String) async -> Bool {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        let body: [String: Any] = [
            "model": model,
            "input": "Reply with the single word OK.",
            "store": false,
            "stream": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode) || http.statusCode == 429
        } catch {
            return false
        }
    }

    private static func postClaudeMessage(accessToken: String) async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode) || http.statusCode == 429
        } catch {
            return false
        }
    }

    private static func chatgptAccountIDFromJWT(_ token: String?) -> String? {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return (auth["chatgpt_account_id"] as? String) ?? (auth["account_id"] as? String)
    }

    private static func proxyDetail(_ result: WakeResult) -> String {
        if case .failure(let message) = result { return message }
        return ""
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
}
