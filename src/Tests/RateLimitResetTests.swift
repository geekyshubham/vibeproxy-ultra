import XCTest
@testable import CLIProxyMenuBar

final class RateLimitResetTests: XCTestCase {
    // MARK: - Capability gating

    func testResetBankSupportedProviders() {
        XCTAssertTrue(RateLimitResetService.supports(.codex))
        XCTAssertTrue(RateLimitResetService.supports(.grok))
        XCTAssertFalse(RateLimitResetService.supports(.claude))
        XCTAssertFalse(RateLimitResetService.supports(.gemini))
        XCTAssertFalse(RateLimitResetService.supports(.copilot))
        XCTAssertFalse(RateLimitResetService.supports(.kiro))
        XCTAssertFalse(RateLimitResetService.supports(.zai))
    }

    // MARK: - Bank model

    func testRateLimitResetBankSummaryLine() {
        let future = Date().addingTimeInterval(86_400 * 14)
        let single = RateLimitResetBank(availableCount: 1, nextExpiresAt: future)
        XCTAssertTrue(single.summaryLine.hasPrefix("1 rate-limit reset left"))
        XCTAssertTrue(single.summaryLine.contains("next expires"))

        let many = RateLimitResetBank(availableCount: 3)
        XCTAssertTrue(many.summaryLine.contains("3 rate-limit resets left"))

        let empty = RateLimitResetBank(availableCount: 0)
        XCTAssertEqual(empty.summaryLine, "No rate-limit resets left")
        XCTAssertFalse(empty.summaryLine.contains("next expires"))
    }

    // MARK: - Codex credits parsing

    func testParseCodexCreditsFiltersUnavailableAndExpired() {
        let json: [String: Any] = [
            "credits": [
                [
                    "id": "RateLimitResetCredit_abc",
                    "status": "available",
                    "title": "Full reset (Weekly + 5 hr)",
                    "expires_at": Self.iso(Date().addingTimeInterval(86_400)),
                ],
                [
                    "id": "RateLimitResetCredit_old",
                    "status": "available",
                    "expires_at": Self.iso(Date().addingTimeInterval(-3_600)),
                ],
                [
                    "id": "RateLimitResetCredit_spent",
                    "status": "redeemed",
                    "expires_at": Self.iso(Date().addingTimeInterval(86_400)),
                ],
            ]
        ]
        let credits = NativeUsageFetcher.parseCodexCredits(json: json)
        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits[0].id, "RateLimitResetCredit_abc")
        XCTAssertEqual(credits[0].title, "Full reset (Weekly + 5 hr)")
        XCTAssertNotNil(credits[0].expiresAt)
    }

    // MARK: - Grok gRPC-web parsing

    func testParseGrokRemainingResetsReadsTokensAndFiltersExpired() throws {
        let now = Date()
        let future = UInt64(now.addingTimeInterval(86_400 * 20).timeIntervalSince1970)
        let past = UInt64(now.addingTimeInterval(-86_400).timeIntervalSince1970)

        var live = Data()
        live.append(contentsOf: [0x52]) // field 10 (token_id), wire type 2
        live.appendProtoVarint("ConsumerResetToken_live".utf8.count)
        live.append(contentsOf: "ConsumerResetToken_live".utf8)
        live.append(contentsOf: [0xF2, 0x01]) // field 30 (validity_end), wire type 2
        live.appendProtoVarint(timestampMessage(future).count)
        live.append(timestampMessage(future))

        var expired = Data()
        expired.append(contentsOf: [0x52])
        expired.appendProtoVarint("tok_expired".utf8.count)
        expired.append(contentsOf: "tok_expired".utf8)
        expired.append(contentsOf: [0xF2, 0x01])
        expired.appendProtoVarint(timestampMessage(past).count)
        expired.append(timestampMessage(past))

        var response = Data()
        for token in [live, expired] {
            response.append(contentsOf: [0x52]) // repeated field 10 (tokens)
            response.appendProtoVarint(token.count)
            response.append(token)
        }

        let data = Self.grpcWebDataFrame(response)
        let tokens = RateLimitResetService.parseGrokRemainingResets(data, now: now)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.tokenID, "ConsumerResetToken_live")
        XCTAssertNotNil(tokens.first?.validUntil)
        XCTAssertTrue(abs((tokens.first!.validUntil!.timeIntervalSince(now)) - 86_400 * 20) < 5)
    }

    func testParseGrokRemainingResetsHandlesEmptyResponse() {
        let empty = Data([0x00, 0x00, 0x00, 0x00, 0x00]) // data frame with empty message
        let tokens = RateLimitResetService.parseGrokRemainingResets(empty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testGrokRedeemRequestBodyShape() {
        let body = RateLimitResetService.grokRedeemRequestBody(tokenID: "abc")
        // Frame header: flag 0 + big-endian payload length
        XCTAssertEqual(body.prefix(1), Data([0x00]))
        let expectedLength = Int(body[1]) << 24 | Int(body[2]) << 16 | Int(body[3]) << 8 | Int(body[4])
        let payload = body.dropFirst(5)
        XCTAssertEqual(payload.count, expectedLength)
        // ConsumerRedeemResetReq{token_id = 10}: tag 0x52, length, utf8 bytes
        XCTAssertEqual(payload.first, 0x52)
        XCTAssertEqual(Int(payload.dropFirst().first!), "abc".utf8.count)
        XCTAssertEqual(Data(payload.dropFirst(2)), Data("abc".utf8))
    }

    func testGrokGRPCFailureDetectsTrailerStatus() {
        let trailer = Self.grpcWebTrailerFrame(Data("grpc-status:16\r\ngrpc-message:no-credentials".utf8))
        let failure = RateLimitResetService.grokGRPCFailure(trailer)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure!.contains("grpc 16"))

        let ok = Self.grpcWebTrailerFrame(Data("grpc-status:0\r\n".utf8))
        XCTAssertNil(RateLimitResetService.grokGRPCFailure(ok))
    }

    // MARK: - Helpers

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// google.protobuf.Timestamp{seconds = 1}.
    private static func timestampMessage(_ seconds: UInt64) -> Data {
        var out = Data([0x08])
        var value = seconds
        while true {
            if value < 0x80 {
                out.append(UInt8(value))
                break
            }
            out.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        return out
    }

    private static func grpcWebDataFrame(_ payload: Data) -> Data {
        var out = Data([0x00])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    private static func grpcWebTrailerFrame(_ payload: Data) -> Data {
        var out = Data([0x80])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}
