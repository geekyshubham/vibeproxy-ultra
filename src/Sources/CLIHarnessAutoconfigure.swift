import Foundation

/// Detected coding CLI / IDE harness that can point at the local VibeRouter.
struct CLIHarness: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case openCode
        case geminiCLI
        case factory
        case kiroCLI
        case amp

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex CLI"
            case .openCode: return "OpenCode"
            case .geminiCLI: return "Gemini CLI"
            case .factory: return "Factory (Droid)"
            case .kiroCLI: return "Kiro CLI"
            case .amp: return "Amp CLI"
            }
        }

        var systemImage: String {
            switch self {
            case .claudeCode: return "brain.head.profile"
            case .codex: return "terminal"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
            case .geminiCLI: return "sparkles"
            case .factory: return "hammer"
            case .kiroCLI: return "bolt.fill"
            case .amp: return "waveform.path"
            }
        }

        var supportsAutoconfigure: Bool {
            switch self {
            case .claudeCode, .codex, .openCode, .geminiCLI, .factory: return true
            case .kiroCLI, .amp: return false // Kiro is a *source* subscription; Amp is special-cased upstream
            }
        }

        var notes: String {
            switch self {
            case .claudeCode:
                return "Sets ANTHROPIC_BASE_URL in ~/.claude/settings.json"
            case .codex:
                return "Adds a VibeRouter model_provider in ~/.codex/config.toml"
            case .openCode:
                return "Adds a viberouter provider in ~/.config/opencode/opencode.json"
            case .geminiCLI:
                return "Sets GEMINI_API_BASE / GOOGLE_GEMINI_BASE_URL in ~/.gemini/settings.json"
            case .factory:
                return "Writes custom_models base_url in ~/.factory/config.json"
            case .kiroCLI:
                return "Kiro is a provider you connect in Settings (source), not a client harness"
            case .amp:
                return "Amp management traffic is handled by the proxy when pointed at localhost"
            }
        }
    }

    let kind: Kind
    let binaryPath: String?
    let configPath: String?
    let isInstalled: Bool
    /// True when config already points at our proxy host/port.
    let isConfigured: Bool
    let detail: String

    var id: String { kind.rawValue }
}

/// Discovers local coding CLIs and rewrites their config to use VibeRouter.
enum CLIHarnessAutoconfigure {
    static let dummyAPIKey = "viberouter"
    private static let backupSuffix = ".viberouter-bak"

    // MARK: - Discovery

