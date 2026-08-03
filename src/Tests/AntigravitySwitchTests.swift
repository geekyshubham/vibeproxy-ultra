import XCTest
@testable import CLIProxyMenuBar

/// Antigravity IDE oauthToken encode/decode (Cockpit-compatible wire format).
final class AntigravitySwitchTests: XCTestCase {
    func testOAuthTokenRoundTripPreservesAccessToken() throws {
        let access = "ya29.a0ARGnu0_test_access_token_value"
        let refresh = "1//0g_test_refresh_token_value"
        let expiry = 1_785_677_611

        let value = try NativeSessionManager.buildAntigravityOAuthTokenValue(
            accessToken: access,
            refreshToken: refresh,
            expirySeconds: expiry,
            existingValue: nil
        )

        XCTAssertEqual(
            NativeSessionManager.parseAntigravityAccessToken(fromOAuthTokenValue: value),
            access
        )
        // Outer payload is standard base64.
        XCTAssertNotNil(Data(base64Encoded: value))
    }

    func testOAuthTokenPreservesExtraSentinelsFromExistingValue() throws {
        let first = try NativeSessionManager.buildAntigravityOAuthTokenValue(
            accessToken: "ya29.first",
            refreshToken: "1//first",
            expirySeconds: 1_700_000_000,
            existingValue: nil
        )
        // Simulate another sentinel already present by building again with a new token;
        // auth state + oauth info should still parse cleanly.
        let second = try NativeSessionManager.buildAntigravityOAuthTokenValue(
            accessToken: "ya29.second",
            refreshToken: "1//second",
            expirySeconds: 1_800_000_000,
            existingValue: first
        )
        XCTAssertEqual(
            NativeSessionManager.parseAntigravityAccessToken(fromOAuthTokenValue: second),
            "ya29.second"
        )
    }

    func testExtractEmailFromUserStatusNestedBase64() {
        // Minimal outer base64 wrapping a nested base64 blob that decodes to
        // protobuf field3 name + field4 email (same shape as real userStatus).
        let nameEmailProto = Data([
            0x1A, 0x0C,
        ]) + Data("Aiden Pierce".utf8) + Data([
            0x22, 0x11,
        ]) + Data("d3ds3c3@gmail.com".utf8)
        let nestedB64 = nameEmailProto.base64EncodedString()
        // Outer is just the nested b64 as ascii text, then base64-wrapped like the IDE store.
        let outer = Data(nestedB64.utf8).base64EncodedString()

        let email = NativeSessionManager.extractEmailFromAntigravityUserStatus(outer)
        XCTAssertEqual(email, "d3ds3c3@gmail.com")
    }

    func testSupportsSwitchingIncludesAntigravity() {
        XCTAssertTrue(NativeSessionManager.switchableProviderIDs.contains("antigravity"))
        XCTAssertTrue(NativeSessionManager.shared.supportsSwitching(.antigravity))
    }
}
