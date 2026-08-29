import Foundation

/// Banked manual rate-limit resets across providers — the ability to *see* the
/// inventory and *redeem* one on demand (clears current limits immediately,
/// same idea as QuotaWakeService but consuming a real reset instead of waking
/// a rolling window).
///
/// Today: ChatGPT/Codex (`wham/rate-limit-reset-credits`) and SuperGrok
/// (`prod_mc_billing.ConsumerUiSvc/GetRemainingResets|RedeemReset`). New
/// providers only need a listing + redeem implementation plus `supports(_:)`.
enum RateLimitResetService {
    enum ResetResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    /// Providers whose reset banks VibeProxy can read today.
    static func supports(_ type: ServiceType) -> Bool {
        switch type {
        case .codex, .grok:
            return true
        default:
            return false
        }
    }

    /// Redeems (applies) one reset for this account right now.
    static func redeem(account: AuthAccount) async -> ResetResult {
        guard supports(account.type) else {
            return .failure(message: "\(account.type.displayName) does not support rate-limit resets")
        }

        // Always refresh first so direct-auth calls use a live access token.
        _ = await TokenRefreshService.refreshAccountFile(account.filePath)

        switch account.type {
        case .codex:
            return await redeemCodex(account: account)
        case .grok:
            return await redeemGrok(account: account)
        default:
            return .failure(message: "\(account.type.displayName) does not support rate-limit resets")
        }
    }

    // MARK: - ChatGPT / Codex

    private static func redeemCodex(account: AuthAccount) async -> ResetResult {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
              let accessToken = stringValue(payload, keys: ["access_token"])
        else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }
        let jwtAccountID = chatgptAccountIDFromJWT(accessToken)
            ?? chatgptAccountIDFromJWT(stringValue(payload, keys: ["id_token"]))
        let accountID = stringValue(payload, keys: ["account_id"]) ?? jwtAccountID

