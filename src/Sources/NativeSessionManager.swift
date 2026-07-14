import AppKit
import Foundation

/// Identity of whatever account is *currently live* in a native tool.
struct NativeSessionIdentity: Equatable {
    let email: String?
    let accountID: String?
    let plan: String?

    var label: String { email ?? accountID ?? "unknown" }
}

enum NativeSwitchOutcome: Equatable {
    case switched(message: String)
    case failure(message: String)
}

/// Detects which account is active in the native CLI/desktop tools and switches the
/// active session by rewriting the native auth files and (optionally) restarting the
/// associated desktop app — the same technique Cockpit Tools uses.
///
/// VibeProxy stores accounts as CLIProxy auth files under `~/.cli-proxy-api/`; this
/// manager translates a selected account's tokens into the *native* auth location
/// (`~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`).
///
/// For ChatGPT/Codex, one OAuth login can own **multiple** workspaces (Go + Team/Enterprise).
/// `switchTo(..., chatGPTAccountID:)` writes that membership's id into `tokens.account_id`
/// so Codex/ChatGPT actually run under the chosen subscription — not always JWT "go".
final class NativeSessionManager: ObservableObject {
    static let shared = NativeSessionManager()

    /// Detected live identity per provider (nil = none / not logged in).
    @Published private(set) var currentByProvider: [ServiceType: NativeSessionIdentity] = [:]
    /// `AuthAccount.id`s that are the live native session (for hiding the Switch button).
    @Published private(set) var currentAccountIDs: Set<String> = []
    @Published private(set) var isRefreshing = false

    private let fileManager = FileManager.default
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Providers we can both detect and switch. (Antigravity is intentionally excluded:
    /// it does not use ~/.gemini/google_accounts.json, so reusing Gemini's identity/creds
    /// would be wrong.)
    static let switchableProviderIDs: Set<String> = ["codex", "claude", "gemini"]

    func supportsSwitching(_ type: ServiceType) -> Bool {
        guard let id = type.usageProviderID else { return false }
        return Self.switchableProviderIDs.contains(id)
    }

    func isCurrent(_ account: AuthAccount) -> Bool {
        currentAccountIDs.contains(account.id)
    }

    /// True when the native Codex session is already on this ChatGPT workspace/subscription.
    func isCurrentSubscription(_ account: AuthAccount, chatGPTAccountID: String?) -> Bool {
        guard account.type == .codex else { return isCurrent(account) }
        guard let identity = currentByProvider[.codex] else { return false }
        guard matches(account, identity) else { return false }
        guard let wanted = chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wanted.isEmpty
        else {
            // No explicit membership: "current login" if email/account matches.
            return true
        }
        return identity.accountID?.caseInsensitiveCompare(wanted) == .orderedSame
    }

    func currentIdentity(for type: ServiceType) -> NativeSessionIdentity? {
        currentByProvider[type]
    }

    // MARK: - Detection

    /// Reads the native auth locations off the main thread and matches them against the
    /// provided VibeProxy accounts. Cheap (small files + one keychain read for Claude).
    func refresh(accounts: [ServiceType: [AuthAccount]]) {
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let (identities, ids) = await self.detectAll(accounts: accounts)
            await MainActor.run {
                self.currentByProvider = identities
                self.currentAccountIDs = ids
                self.isRefreshing = false
            }
        }
    }

    private func detectAll(
        accounts: [ServiceType: [AuthAccount]]
    ) async -> ([ServiceType: NativeSessionIdentity], Set<String>) {
        var identities: [ServiceType: NativeSessionIdentity] = [:]
        var ids = Set<String>()

        for type in ServiceType.allCases {
            guard let providerID = type.usageProviderID,
                  Self.switchableProviderIDs.contains(providerID),
                  let identity = detectIdentity(for: type)
            else { continue }
            identities[type] = identity

            if let match = (accounts[type] ?? []).first(where: { matches($0, identity) }) {
                ids.insert(match.id)
            }
        }
        return (identities, ids)
    }

