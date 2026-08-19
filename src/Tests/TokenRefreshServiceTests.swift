import XCTest
@testable import CLIProxyMenuBar

final class TokenRefreshServiceTests: XCTestCase {
    func testGroupedByRefreshTokenCollapsesDuplicates() {
        let shared = "rt.1.shared"
        let a = URL(fileURLWithPath: "/tmp/codex-a.json")
        let b = URL(fileURLWithPath: "/tmp/codex-seat.json")
        let c = URL(fileURLWithPath: "/tmp/codex-other.json")
        let groups = TokenRefreshService.groupedByRefreshToken([
            .init(file: a, payload: [:], type: "codex", refresh: shared),
            .init(file: b, payload: [:], type: "codex", refresh: shared),
            .init(file: c, payload: [:], type: "codex", refresh: "rt.1.other"),
        ])
        XCTAssertEqual(groups.count, 2)
        let sizes = Set(groups.map(\.count))
        XCTAssertEqual(sizes, [1, 2])
        let sharedGroup = groups.first { $0.count == 2 }!
        XCTAssertEqual(Set(sharedGroup.map(\.file)), [a, b])
    }

    func testShouldRefreshWhenAccessTokenIsSevenDaysOld() {
        let iat = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let exp = Date().addingTimeInterval(2 * 24 * 60 * 60)
        let payload: [String: Any] = [
            "refresh_token": "rt.1.alive",
            "access_token": Self.jwt(iat: iat, exp: exp),
        ]
        XCTAssertTrue(TokenRefreshService.shouldRefresh(payload: payload))
    }

    func testShouldNotRefreshFreshAccessToken() {
        let iat = Date().addingTimeInterval(-2 * 60 * 60)
        let exp = Date().addingTimeInterval(9 * 24 * 60 * 60)
        let payload: [String: Any] = [
            "refresh_token": "rt.1.alive",
            "access_token": Self.jwt(iat: iat, exp: exp),
        ]
        XCTAssertFalse(TokenRefreshService.shouldRefresh(payload: payload))
    }

    func testPropagateRotatedTokensUpdatesEveryFileSharingTheOldRefreshToken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, refresh: String, email: String) throws {
            let rec: [String: Any] = [
                "type": "codex",
                "email": email,
                "refresh_token": refresh,
                "access_token": "old-at",
            ]
            try JSONSerialization.data(withJSONObject: rec).write(to: dir.appendingPathComponent(name))
        }
        try write("codex-a.json", refresh: "rt-old", email: "a@x.com")
        try write("codex-seat.json", refresh: "rt-old", email: "a@x.com")
        try write("codex-other.json", refresh: "rt-other", email: "b@x.com")

        let updated: [String: Any] = [
            "type": "codex",
            "refresh_token": "rt-new",
            "access_token": "new-at",
            "last_refresh": "now",
        ]
        let n = TokenRefreshService.propagateRotatedTokens(
            oldRefresh: "rt-old",
            updated: updated,
            authDirectory: dir
        )
        XCTAssertEqual(n, 2)

        func read(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let a = try read("codex-a.json")
        let seat = try read("codex-seat.json")
        let other = try read("codex-other.json")
        XCTAssertEqual(a["refresh_token"] as? String, "rt-new")
        XCTAssertEqual(a["access_token"] as? String, "new-at")
        XCTAssertEqual(a["email"] as? String, "a@x.com")
        XCTAssertEqual(seat["refresh_token"] as? String, "rt-new")
        XCTAssertEqual(other["refresh_token"] as? String, "rt-other")
        XCTAssertEqual(other["access_token"] as? String, "old-at")
    }

    func testCopyTokenFieldsIncludesCamelCaseAliases() {
        let original: [String: Any] = [
            "type": "cursor",
            "email": "a@x.com",
            "accessToken": "old",
        ]
        let updated: [String: Any] = [
            "access_token": "new-at",
            "accessToken": "new-at",
            "refresh_token": "new-rt",
            "refreshToken": "new-rt",
        ]
        let merged = TokenRefreshService.copyTokenFields(from: updated, onto: original)
        XCTAssertEqual(merged["access_token"] as? String, "new-at")
        XCTAssertEqual(merged["accessToken"] as? String, "new-at")
        XCTAssertEqual(merged["refreshToken"] as? String, "new-rt")
        XCTAssertEqual(merged["email"] as? String, "a@x.com")
    }

    private static func jwt(iat: Date, exp: Date) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLToken()
        let payloadObj: [String: Any] = [
            "iat": Int(iat.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
        ]
        let payload = try! JSONSerialization.data(withJSONObject: payloadObj).base64URLToken()
        return "\(header).\(payload).sig"
    }
}

private extension Data {
    func base64URLToken() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