        let credits = await NativeUsageFetcher.fetchCodexAvailableResets(
            accessToken: accessToken,
            chatGPTAccountID: accountID
        )
        guard let credits else {
            return .failure(message: "Could not reach ChatGPT resets — check connection and retry (nothing was consumed).")
        }
        guard let credit = preferredCodexCredit(credits) else {
            return .failure(message: "No usable ChatGPT rate-limit reset found — nothing to apply.")
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume") else {
            return .failure(message: "Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        let redeemRequestID = UUID().uuidString.lowercased()
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "credit_id": credit.id,
            "redeem_request_id": redeemRequestID,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid reset response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(
                    message: "ChatGPT session expired while applying the reset — re-authenticate and retry (the reset is still banked)."
                )
            }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: data.prefix(200), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                return .failure(message: "Could not apply ChatGPT reset (HTTP \(http.statusCode)). \(snippet)")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["code"] as? String
            let windowsReset = json?["windows_reset"] as? Int ?? 0
            if let code, code.lowercased() != "reset", code.lowercased() != "ok" {
                return .failure(message: "ChatGPT did not apply the reset (\(code)). Try again shortly.")
            }
            var line = "Applied ChatGPT rate-limit reset"
            if windowsReset > 0 { line += " · \(windowsReset) limit window\(windowsReset == 1 ? "" : "s") cleared" }
            return .success(message: line + ".")
        } catch {
            return .failure(message: "Reset request failed: \(error.localizedDescription)")
        }
    }

    /// Prefer the soonest-expiring credit so nothing is wasted to expiry.
    private static func preferredCodexCredit(_ credits: [NativeUsageFetcher.CodexResetCredit]) -> NativeUsageFetcher.CodexResetCredit? {
        credits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }.first
    }

    // MARK: - SuperGrok

    /// gRPC-web endpoint for the consumer billing UI (Settings → Usage page).
    private static let grokEndpointBase = "https://grok.com/prod_mc_billing.ConsumerUiSvc"

    struct GrokResetToken: Equatable {
        let tokenID: String
        let validFrom: Date?
        let validUntil: Date?

        func isCurrentlyValid(now: Date = Date()) -> Bool {
            if let validFrom, validFrom > now { return false }
            if let validUntil, validUntil <= now { return false }
            return !tokenID.isEmpty
        }
    }

    enum GrokResetsOutcome: Equatable {
        case success([GrokResetToken])
        case failure(String)
    }

    /// Lists remaining SuperGrok usage resets (one-time "clear your weekly pool").
    static func fetchGrokRemainingResets(accessToken: String) async -> GrokResetsOutcome {
        guard let url = URL(string: "\(grokEndpointBase)/GetRemainingResets") else {
            return .failure("Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = grpcWebFrame(Data())
        applyGrokHeaders(to: &request, accessToken: accessToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure("Grok resets returned HTTP \(http.statusCode)")
            }
            if let grpcError = grokGRPCFailure(data) {
                return .failure(grpcError)
            }
            return .success(parseGrokRemainingResets(data))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Bank for snapshots; nil when the endpoint is unavailable or empty.
    static func fetchGrokBank(accessToken: String) async -> RateLimitResetBank? {
        switch await fetchGrokRemainingResets(accessToken: accessToken) {
        case .success(let tokens):
            let valid = tokens.filter { $0.isCurrentlyValid() }
            let next = valid.compactMap(\.validUntil).sorted().first
            return RateLimitResetBank(
                availableCount: valid.count,
                nextExpiresAt: next,
                sampleTitle: valid.isEmpty ? nil : "Clears your full weekly pool once",
                canRedeem: true
            )
        case .failure:
            return nil
        }
    }

    private static func redeemGrok(account: AuthAccount) async -> ResetResult {
        let label = account.baseDisplayName
        for candidate in await grokTokenCandidates(for: account) {
            switch await fetchGrokRemainingResets(accessToken: candidate) {
            case .success(let tokens):
                let valid = tokens.filter { $0.isCurrentlyValid() }
                guard let token = valid.sorted(by: { ($0.validUntil ?? .distantFuture) < ($1.validUntil ?? .distantFuture) }).first else {
                    return .failure(message: "No SuperGrok usage resets left for \(label).")
                }
                return await submitGrokRedeem(tokenID: token.tokenID, accessToken: candidate, label: label)
            case .failure(let message):
                if isGrokAuthFailure(message) { continue }
                return .failure(message: friendlyGrokResetError(message))
            }
        }
        return .failure(
            message: "Could not reach Grok resets for \(label) — run `grok login` or reconnect Grok in Settings."
        )
    }

    private static func submitGrokRedeem(tokenID: String, accessToken: String, label: String) async -> ResetResult {
        guard let url = URL(string: "\(grokEndpointBase)/RedeemReset") else {
            return .failure(message: "Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = grokRedeemRequestBody(tokenID: tokenID)
        applyGrokHeaders(to: &request, accessToken: accessToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid reset response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(message: "Grok rejected the reset request — run `grok login` and retry (the reset is still banked).")
            }
            guard (200...299).contains(http.statusCode),
                  grokGRPCFailure(data) == nil
            else {
                let grpcError = grokGRPCFailure(data)
                return .failure(message: friendlyGrokResetError(grpcError ?? "Grok reset returned HTTP \(http.statusCode)"))
            }
            return .success(message: "Redeemed SuperGrok usage reset for \(label) — your weekly pool was cleared.")
        } catch {
            return .failure(message: friendlyGrokResetError(error.localizedDescription))
        }
    }

    /// Token order mirrors fetchGrokUsage: live ~/.grok CLI token first, then the auth file.
    private static func grokTokenCandidates(for account: AuthAccount) async -> [String] {
        var candidates: [String] = []
        func append(_ token: String?) {
            guard let token, !token.isEmpty, !candidates.contains(token) else { return }
            candidates.append(token)
        }

        let local = NativeUsageFetcher.readGrokAppPayload()
        let filePayload = NativeUsageFetcher.readAuthPayload(at: account.filePath) ?? [:]
        let ordered = NativeUsageFetcher.grokBillingTokenCandidates(
            accountPayload: filePayload,
            localGrok: local
        )
        for candidate in ordered {
            append(candidate.token)
        }

        return candidates
    }

    // MARK: - gRPC-web plumbing

    private static func applyGrokHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
    }

    /// grpc-web frame: 1 flag byte (0 = data) + 4 big-endian length bytes + payload.
    static func grpcWebFrame(_ payload: Data) -> Data {
        var out = Data([0x00])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// ConsumerRedeemResetReq{token_id = 10} wrapped in a grpc-web frame.
    static func grokRedeemRequestBody(tokenID: String) -> Data {
        var message = Data([0x52]) // field 10, wire type 2
        message.appendProtoVarint(tokenID.utf8.count)
        message.append(contentsOf: tokenID.utf8)
        return grpcWebFrame(message)
    }

    /// Parses GetRemainingResets responses (repeated ConsumerResetToken = field 10).
    static func parseGrokRemainingResets(_ data: Data, now: Date = Date()) -> [GrokResetToken] {
        let frames = NativeUsageFetcher.grokGRPCWebDataFrames(from: data)
        guard !frames.isEmpty || grokLooksLikeProtobuf(data) else { return [] }
        let payloads = frames.isEmpty ? [data] : frames

        var tokens: [GrokResetToken] = []
        for payload in payloads {
            var reader = ProtoReader(payload)
            while let field = reader.next() {
                guard field.fieldNumber == 10, case .lengthDelimited(let message)? = field.value else { continue }
                tokens.append(parseGrokResetToken(message))
            }
        }
        return tokens.filter { $0.isCurrentlyValid(now: now) }
    }

    private static func parseGrokResetToken(_ message: Data) -> GrokResetToken {
        var tokenID = ""
        var validFrom: Date?
        var validUntil: Date?
        var reader = ProtoReader(message)
        while let field = reader.next() {
            switch (field.fieldNumber, field.value) {
            case (10, .lengthDelimited(let data)):
                tokenID = String(data: data, encoding: .utf8) ?? ""
            case (20, .lengthDelimited(let data)):
                validFrom = Self.parseTimestamp(data)
            case (30, .lengthDelimited(let data)):
                validUntil = Self.parseTimestamp(data)
            default:
                break
            }
        }
        return GrokResetToken(tokenID: tokenID, validFrom: validFrom, validUntil: validUntil)
    }

    /// google.protobuf.Timestamp{seconds = 1, nanos = 2}.
    private static func parseTimestamp(_ message: Data) -> Date? {
        var reader = ProtoReader(message)
        while let field = reader.next() {
            if field.fieldNumber == 1, case .varint(let seconds)? = field.value,
               seconds > 1_500_000_000, seconds < 4_000_000_000
            {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
        }
        return nil
    }

    /// Non-nil when the trailer reports a gRPC failure.
    static func grokGRPCFailure(_ data: Data) -> String? {
        let trailers = NativeUsageFetcher.grokGRPCWebTrailerFields(from: data)
        guard let rawStatus = trailers["grpc-status"], let status = Int(rawStatus), status != 0 else {
            return nil
        }
        let message = (trailers["grpc-message"] ?? "Grok reset request failed")
            .removingPercentEncoding?
            .replacingOccurrences(of: "+", with: " ")
            ?? "Grok reset request failed"
        return "grpc \(status): \(message)"
    }

    private static func isGrokAuthFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unauthenticated") || lower.contains("grpc 16") || lower.contains("grpc 7")
    }

    private static func friendlyGrokResetError(_ raw: String) -> String {
        if isGrokAuthFailure(raw) {
            return "Grok rejected the reset request — run `grok login` (the reset is still banked)."
        }
        return "Could not apply Grok reset: \(raw)"
    }

    private static func grokLooksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    // MARK: - Minimal protobuf reader

    struct ProtoField {
        enum Value {
            case varint(UInt64)
            case fixed64(Data)
            case lengthDelimited(Data)
            case fixed32(Data)
        }

        let fieldNumber: UInt64
        let value: Value?
    }

    struct ProtoReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func next() -> ProtoField? {
            while index < bytes.count {
                let fieldStart = index
                guard let key = readVarint() else {
                    index = fieldStart + 1
                    continue
                }
                let fieldNumber = key >> 3
                let wireType = key & 0x07
                guard fieldNumber > 0 else {
                    index = fieldStart + 1
                    continue
                }
                switch wireType {
                case 0:
                    if let value = readVarint() {
                        return ProtoField(fieldNumber: fieldNumber, value: .varint(value))
                    }
                    index = fieldStart + 1
                case 1:
                    guard index + 8 <= bytes.count else { return nil }
                    let data = Data(bytes[index..<index + 8])
                    index += 8
                    return ProtoField(fieldNumber: fieldNumber, value: .fixed64(data))
                case 2:
                    guard let length = readVarint(), length <= UInt64(bytes.count - index) else {
                        index = fieldStart + 1
                        continue
                    }
                    let data = Data(bytes[index..<index + Int(length)])
                    index += Int(length)
                    return ProtoField(fieldNumber: fieldNumber, value: .lengthDelimited(data))
                case 5:
                    guard index + 4 <= bytes.count else { return nil }
                    let data = Data(bytes[index..<index + 4])
                    index += 4
                    return ProtoField(fieldNumber: fieldNumber, value: .fixed32(data))
                default:
                    index = fieldStart + 1
                }
            }
            return nil
        }

        private mutating func readVarint() -> UInt64? {
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

    // MARK: - Shared helpers

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
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
}

extension Data {
    mutating func appendProtoVarint(_ value: Int) {
        var v = UInt64(value)
        while true {
            if v < 0x80 {
                append(UInt8(v))
                return
            }
            append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
    }
}
