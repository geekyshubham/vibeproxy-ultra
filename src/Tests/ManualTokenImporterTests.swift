import XCTest
@testable import CLIProxyMenuBar

final class ManualTokenImporterTests: XCTestCase {
    func testParsesCodexAuthJSONNestedTokens() throws {
        let json = """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(Self.jwt(email: "user@example.com"))",
            "access_token": "\(Self.jwt(email: "user@example.com", accountID: "acct-1"))",
            "refresh_token": "rt.1.example",
            "account_id": "acct-1"
          },
          "last_refresh": "2026-06-08T09:03:29Z"
        }
        """
        let parsed = try unwrap(ManualTokenImporter.parse(json, preferredType: .codex))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, .codex)
        XCTAssertEqual(parsed[0].displayName, "user@example.com")
        XCTAssertEqual(parsed[0].record["refresh_token"] as? String, "rt.1.example")
        XCTAssertEqual(parsed[0].record["account_id"] as? String, "acct-1")
        XCTAssertEqual(parsed[0].record["type"] as? String, "codex")
        XCTAssertTrue(parsed[0].filename.hasPrefix("codex-"))
    }

    func testParsesCursorJSON() throws {
        let json = """
        {
          "email": "dev@example.com",
          "accessToken": "cursor-access",
          "refreshToken": "cursor-refresh",
          "membershipType": "pro"
        }
        """
        let parsed = try unwrap(ManualTokenImporter.parse(json, preferredType: .cursor))
        XCTAssertEqual(parsed[0].type, .cursor)
        XCTAssertEqual(parsed[0].displayName, "dev@example.com")
        XCTAssertEqual(parsed[0].record["refresh_token"] as? String, "cursor-refresh")
        XCTAssertEqual(parsed[0].record["plan_type"] as? String, "pro")
    }

    func testParsesClaudeCredentialsWrapper() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "claude-at",
            "refreshToken": "claude-rt",
            "email": "claude@example.com"
          }
        }
        """
        let parsed = try unwrap(ManualTokenImporter.parse(json, preferredType: .claude))
        XCTAssertEqual(parsed[0].type, .claude)
        XCTAssertEqual(parsed[0].record["access_token"] as? String, "claude-at")
        XCTAssertEqual(parsed[0].record["refresh_token"] as? String, "claude-rt")
    }

    func testDetectsCodexFromNestedTokensEvenIfPreferredIsCursor() {
        let raw: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "at",
                "refresh_token": "rt",
            ],
        ]
        XCTAssertEqual(ManualTokenImporter.detectType(raw, preferredType: .cursor), .codex)
    }

    func testWritesPastedCodexJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {
          "type": "codex",
          "email": "paste@example.com",
          "access_token": "at",
          "refresh_token": "rt"
        }
        """
        let result = ManualTokenImporter.importPasted(json, preferredType: .codex, authDirectory: dir)
        guard case .success = result else {
            return XCTFail("import failed: \(result)")
        }
        let file = dir.appendingPathComponent("codex-paste@example.com.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let payload = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(payload["refresh_token"] as? String, "rt")
    }

    private func unwrap(_ result: Result<[ManualTokenImporter.ParsedAccount], ManualTokenImporter.ImportError>) throws -> [ManualTokenImporter.ParsedAccount] {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func jwt(email: String, accountID: String? = nil) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLToken()
        var payload: [String: Any] = ["email": email]
        if let accountID {
            payload["https://api.openai.com/auth"] = ["chatgpt_account_id": accountID]
            payload["https://api.openai.com/profile"] = ["email": email]
        }
        let body = try! JSONSerialization.data(withJSONObject: payload).base64URLToken()
        return "\(header).\(body).sig"
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
