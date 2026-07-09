import Foundation

// MARK: - Models

enum ProviderStatusLevel: String, Codable, Equatable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var sortRank: Int {
        switch self {
        case .critical: return 0
        case .major: return 1
        case .minor: return 2
        case .maintenance: return 3
        case .unknown: return 4
        case .none: return 5
        }
    }

    var displayName: String {
        switch self {
        case .none: return "Operational"
        case .minor: return "Degraded"
        case .major: return "Partial outage"
        case .critical: return "Major outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Unknown"
        }
    }
}

struct ProviderStatusIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let impact: String?
    let shortlink: URL?
    let updatedAt: Date?
}

struct ProviderStatusSnapshot: Identifiable, Equatable {
    let id: String
    let providerKey: String
    let displayName: String
    let level: ProviderStatusLevel
    let description: String?
    let pageURL: URL?
    let updatedAt: Date?
    let incidents: [ProviderStatusIncident]
    let errorMessage: String?
    /// True when status is inferred from an API health probe (no public statuspage feed).
    let isProbeOnly: Bool
    /// Service types this status row covers (for Overview dots).
    let serviceTypes: [ServiceType]

    var isHealthy: Bool { level == .none }

    init(
        id: String,
        providerKey: String,
        displayName: String,
        level: ProviderStatusLevel,
        description: String?,
        pageURL: URL?,
        updatedAt: Date?,
        incidents: [ProviderStatusIncident],
        errorMessage: String?,
        isProbeOnly: Bool = false,
        serviceTypes: [ServiceType] = []
    ) {
        self.id = id
        self.providerKey = providerKey
        self.displayName = displayName
        self.level = level
        self.description = description
        self.pageURL = pageURL
        self.updatedAt = updatedAt
        self.incidents = incidents
        self.errorMessage = errorMessage
        self.isProbeOnly = isProbeOnly
        self.serviceTypes = serviceTypes
    }
}

// MARK: - Service

enum ProviderStatusService {
    enum Mode {
        /// Classic statuspage.io `api/v2/summary.json` polling.
        case statuspage
        /// Multi-probe + optional user OAuth token (xAI has no public status JSON).
        case xaiHealth
        /// Generic unauthenticated HTTP probe of one or more URLs.
        case healthProbes([URL])
    }

    struct Source {
        let key: String
        let displayName: String
        let statusPageBase: URL
        let mode: Mode
        /// Which Ultra `ServiceType`s this status covers.
        let serviceTypes: [ServiceType]
    }

    /// Optional credentials for probe-based sources (e.g. xAI OAuth).
    struct ProbeCredentials {
        /// Bearer tokens for authenticated health checks (never logged).
        var accessTokensBySourceKey: [String: [String]] = [:]
    }

    static let sources: [Source] = [
        Source(
            key: "openai",
            displayName: "OpenAI / Codex",
            statusPageBase: URL(string: "https://status.openai.com")!,
            mode: .statuspage,
            serviceTypes: [.codex]
        ),
        Source(
            key: "anthropic",
            displayName: "Anthropic / Claude",
            statusPageBase: URL(string: "https://status.anthropic.com")!,
            mode: .statuspage,
            serviceTypes: [.claude]
        ),
        Source(
            key: "github",
            displayName: "GitHub / Copilot",
            statusPageBase: URL(string: "https://www.githubstatus.com")!,
            mode: .statuspage,
            serviceTypes: [.copilot]
        ),
        Source(
            key: "cursor",
            displayName: "Cursor",
            statusPageBase: URL(string: "https://status.cursor.com")!,
            mode: .statuspage,
            serviceTypes: [.cursor]
        ),
        // status.x.ai is Cloudflare-gated; CodexBar also has no statuspage API.
        // We multi-probe api.x.ai and optionally use the user's Grok OAuth token.
        Source(
            key: "grok",
            displayName: "xAI / Grok",
            statusPageBase: URL(string: "https://status.x.ai")!,
            mode: .xaiHealth,
            serviceTypes: [.grok]
        ),
        Source(
            key: "google",
            displayName: "Google AI / Antigravity",
            statusPageBase: URL(string: "https://status.cloud.google.com")!,
            mode: .healthProbes([
                URL(string: "https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta")!,
                URL(string: "https://www.google.com/generate_204")!,
            ]),
            serviceTypes: [.gemini, .antigravity]
        ),
    ]

