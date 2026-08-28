import Foundation

/// Proactively refreshes OAuth access tokens before they expire.
/// Access tokens are short-lived; refresh tokens keep sessions alive.
enum TokenRefreshService {
    /// Refresh when the access token expires within this grace window.
    static let graceInterval: TimeInterval = 15 * 60 // 15 minutes
    /// How often the background timer checks auth files.
    static let pollInterval: TimeInterval = 3 * 60 // 3 minutes
    /// Codex access tokens last ~10 days; OpenAI refresh tokens die around ~30 days if never rotated.
    /// Rotate unused sessions well before that wall so idle accounts stay valid.
    static let unusedSessionRefreshAge: TimeInterval = 7 * 24 * 60 * 60

    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Must match the original authorize grant. Refreshing without `offline_access`
    /// can yield tokens that cannot be refreshed again after ~30 days.
    static let openAIRefreshScope = "openid email profile offline_access"
    private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let googleClientSecret = "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"
    private static let kimiClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// Public Cursor desktop OAuth client (same one Cockpit Tools uses).
    private static let cursorClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

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
    ///
    /// OpenAI rotates the refresh token on every success and immediately invalidates the previous one.
    /// Duplicate Codex files (email-named + `codex-seat-*.json`) share that token — refresh once
    /// per token and write the new one to every sibling, or the leftover file's next refresh
    /// sends `refresh_token_reused` and OpenAI revokes the whole family.
    @discardableResult
    static func refreshAllNearExpiry(force: Bool = false) async -> Int {
        let authDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var jobs: [AuthRefreshJob] = []
        for file in files where file.pathExtension == "json" {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: file),
                  let type = payload["type"] as? String
            else { continue }
            guard force || shouldRefresh(payload: payload) else { continue }
            jobs.append(
                AuthRefreshJob(
                    file: file,
                    payload: payload,
                    type: type.lowercased(),
                    refresh: refreshToken(from: payload)
                )
            )
        }