    static func discover(proxyPort: Int = 8317) -> [CLIHarness] {
        CLIHarness.Kind.allCases.map { kind in
            let binary = resolveBinary(for: kind)
            let config = resolveConfigPath(for: kind)
            let installed = binary != nil
                || (config.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            let configured = isConfigured(kind: kind, configURL: config, proxyPort: proxyPort)
            let detail: String = {
                if let binary { return binary }
                if let config { return config.path }
                return "Not found"
            }()
            return CLIHarness(
                kind: kind,
                binaryPath: binary,
                configPath: config?.path,
                isInstalled: installed,
                isConfigured: configured,
                detail: detail
            )
        }
    }

    // MARK: - Autoconfigure

    @discardableResult
    static func autoconfigure(_ kind: CLIHarness.Kind, proxyPort: Int = 8317) throws -> String {
        guard kind.supportsAutoconfigure else {
            throw AutoconfigureError.notSupported(kind.displayName)
        }
        let base = "http://127.0.0.1:\(proxyPort)"
        let baseV1 = "\(base)/v1"
        switch kind {
        case .claudeCode:
            try configureClaudeCode(baseURL: base, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Claude Code → \(base)"
        case .codex:
            try configureCodex(baseURL: baseV1, apiKey: dummyAPIKey)
            return "Codex → \(baseV1)"
        case .openCode:
            try configureOpenCode(baseURL: baseV1, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "OpenCode → \(baseV1)"
        case .geminiCLI:
            try configureGemini(baseURL: baseV1, apiKey: dummyAPIKey)
            return "Gemini CLI → \(baseV1)"
        case .factory:
            try configureFactory(baseURL: base, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Factory → \(base)"
        case .kiroCLI, .amp:
            throw AutoconfigureError.notSupported(kind.displayName)
        }
    }

    static func autoconfigureAll(proxyPort: Int = 8317) -> (ok: [String], failed: [String]) {
        var ok: [String] = []
        var failed: [String] = []
        for harness in discover(proxyPort: proxyPort) where harness.isInstalled && harness.kind.supportsAutoconfigure {
            do {
                let msg = try autoconfigure(harness.kind, proxyPort: proxyPort)
                ok.append(msg)
            } catch {
                failed.append("\(harness.kind.displayName): \(error.localizedDescription)")
            }
        }
        return (ok, failed)
    }

    // MARK: - Per-tool writers

    private static func configureClaudeCode(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var root = try readJSONForMerge(url)
        try backupIfNeeded(url)
        var env = root["env"] as? [String: Any] ?? [:]
        env["ANTHROPIC_BASE_URL"] = baseURL
        env["ANTHROPIC_API_KEY"] = apiKey
        env["ANTHROPIC_AUTH_TOKEN"] = apiKey
        // Only pin a model the proxy actually advertises. A stale provider-scoped
        // ID such as "[Kiro] claude-sonnet-4-5" fails every request with
        // "unknown provider for model", so drop it rather than leave it pinned.
        let pinned = env["ANTHROPIC_MODEL"] as? String
        if pinned == nil || pinned?.contains("[") == true {
            if let resolved = resolveLiveModel(anthropicModelPreferences, port: proxyPort) {
                env["ANTHROPIC_MODEL"] = resolved
            } else {
                env.removeValue(forKey: "ANTHROPIC_MODEL")
            }
        }
        root["env"] = env
        try writeJSON(root, to: url)
    }

    private static func configureCodex(baseURL: String, apiKey: String) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = renameLegacyProviderKey(inTOML: text)

        // Ensure model_provider + provider table. Avoid duplicating if already present.
        if text.contains("model_providers.viberouter") || text.contains("[model_providers.viberouter]") {
            // Update base_url lines inside the viberouter table (simple rewrite of known keys).
            text = replaceOrAppendTOMLKey(in: text, key: "base_url", value: "\"\(baseURL)\"", section: "model_providers.viberouter")
            if !text.contains("model_provider") || !text.contains("\"viberouter\"") {
                if text.contains("model_provider") {
                    text = text.replacingOccurrences(
                        of: #"model_provider\s*=\s*"[^"]*""#,
                        with: "model_provider = \"viberouter\"",
                        options: .regularExpression
                    )
                } else {
                    text = "model_provider = \"viberouter\"\n" + text
                }
            }
        } else {
            let block = """

            # --- VibeRouter (auto-configured) ---
            model_provider = "viberouter"

            [model_providers.viberouter]
            name = "VibeRouter"
            base_url = "\(baseURL)"
            wire_api = "chat"
            env_key = "VIBEROUTER_API_KEY"
            """
            text += block
        }
        // Seed env file hint via empty optional — codex reads env_key from environment.
        // Also write a tiny sidecar for the key so users can export it.
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let envHint = codexHome.appendingPathComponent("viberouter.env")
        try "export VIBEROUTER_API_KEY=\"\(apiKey)\"\n".write(to: envHint, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: codexHome.appendingPathComponent(legacyProviderKey + ".env"))
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func configureOpenCode(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/opencode.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/opencode.jsonc"),
        ]
        let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? candidates[0]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        var provider = root["provider"] as? [String: Any] ?? [:]

        // Fetch live model ids when proxy is up; fall back to common aliases.
        let modelIDs = fetchProxyModelIDs(port: proxyPort)
        var models: [String: Any] = [:]
        for id in modelIDs.prefix(40) {
            models[openCodeModelKey(id)] = [
                "name": id,
                "tool_call": true,
            ] as [String: Any]
        }
        if models.isEmpty {
            for id in anthropicModelPreferences.prefix(1) + openAIModelPreferences.prefix(1) {
                models[openCodeModelKey(id)] = ["name": id, "tool_call": true] as [String: Any]
            }
        }

        provider.removeValue(forKey: legacyProviderKey)
        if let pinned = root["model"] as? String, pinned.hasPrefix(legacyProviderKey + "/") {
            root["model"] = providerKey + pinned.dropFirst(legacyProviderKey.count)
        }
        provider[providerKey] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "VibeRouter",
            "options": [
                "baseURL": baseURL,
                "apiKey": apiKey,
            ],
            "models": models,
        ] as [String: Any]
        root["provider"] = provider
        if root["model"] == nil {
            let preferred = resolveLiveModel(anthropicModelPreferences, port: proxyPort, available: modelIDs)
                ?? models.keys.sorted().first
            if let preferred {
                root["model"] = "\(providerKey)/\(openCodeModelKey(preferred))"
            }
        }
        try writeJSON(root, to: url)
    }

    private static func configureGemini(baseURL: String, apiKey: String) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        var env = root["env"] as? [String: Any] ?? [:]
        env["GEMINI_API_BASE"] = baseURL
        env["GOOGLE_GEMINI_BASE_URL"] = baseURL
        env["GEMINI_API_KEY"] = apiKey
        root["env"] = env
        try writeJSON(root, to: url)
    }

    private static func configureFactory(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        let available = fetchProxyModelIDs(port: proxyPort)
        var models: [[String: Any]] = []
        if let anthropicModel = resolveLiveModel(anthropicModelPreferences, port: proxyPort, available: available) {
            models.append([
                "model_display_name": "VP: \(anthropicModel)",
                "model": anthropicModel,
                "base_url": baseURL,
                "api_key": apiKey,
                "provider": "anthropic",
            ])
        }
        if let openAIModel = resolveLiveModel(openAIModelPreferences, port: proxyPort, available: available) {
            models.append([
                "model_display_name": "VP: \(openAIModel)",
                "model": openAIModel,
                "base_url": "\(baseURL)/v1",
                "api_key": apiKey,
                "provider": "openai",
            ])
        }
        // Merge: replace previous VibeRouter-tagged entries, keep user custom models.
        let existing = root["custom_models"] as? [[String: Any]] ?? []
        let kept = existing.filter { entry in
            let name = (entry["model_display_name"] as? String) ?? ""
            return !name.hasPrefix("VP:")
        }
        root["custom_models"] = kept + models
        try writeJSON(root, to: url)
    }

    // MARK: - Detection helpers

    private static func resolveBinary(for kind: CLIHarness.Kind) -> String? {
        let names: [String]
        switch kind {
        case .claudeCode: names = ["claude"]
        case .codex: names = ["codex"]
        case .openCode: names = ["opencode"]
        case .geminiCLI: names = ["gemini"]
        case .factory: names = ["droid", "factory"]
        case .kiroCLI: names = ["kiro-cli", "kiro"]
        case .amp: names = ["amp"]
        }
        for name in names {
            if let path = which(name) { return path }
        }
        // App bundles
        switch kind {
        case .codex:
            let app = "/Applications/Codex.app"
            if FileManager.default.fileExists(atPath: app) { return app }
        case .claudeCode:
            let app = "/Applications/Claude.app"
            if FileManager.default.fileExists(atPath: app) { return app }
        default:
            break
        }
        return nil
    }

    private static func resolveConfigPath(for kind: CLIHarness.Kind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .claudeCode:
            return home.appendingPathComponent(".claude/settings.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .openCode:
            let json = home.appendingPathComponent(".config/opencode/opencode.json")
            let jsonc = home.appendingPathComponent(".config/opencode/opencode.jsonc")
            if FileManager.default.fileExists(atPath: json.path) { return json }
            if FileManager.default.fileExists(atPath: jsonc.path) { return jsonc }
            return json
        case .geminiCLI:
            return home.appendingPathComponent(".gemini/settings.json")
        case .factory:
            return home.appendingPathComponent(".factory/config.json")
        case .kiroCLI:
            return home.appendingPathComponent(".kiro")
        case .amp:
            return home.appendingPathComponent(".config/amp")
        }
    }

    private static func isConfigured(kind: CLIHarness.Kind, configURL: URL?, proxyPort: Int) -> Bool {
        guard let configURL, FileManager.default.fileExists(atPath: configURL.path) else {
            return false
        }
        let needle = "127.0.0.1:\(proxyPort)"
        let needleLocal = "localhost:\(proxyPort)"
        if kind == .codex {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            let named = text.contains(providerKey) || text.contains(legacyProviderKey)
            return named && (text.contains(needle) || text.contains(needleLocal))
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return text.contains(needle) || text.contains(needleLocal)
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    /// Provider key written into harness configs. `legacyProviderKey` is the
    /// pre-rename name, still present in configs written by older builds.
    static let providerKey = "viberouter"
    static let legacyProviderKey = "vibeproxy"

    /// Converts a pre-rename Codex block in place. Appending a second provider
    /// instead would leave two tables and an ambiguous `model_provider`.
    static func renameLegacyProviderKey(inTOML text: String) -> String {
        guard text.contains(legacyProviderKey) else { return text }
        return text
            .replacingOccurrences(of: "model_providers.\(legacyProviderKey)", with: "model_providers.\(providerKey)")
            .replacingOccurrences(of: "model_provider = \"\(legacyProviderKey)\"", with: "model_provider = \"\(providerKey)\"")
            .replacingOccurrences(of: "VIBEPROXY_API_KEY", with: "VIBEROUTER_API_KEY")
            .replacingOccurrences(of: "# --- VibeProxy (auto-configured) ---", with: "# --- VibeRouter (auto-configured) ---")
    }

    /// Anthropic-format IDs to pin, best first. Must be plain catalog IDs: the
    /// proxy has no provider-scoped `[Provider] model` namespace.
    static let anthropicModelPreferences = [
        "claude-sonnet-4-5-20250929",
        "claude-sonnet-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-20250514",
    ]

    static let openAIModelPreferences = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
    ]

    /// First preference the proxy actually advertises, or nil when none match.
    static func resolveLiveModel(_ preferences: [String], port: Int, available: [String]? = nil) -> String? {
        let ids = available ?? fetchProxyModelIDs(port: port)
        guard !ids.isEmpty else { return nil }
        return preferences.first(where: ids.contains)
    }

    /// OpenCode model keys cannot carry spaces or brackets.
    static func openCodeModelKey(_ id: String) -> String {
        id.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func fetchProxyModelIDs(port: Int) -> [String] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer \(dummyAPIKey)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var ids: [String] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]]
            else { return }
            ids = list.compactMap { $0["id"] as? String }
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return ids
    }