    /// Status source key for a service type, if any.
    static func sourceKey(for serviceType: ServiceType) -> String? {
        sources.first { $0.serviceTypes.contains(serviceType) }?.key
    }

    /// Only fetch status for providers the user actually has accounts for.
    static func fetch(
        forConnected serviceTypes: Set<ServiceType>,
        credentials: ProbeCredentials = ProbeCredentials()
    ) async -> [ProviderStatusSnapshot] {
        let activeSources = sources.filter { source in
            !Set(source.serviceTypes).isDisjoint(with: serviceTypes)
        }
        guard !activeSources.isEmpty else { return [] }

        return await withTaskGroup(of: ProviderStatusSnapshot.self) { group in
            for source in activeSources {
                group.addTask { await fetch(source: source, credentials: credentials) }
            }
            var results: [ProviderStatusSnapshot] = []
            for await item in group {
                results.append(item)
            }
            return results.sorted { lhs, rhs in
                if lhs.level.sortRank != rhs.level.sortRank {
                    return lhs.level.sortRank < rhs.level.sortRank
                }
                return lhs.displayName < rhs.displayName
            }
        }
    }

    /// @deprecated — prefer `fetch(forConnected:)`.
    static func fetchAll() async -> [ProviderStatusSnapshot] {
        await fetch(forConnected: Set(ServiceType.allCases))
    }

    static func fetch(source: Source, credentials: ProbeCredentials = ProbeCredentials()) async -> ProviderStatusSnapshot {
        switch source.mode {
        case .statuspage:
            if let summary = await fetchSummary(source: source) { return withServices(summary, source) }
            if let statusOnly = await fetchStatusOnly(source: source) { return withServices(statusOnly, source) }
            return ProviderStatusSnapshot(
                id: source.key,
                providerKey: source.key,
                displayName: source.displayName,
                level: .unknown,
                description: "Status feed unavailable",
                pageURL: source.statusPageBase,
                updatedAt: nil,
                incidents: [],
                errorMessage: "Could not load status feed",
                isProbeOnly: false,
                serviceTypes: source.serviceTypes
            )

        case .xaiHealth:
            return await fetchXAIHealth(
                source: source,
                tokens: credentials.accessTokensBySourceKey[source.key] ?? []
            )

        case .healthProbes(let urls):
            return await fetchGenericProbes(source: source, urls: urls)
        }
    }