    private func detectIdentity(for type: ServiceType) -> NativeSessionIdentity? {
        switch type {
        case .codex: return detectCodexIdentity()
        case .claude: return detectClaudeIdentity()
        case .gemini: return detectGoogleIdentity()
        default: return nil
        }
    }

    private func detectCodexIdentity() -> NativeSessionIdentity? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let json = readJSON(url) else { return nil }
        let tokens = (json["tokens"] as? [String: Any]) ?? json
        let access = tokens["access_token"] as? String
        let claims = access.flatMap(Self.decodeJWT)
        let accountID = (tokens["account_id"] as? String)
            ?? Self.openAIAccountID(from: claims)
        let email = Self.openAIEmail(from: claims)
        let plan = Self.openAIPlan(from: claims)
        guard accountID != nil || email != nil else { return nil }
        return NativeSessionIdentity(email: email, accountID: accountID, plan: plan)
    }

    private func detectClaudeIdentity() -> NativeSessionIdentity? {
        // Identity lives in ~/.claude/.claude.json → oauthAccount.
        let configURL = home.appendingPathComponent(".claude/.claude.json")
        if let json = readJSON(configURL),
           let oauth = json["oauthAccount"] as? [String: Any]
        {
            let email = oauth["emailAddress"] as? String
            let uuid = oauth["accountUuid"] as? String
            if email != nil || uuid != nil {
                return NativeSessionIdentity(email: email, accountID: uuid, plan: nil)
            }
        }
        // Fall back to presence of credentials (logged in but identity unknown).
        if readClaudeCredentials() != nil {
            return NativeSessionIdentity(email: nil, accountID: nil, plan: nil)
        }
        return nil
    }

    private func detectGoogleIdentity() -> NativeSessionIdentity? {
        let url = home.appendingPathComponent(".gemini/google_accounts.json")
        guard let json = readJSON(url) else { return nil }
        guard let active = json["active"] as? String, !active.isEmpty else { return nil }
        return NativeSessionIdentity(email: active, accountID: nil, plan: nil)
    }

    private func matches(_ account: AuthAccount, _ identity: NativeSessionIdentity) -> Bool {
        if let email = account.email?.lowercased(),
           let other = identity.email?.lowercased(),
           email == other
        {
            return true
        }
        // Codex: also match by stable account_id from the stored file.
        if account.type == .codex,
           let identityID = identity.accountID,
           let payload = readJSON(account.filePath),
           let fileID = payload["account_id"] as? String,
           fileID == identityID
        {
            return true
        }
        return false
    }

    // MARK: - Switching

    /// Switch the native session to `account`.
    /// - Parameter chatGPTAccountID: For Codex multi-subscription logins, the membership /
    ///   workspace id to pin in `tokens.account_id` (Team/Enterprise vs Go).
    /// - Parameter subscriptionLabel: Human label for the toast (e.g. "ChatGPT Team · CR").
    @MainActor
    func switchTo(
        _ account: AuthAccount,
        chatGPTAccountID: String? = nil,
        subscriptionLabel: String? = nil,
        restartApp: Bool
    ) async -> NativeSwitchOutcome {
        guard supportsSwitching(account.type) else {
            return .failure(message: "Switching \(account.type.displayName) is not supported yet.")
        }
        guard let src = readJSON(account.filePath) else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName).")
        }

        // Disk + Keychain writes run off the main thread (the `security` subprocess can
        // block for ~100ms). Only the AppKit app-restart below stays on the main actor.
        let type = account.type
        let email = account.email
        let preferredAccountID = chatGPTAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let writeError: String? = await Task.detached(priority: .userInitiated) { [self] in
            do {
                switch type {
                case .codex: try writeCodexAuth(from: src, preferredAccountID: preferredAccountID)
                case .claude: try writeClaudeAuth(from: src)
                case .gemini: try writeGoogleAuth(from: src, email: email)
                default: return "Switching \(type.displayName) is not supported yet."
                }
                return nil
            } catch {
                return "Switch failed: \(error.localizedDescription)"
            }
        }.value

        if let writeError { return .failure(message: writeError) }

        // Update live identity from disk immediately (full account list refresh follows via UI).
        if let identity = detectIdentity(for: type) {
            currentByProvider[type] = identity
            if matches(account, identity) {
                currentAccountIDs.insert(account.id)
            }
        }

        let targetName = subscriptionLabel?.nilIfEmpty
            ?? account.baseDisplayName
        var msg = "Switched \(type.displayName) to \(targetName)."
        if restartApp {
            let restarted = await restartApps(for: type)
            if !restarted.isEmpty {
                msg += " Restarted \(restarted.joined(separator: ", "))."
            } else {
                msg += " Native auth written — launch \(type.displayName) to pick it up."
            }
        } else {
            msg += " Restart the app (or enable restart-on-switch in Settings) to load it."
        }
        return .switched(message: msg)
    }

    // MARK: - Native writers

    private func writeCodexAuth(from src: [String: Any], preferredAccountID: String? = nil) throws {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        let url = home.appendingPathComponent(".codex/auth.json")
        try ensureParent(url)

        var tokens: [String: Any] = ["access_token": access]
        if let idToken = nonEmpty(src["id_token"]) { tokens["id_token"] = idToken }
        if let refresh = nonEmpty(src["refresh_token"]) { tokens["refresh_token"] = refresh }
        // Prefer explicit membership id (Team/Enterprise). JWT default is often Go and would
        // make every "Switch" land on the personal plan.
        if let preferredAccountID {
            tokens["account_id"] = preferredAccountID
        } else if let accountID = nonEmpty(src["account_id"])
            ?? Self.openAIAccountID(from: Self.decodeJWT(access))
        {
            tokens["account_id"] = accountID
        }

        var out: [String: Any] = ["tokens": tokens]
        // Preserve any existing API key field (usually null).
        if let existing = readJSON(url), let key = existing["OPENAI_API_KEY"], !(key is NSNull) {
            out["OPENAI_API_KEY"] = key
        } else {
            out["OPENAI_API_KEY"] = NSNull()
        }
        out["last_refresh"] = nonEmpty(src["last_refresh"]) ?? Self.isoNow()

        try backupThenWrite(json: out, to: url)
    }

    private func writeClaudeAuth(from src: [String: Any]) throws {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        var oauth: [String: Any] = ["accessToken": access]
        if let refresh = nonEmpty(src["refresh_token"]) { oauth["refreshToken"] = refresh }
        if let expiresAt = expiryMillis(from: src) { oauth["expiresAt"] = expiresAt }
        if let sub = nonEmpty(src["subscriptionType"]) ?? nonEmpty(src["plan_type"]) {
            oauth["subscriptionType"] = sub
        }
        oauth["scopes"] = ["user:inference", "user:profile"]
        let credentials: [String: Any] = ["claudeAiOauth": oauth]

        // macOS primary store is the Keychain; also write the plaintext file as fallback.
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
        if let jsonString = String(data: data, encoding: .utf8) {
            writeClaudeKeychain(jsonString)
        }
        let credURL = home.appendingPathComponent(".claude/.credentials.json")
        try ensureParent(credURL)
        try backupThenWrite(json: credentials, to: credURL)

        // Merge identity into ~/.claude/.claude.json so detection reflects the switch.
        if let email = nonEmpty(src["email"]) {
            let configURL = home.appendingPathComponent(".claude/.claude.json")
            var config = readJSON(configURL) ?? [:]
            var oauthAccount = (config["oauthAccount"] as? [String: Any]) ?? [:]
            oauthAccount["emailAddress"] = email
            config["oauthAccount"] = oauthAccount
            try backupThenWrite(json: config, to: configURL)
        }
    }

    private func writeGoogleAuth(from src: [String: Any], email: String?) throws {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        var creds: [String: Any] = ["access_token": access, "token_type": "Bearer"]
        if let refresh = nonEmpty(src["refresh_token"]) { creds["refresh_token"] = refresh }
        if let idToken = nonEmpty(src["id_token"]) { creds["id_token"] = idToken }
        if let expiry = expiryMillis(from: src) { creds["expiry_date"] = expiry }
        creds["scope"] = "https://www.googleapis.com/auth/cloud-platform"

        let credURL = home.appendingPathComponent(".gemini/oauth_creds.json")
        try ensureParent(credURL)
        try backupThenWrite(json: creds, to: credURL)

        // Update the active-account pointer.
        if let email {
            let accountsURL = home.appendingPathComponent(".gemini/google_accounts.json")
            var accounts = readJSON(accountsURL) ?? [:]
            var old = (accounts["old"] as? [String]) ?? []
            if let previous = accounts["active"] as? String,
               !previous.isEmpty,
               previous.lowercased() != email.lowercased(),
               !old.contains(previous)
            {
                old.append(previous)
            }
            old.removeAll { $0.lowercased() == email.lowercased() }
            accounts["active"] = email
            accounts["old"] = old
            try backupThenWrite(json: accounts, to: accountsURL)
        }
    }

    // MARK: - App restart (quit + relaunch) — Cockpit-style

    /// Kill provider desktop apps (and matching helper processes), then relaunch so they
    /// re-read native auth. Mirrors Cockpit: close Codex processes → rewrite auth already
    /// done → start Codex.app again.
    @MainActor
    private func restartApps(for type: ServiceType) async -> [String] {
        switch type {
        case .codex:
            // Official desktop + CLI helpers that pin the old account_id in memory.
            return await killAndRelaunch(
                label: "Codex",
                bundleIDs: ["com.openai.codex", "com.openai.chat"],
                names: ["Codex", "ChatGPT"],
                pathFragments: [
                    "Codex.app/Contents/MacOS/Codex",
                    "ChatGPT.app/Contents/MacOS/ChatGPT",
                ],
                // Also force-kill detached CLI sessions so the next `codex` uses new auth.
                processNames: ["codex"]
            )
        case .claude:
            return await killAndRelaunch(
                label: "Claude",
                bundleIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                names: ["Claude"],
                pathFragments: ["Claude.app/Contents/MacOS/Claude"],
                processNames: ["claude"]
            )
        case .gemini:
            // Gemini is mostly CLI; kill long-lived CLI processes if any.
            return await killAndRelaunch(
                label: "Gemini",
                bundleIDs: [],
                names: [],
                pathFragments: [],
                processNames: ["gemini"]
            )
        default:
            return []
        }
    }

    /// Returns human labels of apps that were restarted (or "CLI helpers" if only processes died).
    @MainActor
    private func killAndRelaunch(
        label: String,
        bundleIDs: [String],
        names: [String],
        pathFragments: [String],
        processNames: [String]
    ) async -> [String] {
        var relaunchURLs: [URL] = []
        var sawRunning = false

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            if let bundle = app.bundleIdentifier, bundleIDs.contains(bundle) { return true }
            if let name = app.localizedName,
               names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            {
                return true
            }
            return false
        }
        for app in apps {
            sawRunning = true
            if let url = app.bundleURL { relaunchURLs.append(url) }
            app.terminate()
        }

        // Path-fragment kill (Cockpit uses pgrep -f "Codex.app/Contents/MacOS/Codex").
        let pgrepPIDs = Self.pgrepPIDs(pathFragments: pathFragments, processNames: processNames)
        if !pgrepPIDs.isEmpty {
            sawRunning = true
            Self.signalPIDs(pgrepPIDs, sig: SIGTERM)
        }

        // Wait up to ~6s for graceful quit, then SIGKILL stragglers.
        for _ in 0..<12 {
            let stillApps = apps.contains(where: { !$0.isTerminated })
            let stillPIDs = pgrepPIDs.contains(where: { Self.isPIDAlive($0) })
            if !stillApps && !stillPIDs { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        for app in apps where !app.isTerminated { app.forceTerminate() }
        let leftover = pgrepPIDs.filter { Self.isPIDAlive($0) }
        if !leftover.isEmpty { Self.signalPIDs(leftover, sig: SIGKILL) }

        // Resolve launch URLs even if the app wasn't running (open from /Applications).
        if relaunchURLs.isEmpty {
            for name in names {
                let candidate = URL(fileURLWithPath: "/Applications/\(name).app")
                if fileManager.fileExists(atPath: candidate.path) {
                    relaunchURLs.append(candidate)
                }
            }
            for bundleID in bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    relaunchURLs.append(url)
                }
            }
        }

        // Deduplicate by path.
        var seen = Set<String>()
        let uniqueURLs = relaunchURLs.filter { seen.insert($0.path).inserted }

        guard !uniqueURLs.isEmpty else {
            // Only CLI processes were killed — nothing to relaunch.
            return sawRunning ? ["\(label) processes"] : []
        }

        // Always relaunch when restart-on-switch is on (Cockpit "launch on switch"), so the
        // user lands on the new subscription without a manual open.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        var launched: [String] = []
        for url in uniqueURLs {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                launched.append(url.deletingPathExtension().lastPathComponent)
            } catch {
                // Fall through — auth is still written.
            }
        }
        if launched.isEmpty, sawRunning {
            return ["\(label) processes"]
        }
        return launched
    }

    private static func pgrepPIDs(pathFragments: [String], processNames: [String]) -> [Int32] {
        var pids = Set<Int32>()
        for fragment in pathFragments where !fragment.isEmpty {
            for pid in runPgrep(arguments: ["-f", fragment]) { pids.insert(pid) }
        }
        for name in processNames where !name.isEmpty {
            for pid in runPgrep(arguments: ["-x", name]) { pids.insert(pid) }
        }
        // Never signal ourselves.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        pids.remove(selfPID)
        return Array(pids)
    }

    private static func runPgrep(arguments: [String]) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func signalPIDs(_ pids: [Int32], sig: Int32) {
        for pid in pids where pid > 1 {
            kill(pid, sig)
        }
    }

    private static func isPIDAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - Keychain (Claude)

    private func writeClaudeKeychain(_ json: String) {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-a", user,
            "-s", "Claude Code-credentials",
            "-w", json,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func readClaudeCredentials() -> [String: Any]? {
        // Try Keychain first, then plaintext file.
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", user, "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0,
               let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let jsonData = string.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            {
                return json
            }
        } catch {
            return nil
        }
        return readJSON(home.appendingPathComponent(".claude/.credentials.json"))
    }

    // MARK: - IO helpers

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func ensureParent(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Back up the existing native file once, then write the new JSON atomically.
    /// These files hold OAuth tokens, so keep them owner-only (0600).
    private func backupThenWrite(json: [String: Any], to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("vibeproxy-bak")
            if !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.copyItem(at: url, to: backup)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        // atomic write replaces the file, resetting perms to the umask default (often 0644);
        // restore owner-only so tokens aren't world/group readable.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func expiryMillis(from src: [String: Any]) -> Int? {
        if let expiresIn = src["expires_in"] as? Int, expiresIn > 0 {
            return Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
        }
        if let expired = nonEmpty(src["expired"]) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: expired) ?? {
                let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: expired)
            }() {
                return Int(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    enum SwitchError: LocalizedError {
        case missingToken(String)
        var errorDescription: String? {
            switch self {
            case .missingToken(let name): return "stored account is missing \(name)"
            }
        }
    }

    // MARK: - JWT helpers (OpenAI)

    static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func openAIAccountID(from claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            if let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
            if let id = auth["account_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    static func openAIEmail(from claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let email = claims["email"] as? String, !email.isEmpty { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty
        {
            return email
        }
        return nil
    }

    static func openAIPlan(from claims: [String: Any]?) -> String? {
        guard let claims,
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty
        else { return nil }
        return plan
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