    // MARK: - IO

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Reads an existing JSON config for in-place merging. Returns [:] only when
    /// the file is genuinely absent/empty; throws if it exists but cannot be
    /// parsed, so we never clobber a user's config (e.g. a .jsonc with comments
    /// or trailing commas) by silently replacing it with a stub.
    private static func readJSONForMerge(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutoconfigureError.unparseableConfig(url.lastPathComponent)
        }
        return json
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func backupIfNeeded(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bak = URL(fileURLWithPath: url.path + backupSuffix)
        if !FileManager.default.fileExists(atPath: bak.path) {
            try FileManager.default.copyItem(at: url, to: bak)
        }
    }

    private static func replaceOrAppendTOMLKey(
        in text: String,
        key: String,
        value: String,
        section: String
    ) -> String {
        // Scope the edit to the `[section]` table only — bounded by the next
        // `[...]` header (or EOF) — so we never clobber another provider's
        // base_url elsewhere in the file. Append the key if the table lacks it.
        guard let header = text.range(of: "[\(section)]") else { return text }
        let bodyStart = header.upperBound
        let rest = text[bodyStart...]
        let bodyEnd = rest.range(of: #"\n\s*\["#, options: .regularExpression)?.lowerBound ?? text.endIndex
        let body = String(text[bodyStart..<bodyEnd])
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"[^\"]*\""
        let newBody: String
        if body.range(of: pattern, options: .regularExpression) != nil {
            newBody = body.replacingOccurrences(
                of: pattern,
                with: "\(key) = \(value)",
                options: .regularExpression
            )
        } else {
            newBody = "\n\(key) = \(value)" + body
        }
        return text.replacingCharacters(in: bodyStart..<bodyEnd, with: newBody)
    }

    enum AutoconfigureError: LocalizedError {
        case notSupported(String)
        case unparseableConfig(String)
        var errorDescription: String? {
            switch self {
            case .notSupported(let name):
                return "\(name) is not autoconfigured as a client harness"
            case .unparseableConfig(let name):
                return "\(name) exists but couldn't be parsed (comments, trailing commas, or malformed JSON). Refusing to overwrite it — edit or remove it manually, then retry."
            }
        }
    }
}