    private static func withServices(_ snapshot: ProviderStatusSnapshot, _ source: Source) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            id: snapshot.id,
            providerKey: snapshot.providerKey,
            displayName: snapshot.displayName,
            level: snapshot.level,
            description: snapshot.description,
            pageURL: snapshot.pageURL,
            updatedAt: snapshot.updatedAt,
            incidents: snapshot.incidents,
            errorMessage: snapshot.errorMessage,
            isProbeOnly: snapshot.isProbeOnly,
            serviceTypes: source.serviceTypes
        )
    }

    // MARK: - xAI multi-probe

    /// How we get xAI status without status.x.ai (Cloudflare 403):
    /// 1. Authenticated `GET /v1/models` with the user's Grok OAuth token (best)
    /// 2. Unauthenticated `/v1/models` → 401 JSON means the API edge is up
    /// 3. Root `api.x.ai` welcome → secondary liveness
    private static func fetchXAIHealth(source: Source, tokens: [String]) async -> ProviderStatusSnapshot {
        // Prefer real account token when available.
        for token in tokens where !token.isEmpty {
            if let result = await probeXAIAuthenticated(token: token) {
                return ProviderStatusSnapshot(
                    id: source.key,
                    providerKey: source.key,
                    displayName: source.displayName,
                    level: result.level,
                    description: result.description,
                    pageURL: source.statusPageBase,
                    updatedAt: Date(),
                    incidents: result.incidents,
                    errorMessage: nil,
                    isProbeOnly: true,
                    serviceTypes: source.serviceTypes
                )
            }
        }

        // Unauthenticated multi-probe.
        let modelsProbe = await httpProbe(
            URL(string: "https://api.x.ai/v1/models")!,
            acceptJSON: true
        )
        let rootProbe = await httpProbe(
            URL(string: "https://api.x.ai/")!,
            acceptJSON: false
        )

        // Healthy signals
        let modelsHealthy = modelsProbe.map { code, body in
            // 401 unauthenticated JSON = edge up
            if code == 401 || code == 403 {
                return body.contains("unauthenticated")
                    || body.contains("no-credentials")
                    || body.contains("credentials")
                    || body.contains("\"error\"")
            }
            return (200...299).contains(code)
        } ?? false

        let rootHealthy = rootProbe.map { code, body in
            // 421 Misdirected / welcome text is normal for api.x.ai root
            if code == 421 { return true }
            if (200...299).contains(code) { return true }
            return body.localizedCaseInsensitiveContains("xai")
                || body.localizedCaseInsensitiveContains("documentation")
        } ?? false

        if modelsHealthy || rootHealthy {
            return ProviderStatusSnapshot(
                id: source.key,
                providerKey: source.key,
                displayName: source.displayName,
                level: .none,
                description: modelsHealthy
                    ? "API edge healthy (api.x.ai) · no public incident feed"
                    : "API root reachable · models probe inconclusive",
                pageURL: source.statusPageBase,
                updatedAt: Date(),
                incidents: [],
                errorMessage: nil,
                isProbeOnly: true,
                serviceTypes: source.serviceTypes
            )
        }

        if modelsProbe == nil && rootProbe == nil {
            return ProviderStatusSnapshot(
                id: source.key,
                providerKey: source.key,
                displayName: source.displayName,
                level: .major,
                description: "Could not reach api.x.ai",
                pageURL: source.statusPageBase,
                updatedAt: Date(),
                incidents: [
                    ProviderStatusIncident(
                        id: "xai-unreachable",
                        name: "xAI API unreachable",
                        status: "Connection failed",
                        impact: "major",
                        shortlink: source.statusPageBase,
                        updatedAt: Date()
                    )
                ],
                errorMessage: "Network error probing api.x.ai",
                isProbeOnly: true,
                serviceTypes: source.serviceTypes
            )
        }

        let code = modelsProbe?.0 ?? rootProbe?.0 ?? 0
        return ProviderStatusSnapshot(
            id: source.key,
            providerKey: source.key,
            displayName: source.displayName,
            level: (500...599).contains(code) ? .major : .unknown,
            description: "Unexpected API response (HTTP \(code)) — check status.x.ai in a browser",
            pageURL: source.statusPageBase,
            updatedAt: Date(),
            incidents: [],
            errorMessage: nil,
            isProbeOnly: true,
            serviceTypes: source.serviceTypes
        )
    }

    private static func probeXAIAuthenticated(token: String) async -> (level: ProviderStatusLevel, description: String, incidents: [ProviderStatusIncident])? {
        guard let url = URL(string: "https://api.x.ai/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeProxyUltra/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            if (200...299).contains(http.statusCode) {
                return (.none, "Authenticated API check OK · Grok account can reach api.x.ai", [])
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                // Token expired vs service down: edge still answered with JSON auth error.
                if body.contains("unauthenticated") || body.contains("invalid") || body.contains("expired")
                    || body.contains("credentials") || body.contains("error")
                {
                    return (
                        .none,
                        "API edge healthy · account token rejected (refresh/re-auth if Grok calls fail)",
                        []
                    )
                }
            }
            if (500...599).contains(http.statusCode) {
                return (
                    .major,
                    "Authenticated API returned HTTP \(http.statusCode)",
                    [
                        ProviderStatusIncident(
                            id: "xai-auth-5xx",
                            name: "xAI API error",
                            status: "HTTP \(http.statusCode)",
                            impact: "major",
                            shortlink: URL(string: "https://status.x.ai"),
                            updatedAt: Date()
                        )
                    ]
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Generic probes

    private static func fetchGenericProbes(source: Source, urls: [URL]) async -> ProviderStatusSnapshot {
        var anyHealthy = false
        var any5xx = false
        var anyReachable = false

        for url in urls {
            guard let (code, _) = await httpProbe(url, acceptJSON: false) else { continue }
            anyReachable = true
            if (200...399).contains(code) { anyHealthy = true }
            if (500...599).contains(code) { any5xx = true }
        }

        if anyHealthy {
            return ProviderStatusSnapshot(
                id: source.key,
                providerKey: source.key,
                displayName: source.displayName,
                level: .none,
                description: "Service endpoints reachable (health probe)",
                pageURL: source.statusPageBase,
                updatedAt: Date(),
                incidents: [],
                errorMessage: nil,
                isProbeOnly: true,
                serviceTypes: source.serviceTypes
            )
        }
        if any5xx {
            return ProviderStatusSnapshot(
                id: source.key,
                providerKey: source.key,
                displayName: source.displayName,
                level: .major,
                description: "Health probe saw server errors",
                pageURL: source.statusPageBase,
                updatedAt: Date(),
                incidents: [],
                errorMessage: nil,
                isProbeOnly: true,
                serviceTypes: source.serviceTypes
            )
        }
        return ProviderStatusSnapshot(
            id: source.key,
            providerKey: source.key,
            displayName: source.displayName,
            level: anyReachable ? .unknown : .major,
            description: anyReachable ? "Unexpected health-probe response" : "Could not reach service endpoints",
            pageURL: source.statusPageBase,
            updatedAt: Date(),
            incidents: [],
            errorMessage: nil,
            isProbeOnly: true,
            serviceTypes: source.serviceTypes
        )
    }

    private static func httpProbe(_ url: URL, acceptJSON: Bool) async -> (Int, String)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(acceptJSON ? "application/json" : "*/*", forHTTPHeaderField: "Accept")
        request.setValue("VibeProxyUltra/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            return (http.statusCode, body)
        } catch {
            return nil
        }
    }

    // MARK: - Statuspage

    private static func fetchSummary(source: Source) async -> ProviderStatusSnapshot? {
        let url = source.statusPageBase.appendingPathComponent("api/v2/summary.json")
        guard let json = await getJSON(url: url) else { return nil }

        let statusObj = json["status"] as? [String: Any]
        let indicator = (statusObj?["indicator"] as? String) ?? "unknown"
        let description = statusObj?["description"] as? String
        let page = json["page"] as? [String: Any]
        let updatedAt = parseISO8601(page?["updated_at"] as? String)

        let incidentsJSON = json["incidents"] as? [[String: Any]] ?? []
        let incidents: [ProviderStatusIncident] = incidentsJSON.prefix(8).compactMap { entry in
            let id = (entry["id"] as? String) ?? UUID().uuidString
            let name = (entry["name"] as? String) ?? "Incident"
            let status = (entry["status"] as? String) ?? "investigating"
            let impact = entry["impact"] as? String
            let shortlink = (entry["shortlink"] as? String).flatMap(URL.init(string:))
            let updated = parseISO8601(entry["updated_at"] as? String)
            return ProviderStatusIncident(
                id: id,
                name: name,
                status: status.replacingOccurrences(of: "_", with: " ").capitalized,
                impact: impact,
                shortlink: shortlink,
                updatedAt: updated
            )
        }

        let maintenances = json["scheduled_maintenances"] as? [[String: Any]] ?? []
        let activeMaintenances: [ProviderStatusIncident] = maintenances.compactMap { entry in
            let status = (entry["status"] as? String) ?? ""
            guard status == "in_progress" || status == "verifying" else { return nil }
            return ProviderStatusIncident(
                id: (entry["id"] as? String) ?? UUID().uuidString,
                name: (entry["name"] as? String) ?? "Maintenance",
                status: "Maintenance",
                impact: entry["impact"] as? String,
                shortlink: (entry["shortlink"] as? String).flatMap(URL.init(string:)),
                updatedAt: parseISO8601(entry["updated_at"] as? String)
            )
        }

        return ProviderStatusSnapshot(
            id: source.key,
            providerKey: source.key,
            displayName: source.displayName,
            level: ProviderStatusLevel(rawValue: indicator) ?? .unknown,
            description: description,
            pageURL: source.statusPageBase,
            updatedAt: updatedAt,
            incidents: incidents + activeMaintenances,
            errorMessage: nil,
            isProbeOnly: false,
            serviceTypes: source.serviceTypes
        )
    }

    private static func fetchStatusOnly(source: Source) async -> ProviderStatusSnapshot? {
        let url = source.statusPageBase.appendingPathComponent("api/v2/status.json")
        guard let json = await getJSON(url: url) else { return nil }
        let statusObj = json["status"] as? [String: Any]
        let indicator = (statusObj?["indicator"] as? String) ?? "unknown"
        let description = statusObj?["description"] as? String
        let page = json["page"] as? [String: Any]
        return ProviderStatusSnapshot(
            id: source.key,
            providerKey: source.key,
            displayName: source.displayName,
            level: ProviderStatusLevel(rawValue: indicator) ?? .unknown,
            description: description,
            pageURL: source.statusPageBase,
            updatedAt: parseISO8601(page?["updated_at"] as? String),
            incidents: [],
            errorMessage: nil,
            isProbeOnly: false,
            serviceTypes: source.serviceTypes
        )
    }

    private static func getJSON(url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) VibeProxyUltra/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func parseISO8601(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
