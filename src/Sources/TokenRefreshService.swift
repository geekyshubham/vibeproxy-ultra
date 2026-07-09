import Foundation

/// Proactively refreshes OAuth access tokens before they expire.
/// Access tokens are short-lived; refresh tokens keep sessions alive.
enum TokenRefreshService {
    /// Refresh when the access token expires within this grace window.
    static let graceInterval: TimeInterval = 15 * 60 // 15 minutes
    /// How often the background timer checks auth files.
    static let pollInterval: TimeInterval = 3 * 60 // 3 minutes

    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let googleClientSecret = "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"

    private static var timer: Timer?
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    @discardableResult
    static func startAutoRefresh() -> Timer {
        stopAutoRefresh()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { await refreshAllNearExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refreshAllNearExpiry() }
        return timer
    }

    static func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// Refresh every refreshable auth file whose access token is within the grace period (or already past).
    @discardableResult
    static func refreshAllNearExpiry(force: Bool = false) async -> Int {
        let authDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var refreshed = 0
        for file in files where file.pathExtension == "json" {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: file),
                  let type = payload["type"] as? String
            else { continue }

            let needsRefresh = force || shouldRefresh(payload: payload)
            guard needsRefresh else { continue }

            if let updated = await refreshPayload(payload, type: type.lowercased()) {
                if writeAuthFile(updated, to: file) {
                    refreshed += 1
                    NSLog("[TokenRefresh] Refreshed %@", file.lastPathComponent)
                }
            }
        }

        if refreshed > 0 {
            await MainActor.run {
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
        }
        return refreshed
    }

    static func refreshAccountFile(_ file: URL) async -> Bool {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: file),
              let type = payload["type"] as? String,
              let updated = await refreshPayload(payload, type: type.lowercased())
        else { return false }
        let ok = writeAuthFile(updated, to: file)
        if ok {
            await MainActor.run {
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
        }
        return ok
    }

    // MARK: - Decision

    private static func shouldRefresh(payload: [String: Any]) -> Bool {
        guard refreshToken(from: payload) != nil else { return false }

        let now = Date()
        let deadline = now.addingTimeInterval(graceInterval)

        if let exp = accessTokenExpiry(from: payload) {
            return exp <= deadline
        }

        // No parseable expiry — refresh opportunistically if last_refresh is old.
        if let last = parseDate(payload["last_refresh"] as? String)
            ?? parseDate(payload["expired"] as? String)
        {
            return last.addingTimeInterval(30 * 60) <= now
        }
        return true
    }

    private static func accessTokenExpiry(from payload: [String: Any]) -> Date? {
        if let token = stringValue(payload, keys: ["access_token", "accessToken", "key"]),
           let exp = jwtExpiry(token)
        {
            return exp
        }
        return parseDate(payload["expired"] as? String)
            ?? parseDate(payload["expires_at"] as? String)
            ?? parseDate(payload["expiresAt"] as? String)
    }

    private static func refreshToken(from payload: [String: Any]) -> String? {
        stringValue(payload, keys: ["refresh_token", "refreshToken", "refresh"])
    }

    // MARK: - Provider refresh

    private static func refreshPayload(_ payload: [String: Any], type: String) async -> [String: Any]? {
        switch type {
        case "codex":
            return await refreshOpenAI(payload)
        case "claude":
            return await refreshAnthropic(payload)
        case "antigravity", "gemini":
            return await refreshGoogle(payload)
        case "xai":
            return await refreshXAI(payload)
        case "kiro":
            return await refreshKiro(payload)
        default:
            return nil
        }
    }

