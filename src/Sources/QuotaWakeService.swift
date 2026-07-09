import Foundation

/// Sends a tiny "dummy" request so a provider's rolling 5-hour quota window
/// starts / advances on demand (Codex/ChatGPT and Claude/Anthropic primarily).
enum QuotaWakeService {
    enum WakeResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    /// Providers that expose a controllable 5-hour session window.
    static func supportsWake(_ type: ServiceType) -> Bool {
        switch type {
        case .codex, .claude, .antigravity, .gemini, .zai:
            return true
        default:
            return false
        }
    }

    static func wake(account: AuthAccount, proxyPort: Int = 8317) async -> WakeResult {
        // Always refresh first so the wake request uses a live access token.
        _ = await TokenRefreshService.refreshAccountFile(account.filePath)

        guard let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath) else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }

        switch account.type {
        case .codex:
            return await wakeCodex(account: account, payload: payload, proxyPort: proxyPort)
        case .claude:
            return await wakeClaude(account: account, payload: payload, proxyPort: proxyPort)
        case .antigravity, .gemini:
            return await wakeViaLocalProxy(
                models: preferredModels(for: account.type),
                proxyPort: proxyPort,
                label: account.type.displayName
            )
        case .zai:
            return await wakeViaLocalProxy(
                models: preferredModels(for: .zai),
                proxyPort: proxyPort,
                label: "Z.AI GLM"
            )
        default:
            return .failure(message: "5-hour wake is not supported for \(account.type.displayName)")
        }
    }

    // MARK: - Codex / ChatGPT

    private static func wakeCodex(
        account: AuthAccount,
        payload: [String: Any],
        proxyPort: Int
    ) async -> WakeResult {
        // Prefer local proxy (uses the same routing as real traffic).
        let proxyResult = await wakeViaLocalProxy(
            models: preferredModels(for: .codex),
            proxyPort: proxyPort,
            label: "Codex"
        )
        if case .success = proxyResult {
            return .success(message: "Triggered Codex/ChatGPT 5-hour window for \(account.baseDisplayName) via local proxy")
        }

        // Direct Codex Responses API (works when the ChatGPT plan includes Codex models).
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return proxyResult
        }
        let accountID = stringValue(payload, keys: ["account_id"])
        let models = [
            "gpt-5.1-codex-mini",
            "gpt-5.1-codex",
            "gpt-5.3-codex",
            "codex-mini-latest",
        ]
        for model in models {
            if await postCodexResponse(accessToken: accessToken, accountID: accountID, model: model) {
                return .success(message: "Triggered Codex 5-hour window for \(account.baseDisplayName) (\(model))")
            }
        }
        return .failure(
            message: "Could not wake Codex for \(account.baseDisplayName). Start the proxy and try again, or ensure this plan includes Codex models. \(proxyDetail(proxyResult))"
        )
    }

    private static func postCodexResponse(accessToken: String, accountID: String?, model: String) async -> Bool {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Claude

    private static func wakeClaude(
        account: AuthAccount,
        payload: [String: Any],
        proxyPort: Int
    ) async -> WakeResult {
        if let accessToken = stringValue(payload, keys: ["access_token"]),
           await postClaudeMessage(accessToken: accessToken)
        {
            return .success(message: "Triggered Claude 5-hour window for \(account.baseDisplayName)")
        }

        let proxyResult = await wakeViaLocalProxy(
            models: preferredModels(for: .claude),
            proxyPort: proxyPort,
            label: "Claude"
        )
        switch proxyResult {
        case .success:
            return .success(message: "Triggered Claude 5-hour window for \(account.baseDisplayName) via local proxy")
        case .failure(let message):
            return .failure(message: message)
        }
    }

    private static func postClaudeMessage(accessToken: String) async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
            // 200 = success; 400 with rate limit still "triggered" the window.
            return (200...299).contains(http.statusCode) || http.statusCode == 429
        } catch {
            return false
        }
    }

    // MARK: - Local proxy

    private static func preferredModels(for type: ServiceType) -> [String] {
        switch type {
        case .codex:
            return ["gpt-5.1-codex-mini", "gpt-5.1-codex", "gpt-4o-mini", "gpt-4o"]
        case .claude:
            return ["claude-sonnet-4", "claude-sonnet-4-20250514", "claude-3-5-sonnet-latest"]
        case .antigravity:
            return ["gemini-2.5-flash", "claude-sonnet-4", "gemini-2.5-pro"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.0-flash"]
        case .zai:
            return ["glm-4.7", "glm-5", "glm-4.6", "glm-4.5"]
        default:
            return ["gpt-4o-mini"]
        }
    }

    private static func wakeViaLocalProxy(
        models: [String],
        proxyPort: Int,
        label: String
    ) async -> WakeResult {
        let ports = [proxyPort, 8317, 8318]
        var lastError = "Proxy not reachable on port \(proxyPort)"

        for port in ports {
            for model in models {
                switch await postLocalCompletion(port: port, model: model) {
                case .success:
                    return .success(message: "Triggered \(label) 5-hour window via localhost:\(port) (\(model))")
                case .failure(let message):
                    lastError = message
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
        request.timeoutInterval = 90
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
            // 429 still means the 5h window was hit / engaged.
            if http.statusCode == 429 {
                return .success(message: "ok-rate-limited")
            }
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? ""
            return .failure(message: "Proxy HTTP \(http.statusCode): \(snippet)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
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