        var refreshed = 0
        for group in groupedByRefreshToken(jobs) {
            guard let first = group.first else { continue }
            let oldRefresh = first.refresh
            guard let updated = await refreshPayload(first.payload, type: first.type) else { continue }

            var skipped = Set<String>()
            for job in group {
                let merged = copyTokenFields(from: updated, onto: job.payload)
                if writeAuthFile(merged, to: job.file) {
                    refreshed += 1
                    skipped.insert(job.file.path)
                    NSLog("[TokenRefresh] Refreshed %@", job.file.lastPathComponent)
                }
            }
            if let oldRefresh, !oldRefresh.isEmpty {
                refreshed += propagateRotatedTokens(
                    oldRefresh: oldRefresh,
                    updated: updated,
                    authDirectory: authDir,
                    skipping: skipped
                )
                syncNativeCredentialStores(type: first.type, oldRefresh: oldRefresh, updated: updated)
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
              let type = payload["type"] as? String
        else { return false }
        let oldRefresh = refreshToken(from: payload)
        guard let updated = await refreshPayload(payload, type: type.lowercased()) else { return false }
        let ok = writeAuthFile(updated, to: file)
        if ok {
            if let oldRefresh, !oldRefresh.isEmpty {
                _ = propagateRotatedTokens(
                    oldRefresh: oldRefresh,
                    updated: updated,
                    skipping: [file.path]
                )
                syncNativeCredentialStores(type: type.lowercased(), oldRefresh: oldRefresh, updated: updated)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
        }
        return ok
    }

    // MARK: - Decision

    /// True when the access token is near/past expiry, or when a Codex-style session is old
    /// enough that its refresh token would otherwise hit OpenAI's idle-expiry wall.
    static func shouldRefresh(payload: [String: Any]) -> Bool {
        guard refreshToken(from: payload) != nil else { return false }

        let now = Date()
        let deadline = now.addingTimeInterval(graceInterval)

        if let exp = accessTokenExpiry(from: payload) {
            if exp <= deadline { return true }
            if let iat = accessTokenIssuedAt(from: payload),
               iat.addingTimeInterval(unusedSessionRefreshAge) <= now
            {
                return true
            }
            return false
        }

        // No parseable expiry — refresh opportunistically if last_refresh is old.
        if let last = parseDate(payload["last_refresh"] as? String)
            ?? parseDate(payload["expired"] as? String)
        {
            return last.addingTimeInterval(30 * 60) <= now
        }
        return true
    }

    struct AuthRefreshJob {
        let file: URL
        let payload: [String: Any]
        let type: String
        let refresh: String?
    }

    /// One group per (provider, refresh_token). Files without a refresh token stay unique.
    static func groupedByRefreshToken(_ jobs: [AuthRefreshJob]) -> [[AuthRefreshJob]] {
        var groups: [String: [AuthRefreshJob]] = [:]
        var order: [String] = []
        for job in jobs {
            let key: String
            if let rt = job.refresh, !rt.isEmpty {
                key = job.type + "\u{1e}" + rt
            } else {
                key = job.type + "\u{1e}file\u{1e}" + job.file.path
            }
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(job)
        }
        return order.compactMap { groups[$0] }
    }

    /// Copy rotated tokens onto every auth file that still holds `oldRefresh`,
    /// plus same-seat siblings (email + chatgpt_account_id) even if their RT is already stale.
    /// Cockpit copies live under `tokens` and used to keep a dead RT that switch then sent first.
    @discardableResult
    static func propagateRotatedTokens(
        oldRefresh: String,
        updated: [String: Any],
        authDirectory: URL? = nil,
        skipping skipped: Set<String> = []
    ) -> Int {
        let trimmed = oldRefresh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let authDir = authDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var wrote = 0
        for file in files where file.pathExtension == "json" {
            if skipped.contains(file.path) { continue }
            guard let payload = NativeUsageFetcher.readAuthPayload(at: file) else { continue }
            let matchesRefresh = refreshToken(from: payload) == trimmed
            let matchesSeat = sameCodexSeat(payload, as: updated)
            guard matchesRefresh || matchesSeat else { continue }
            // Shared RT always takes the new tokens (OpenAI already rotated).
            // Seat fan-out must not copy Team onto a Go file or clobber a fresher copy.
            if !matchesRefresh {
                if seatsConflict(payload, updated: updated) { continue }
                if hasNewerAccessToken(payload, than: updated) { continue }
            }
            let merged = copyTokenFields(from: updated, onto: payload)
            if writeAuthFile(merged, to: file) {
                wrote += 1
                NSLog("[TokenRefresh] Synced rotated refresh token to %@", file.lastPathComponent)
            }
        }
        // Native/Cockpit copies only when operating on the real auth dir — tests pass a temp path.
        if authDirectory == nil {
            if syncCodexAuthJSON(oldRefresh: trimmed, updated: updated) {
                wrote += 1
            }
            wrote += syncCockpitCodexAccounts(oldRefresh: trimmed, updated: updated)
        }
        return wrote
    }

    /// Official Codex CLI/desktop share the same rotating token via ~/.codex/auth.json + keychain.
    /// Leave that copy stale and the next CLI refresh sends refresh_token_reused.
    @discardableResult
    private static func syncCodexAuthJSON(oldRefresh: String, updated: [String: Any]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        let stored = stringValue(tokens, keys: ["refresh_token"])
            ?? stringValue(root, keys: ["refresh_token"])
        guard stored == oldRefresh else { return false }

        if let access = updated["access_token"] {
            tokens["access_token"] = access
            root["access_token"] = access
        }
        if let refresh = updated["refresh_token"] {
            tokens["refresh_token"] = refresh
            root["refresh_token"] = refresh
        }
        if let idToken = updated["id_token"] {
            tokens["id_token"] = idToken
            root["id_token"] = idToken
        }
        root["tokens"] = tokens
        root["last_refresh"] = isoString(Date())
        guard writeAuthFile(root, to: url) else { return false }
        _ = CodexWorkspaceCredentials.writeKeychain(
            authFileJSON: root,
            codexHome: home.appendingPathComponent(".codex")
        )
        NSLog("[TokenRefresh] Synced rotated refresh token to ~/.codex/auth.json")
        return true
    }

    /// Nested Cockpit `~/.antigravity_cockpit/codex_accounts/*.json` share the rotating RT.
    @discardableResult
    private static func syncCockpitCodexAccounts(oldRefresh: String, updated: [String: Any]) -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".antigravity_cockpit/codex_accounts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var wrote = 0
        for file in files where file.pathExtension == "json" {
            guard var root = NativeUsageFetcher.readAuthPayload(at: file) else { continue }
            var tokens = (root["tokens"] as? [String: Any]) ?? [:]
            let stored = stringValue(tokens, keys: ["refresh_token"])
                ?? stringValue(root, keys: ["refresh_token"])
            let matchesRefresh = stored == oldRefresh
            let matchesSeat = sameCodexSeat(root, as: updated)
            guard matchesRefresh || matchesSeat else { continue }
            if !matchesRefresh {
                if seatsConflict(root, updated: updated) { continue }
                if hasNewerAccessToken(root, than: updated) { continue }
            }
            if let access = stringValue(updated, keys: ["access_token"]) {
                tokens["access_token"] = access
                root["access_token"] = access
            }
            if let refresh = stringValue(updated, keys: ["refresh_token"]) {
                tokens["refresh_token"] = refresh
                root["refresh_token"] = refresh
            }
            if let idToken = stringValue(updated, keys: ["id_token"]) {
                tokens["id_token"] = idToken
                root["id_token"] = idToken
            }
            root["tokens"] = tokens
            root["token_updated_at"] = isoString(Date())
            if writeAuthFile(root, to: file) {
                wrote += 1
                NSLog("[TokenRefresh] Synced rotated refresh token to cockpit %@", file.lastPathComponent)
            }
        }
        return wrote
    }

    /// Same ChatGPT login + workspace. Team members share account_id — email must match too.
    static func sameCodexSeat(_ payload: [String: Any], as updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard let idA = seatAccountID(a), let idB = seatAccountID(b),
              idA.caseInsensitiveCompare(idB) == .orderedSame
        else { return false }
        guard let emailA = seatEmail(a), let emailB = seatEmail(b),
              emailA.caseInsensitiveCompare(emailB) == .orderedSame
        else { return false }
        return true
    }

    /// JWT seats disagree — do not copy Team tokens onto a Go file (or vice versa).
    private static func seatsConflict(_ payload: [String: Any], updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard let idA = CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(a, keys: ["access_token"])),
              let idB = CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(b, keys: ["access_token"]))
        else { return false }
        return idA.caseInsensitiveCompare(idB) != .orderedSame
    }

    private static func hasNewerAccessToken(_ payload: [String: Any], than updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard let oldExp = jwtExpiry(stringValue(a, keys: ["access_token"]) ?? ""),
              let newExp = jwtExpiry(stringValue(b, keys: ["access_token"]) ?? "")
        else { return false }
        return oldExp > newExp
    }

    private static func flattenedAuth(_ json: [String: Any]) -> [String: Any] {
        var out = json
        if let tokens = json["tokens"] as? [String: Any] {
            for (key, value) in tokens where out[key] == nil {
                out[key] = value
            }
        }
        return out
    }

    private static func seatAccountID(_ json: [String: Any]) -> String? {
        CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(json, keys: ["access_token"]))
            ?? stringValue(json, keys: ["account_id", "chatgpt_account_id"])
    }

    private static func seatEmail(_ json: [String: Any]) -> String? {
        stringValue(json, keys: ["email"])
            ?? JWTEmailExtractor.email(from: stringValue(json, keys: ["id_token"]))
            ?? JWTEmailExtractor.email(from: stringValue(json, keys: ["access_token"]))
    }

    static func copyTokenFields(from updated: [String: Any], onto original: [String: Any]) -> [String: Any] {
        var out = original
        for key in [
            "access_token", "refresh_token", "id_token",
            "accessToken", "refreshToken",
            "expires_in", "expired", "expires_at", "last_refresh",
            "account_id", "plan_type",
        ] {
            if let value = updated[key] {
                out[key] = value
            }
        }
        return out
    }

    /// Keep native CLI/desktop copies in lockstep after a rotating refresh.
    /// Stale ~/.claude, ~/.gemini, or Cursor state.vscdb copies reuse the old token and kill the family.
    static func syncNativeCredentialStores(type: String, oldRefresh: String, updated: [String: Any]) {
        let trimmed = oldRefresh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch type {
        case "codex":
            break // handled by syncCodexAuthJSON inside propagateRotatedTokens
        case "claude":
            syncClaudeCredentials(oldRefresh: trimmed, updated: updated)
        case "gemini", "antigravity":
            syncGeminiCredentials(oldRefresh: trimmed, updated: updated)
        case "cursor":
            syncCursorState(oldRefresh: trimmed, updated: updated)
        default:
            break
        }
    }

    private static func syncClaudeCredentials(oldRefresh: String, updated: [String: Any]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        let stored = stringValue(oauth, keys: ["refreshToken", "refresh_token"])
            ?? stringValue(root, keys: ["refresh_token"])
        guard stored == oldRefresh else { return }
        if let access = stringValue(updated, keys: ["access_token"]) {
            oauth["accessToken"] = access
            root["access_token"] = access
        }
        if let refresh = stringValue(updated, keys: ["refresh_token"]) {
            oauth["refreshToken"] = refresh
            root["refresh_token"] = refresh
        }
        root["claudeAiOauth"] = oauth
        guard writeAuthFile(root, to: url) else { return }
        if let json = String(data: (try? JSONSerialization.data(withJSONObject: root)) ?? Data(), encoding: .utf8) {
            writeClaudeKeychain(json)
        }
        NSLog("[TokenRefresh] Synced rotated refresh token to ~/.claude/.credentials.json")
    }

    private static func writeClaudeKeychain(_ json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-s", "Claude Code-credentials",
            "-a", NSUserName(),
            "-w", json,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func syncGeminiCredentials(oldRefresh: String, updated: [String: Any]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard var root = NativeUsageFetcher.readAuthPayload(at: url),
              stringValue(root, keys: ["refresh_token", "refreshToken"]) == oldRefresh
        else { return }
        if let access = stringValue(updated, keys: ["access_token"]) {
            root["access_token"] = access
        }
        if let refresh = stringValue(updated, keys: ["refresh_token"]) {
            root["refresh_token"] = refresh
        }
        if let idToken = stringValue(updated, keys: ["id_token"]) {
            root["id_token"] = idToken
        }
        if writeAuthFile(root, to: url) {
            NSLog("[TokenRefresh] Synced rotated refresh token to ~/.gemini/oauth_creds.json")
        }
    }

    private static func syncCursorState(oldRefresh: String, updated: [String: Any]) {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let stored = VscdbStore.readString(dbURL: db, key: "cursorAuth/refreshToken")
        guard stored == oldRefresh else { return }
        if let access = stringValue(updated, keys: ["access_token", "accessToken"]) {
            try? VscdbStore.writeString(dbURL: db, key: "cursorAuth/accessToken", value: access)
            try? VscdbStore.writeString(dbURL: db, key: "cursor.accessToken", value: access)
        }
        if let refresh = stringValue(updated, keys: ["refresh_token", "refreshToken"]) {
            try? VscdbStore.writeString(dbURL: db, key: "cursorAuth/refreshToken", value: refresh)
        }
        NSLog("[TokenRefresh] Synced rotated refresh token to Cursor state.vscdb")
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
        case "kimi":
            return await refreshKimi(payload)
        case "cursor":
            return await refreshCursor(payload)
        default:
            return nil
        }
    }

    enum OAuthGrantResult {
        case success([String: Any])
        /// OpenAI saw a previously rotated RT. The family may already be revoked — do not try older copies.
        case reuseRevoked
        case failed
    }

    static func openAIRefreshFields(refreshToken: String) -> [String: String] {
        [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": openAIClientID,
            "scope": openAIRefreshScope,
        ]
    }

    /// Single-flight OpenAI refresh so switch + keep-alive cannot rotate the same RT twice.
    static func refreshOpenAIGrant(refreshToken: String) async -> OAuthGrantResult {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }
        return await OpenAIRefreshFlight.shared.run(token: trimmed) {
            await postOpenAIRefresh(refreshToken: trimmed)
        }
    }

    private static func refreshOpenAI(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        switch await refreshOpenAIGrant(refreshToken: refresh) {
        case .success(let json):
            return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
        case .reuseRevoked, .failed:
            return nil
        }
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

    private static func refreshKimi(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let body = formBody([
            "client_id": kimiClientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        guard let json = await postForm(
            url: "https://auth.kimi.com/api/oauth/token",
            body: body
        ) else { return nil }
        return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
    }

    private static func refreshCursor(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let jsonBody: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": cursorClientID,
            "refresh_token": refresh,
        ]
        guard let json = await postJSON(url: "https://api2.cursor.sh/oauth/token", body: jsonBody),
              json["shouldLogout"] as? Bool != true
        else { return nil }
        guard let updated = applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true) else {
            return nil
        }
        var out = updated
        if let access = stringValue(out, keys: ["access_token"]) {
            out["accessToken"] = access
        }
        if let newRefresh = stringValue(out, keys: ["refresh_token"]) {
            out["refreshToken"] = newRefresh
        }
        return out
    }

    private static func applyOAuthTokenResponse(
        _ json: [String: Any],
        to payload: [String: Any],
        preferRefreshFromResponse: Bool
    ) -> [String: Any]? {
        guard let access = stringValue(json, keys: ["access_token", "accessToken"]) else { return nil }
        var updated = payload
        updated["access_token"] = access
        if let idToken = stringValue(json, keys: ["id_token", "idToken"]) {
            updated["id_token"] = idToken
        }
        if preferRefreshFromResponse, let newRefresh = stringValue(json, keys: ["refresh_token", "refreshToken"]) {
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

    private static func postOpenAIRefresh(refreshToken: String) async -> OAuthGrantResult {
        guard let endpoint = URL(string: "https://auth.openai.com/oauth/token") else { return .failed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = formBody(openAIRefreshFields(refreshToken: refreshToken))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if bodyText.lowercased().contains("refresh_token_reused") {
                NSLog("[TokenRefresh] OpenAI refresh_token_reused — stopping sibling attempts")
                return .reuseRevoked
            }
            guard let http = response as? HTTPURLResponse else { return .failed }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil,
                  stringValue(json, keys: ["access_token"]) != nil
            else {
                NSLog("[TokenRefresh] OpenAI refresh failed status %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return .failed
            }
            return .success(json)
        } catch {
            NSLog("[TokenRefresh] OpenAI refresh request error: %@", error.localizedDescription)
            return .failed
        }
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

    private static func accessTokenIssuedAt(from payload: [String: Any]) -> Date? {
        guard let token = stringValue(payload, keys: ["access_token", "accessToken", "key"]) else {
            return nil
        }
        return jwtClaimDate(token, key: "iat")
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        jwtClaimDate(token, key: "exp")
    }

    private static func jwtClaimDate(_ token: String, key: String) -> Date? {
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
        if let value = json[key] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = json[key] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// One in-flight OpenAI grant per refresh token. A second POST with the old token
/// returns `refresh_token_reused` and OpenAI revokes the family.
private actor OpenAIRefreshFlight {
    static let shared = OpenAIRefreshFlight()
    private var inflight: [String: Task<TokenRefreshService.OAuthGrantResult, Never>] = [:]

    func run(
        token: String,
        work: @Sendable @escaping () async -> TokenRefreshService.OAuthGrantResult
    ) async -> TokenRefreshService.OAuthGrantResult {
        if let existing = inflight[token] {
            return await existing.value
        }
        let task = Task { await work() }
        inflight[token] = task
        let result = await task.value
        inflight[token] = nil
        return result
    }
}