    private static func refreshOpenAI(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": openAIClientID,
        ])
        guard let json = await postForm(
            url: "https://auth.openai.com/oauth/token",
            body: body
        ) else { return nil }

        return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
    }

    private static func refreshAnthropic(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let endpoints = [
            "https://console.anthropic.com/v1/oauth/token",
            "https://platform.claude.com/v1/oauth/token",
        ]
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": anthropicClientID,
        ])
        for endpoint in endpoints {
            if let json = await postForm(url: endpoint, body: body) {
                return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
            }
        }
        return nil
    }

    private static func refreshGoogle(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let body = formBody([
            "client_id": googleClientID,
            "client_secret": googleClientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        guard let json = await postForm(
            url: "https://oauth2.googleapis.com/token",
            body: body
        ) else { return nil }
        // Google does not always return a new refresh_token.
        return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: false)
    }

    private static func refreshXAI(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        // Best-effort: xAI OAuth refresh endpoints vary by client; try common form.
        let endpoints = [
            "https://auth.x.ai/oauth/token",
            "https://api.x.ai/oauth/token",
        ]
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        for endpoint in endpoints {
            if let json = await postForm(url: endpoint, body: body) {
                return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
            }
        }
        return nil
    }

    private static func refreshKiro(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = stringValue(payload, keys: ["refreshToken", "refresh_token"]) else {
            return nil
        }
        let region = stringValue(payload, keys: ["region"]) ?? "us-east-1"
        let endpoints = [
            "https://prod.\(region).auth.desktop.kiro.dev/refreshToken",
            "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken",
        ]
        let jsonBody: [String: Any] = ["refreshToken": refresh]
        for endpoint in endpoints {
            if let json = await postJSON(url: endpoint, body: jsonBody) {
                var updated = payload
                if let access = stringValue(json, keys: ["accessToken", "access_token"]) {
                    updated["access_token"] = access
                    updated["accessToken"] = access
                }
                if let newRefresh = stringValue(json, keys: ["refreshToken", "refresh_token"]) {
                    updated["refresh_token"] = newRefresh
                    updated["refreshToken"] = newRefresh
                }
                if let expiresAt = stringValue(json, keys: ["expiresAt", "expires_at"]) {
                    updated["expires_at"] = expiresAt
                    updated["expired"] = expiresAt
                } else if let expiresIn = json["expiresIn"] as? Int ?? json["expires_in"] as? Int {
                    let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
                    updated["expired"] = isoString(exp)
                    updated["expires_at"] = isoString(exp)
                    updated["expires_in"] = expiresIn
                }
                updated["last_refresh"] = isoString(Date())
                return updated
            }
        }
        return nil
    }

    private static func applyOAuthTokenResponse(
        _ json: [String: Any],
        to payload: [String: Any],
        preferRefreshFromResponse: Bool
    ) -> [String: Any]? {
        guard let access = stringValue(json, keys: ["access_token"]) else { return nil }
        var updated = payload
        updated["access_token"] = access
        if let idToken = stringValue(json, keys: ["id_token"]) {
            updated["id_token"] = idToken
        }
        if preferRefreshFromResponse, let newRefresh = stringValue(json, keys: ["refresh_token"]) {
            updated["refresh_token"] = newRefresh
        }
        let expiresIn = (json["expires_in"] as? Int)
            ?? (json["expires_in"] as? Double).map { Int($0) }
            ?? 3600
        updated["expires_in"] = expiresIn
        let expDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        updated["expired"] = isoString(expDate)
        updated["last_refresh"] = isoString(Date())
        return updated
    }

    // MARK: - HTTP helpers

    private static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents adds a leading "?" — strip it for form bodies.
        let encoded = components.percentEncodedQuery ?? ""
        return Data(encoded.utf8)
    }

    private static func postForm(url: String, body: Data) async -> [String: Any]? {
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    private static func postJSON(url: String, body: [String: Any]) async -> [String: Any]? {
        guard let endpoint = URL(string: url),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    private static func writeAuthFile(_ payload: [String: Any], to file: URL) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("[TokenRefresh] Failed to write %@: %@", file.lastPathComponent, error.localizedDescription)
            return false
        }
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

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func jwtExpiry(_ token: String) -> Date? {
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
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
