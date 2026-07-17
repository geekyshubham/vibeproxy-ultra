import XCTest
@testable import CLIProxyMenuBar

/// Edge-case coverage for multi-seat Codex (Go ↔ Team), matching Cockpit's account_id model.
final class CodexSeatSwitchTests: XCTestCase {
    private let goAccountID = "b8490ad0-efd0-4413-a1f3-38e7e1dcb977"
    private let teamAccountID = "f7268a18-b7e1-42d3-b4b1-286f67b74b4d"

    // MARK: - JWT helpers under test

    func testAccessTokenExpiryPastAndFuture() {
        let past = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
            exp: Date().addingTimeInterval(-3600)
        )
        let future = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": teamAccountID, "chatgpt_plan_type": "team"],
            exp: Date().addingTimeInterval(3600)
        )
        XCTAssertTrue(CodexWorkspaceCredentials.Payload(
            accessToken: past,
            refreshToken: "rt",
            idToken: nil,
            accountID: goAccountID,
            email: "a@b.c",
            planType: "go",
            source: "test"
        ).isAccessExpired)
        XCTAssertFalse(CodexWorkspaceCredentials.Payload(
            accessToken: future,
            refreshToken: "rt",
            idToken: nil,
            accountID: teamAccountID,
            email: "a@b.c",
            planType: "team",
            source: "test"
        ).isAccessExpired)
    }

    func testPickBestPrefersNonExpiredJWTMatch() {
        let expiredGo = CodexWorkspaceCredentials.Payload(
            accessToken: Self.makeUnsignedJWT(
                auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
                exp: Date().addingTimeInterval(-7200)
            ),
            refreshToken: "rt-dead",
            idToken: nil,
            accountID: goAccountID,
            email: "user@example.com",
            planType: "go",
            source: "cockpit:go.json"
        )
        let liveTeam = CodexWorkspaceCredentials.Payload(
            accessToken: Self.makeUnsignedJWT(
                auth: ["chatgpt_account_id": teamAccountID, "chatgpt_plan_type": "team"],
                exp: Date().addingTimeInterval(7200)
            ),
            refreshToken: "rt-live",
            idToken: nil,
            accountID: teamAccountID,
            email: "user@example.com",
            planType: "team",
            source: "seed"
        )
        // Same seat: live wins over expired.
        let liveGo = CodexWorkspaceCredentials.Payload(
            accessToken: Self.makeUnsignedJWT(
                auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
                exp: Date().addingTimeInterval(7200)
            ),
            refreshToken: "rt-live-go",
            idToken: nil,
            accountID: goAccountID,
            email: "user@example.com",
            planType: "go",
            source: "cli-proxy:codex-seat.json"
        )
        let bestGo = CodexWorkspaceCredentials.pickBest(among: [expiredGo, liveGo])
        XCTAssertEqual(bestGo?.accessToken, liveGo.accessToken)

        // Different seats are independent — pickBest among mixed still returns highest score.
        let best = CodexWorkspaceCredentials.pickBest(among: [expiredGo, liveTeam])
        XCTAssertEqual(best?.accountID, teamAccountID)
    }

    func testResolveFailsClosedForForeignSeatWithoutLineage() {
        let goJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
            exp: Date().addingTimeInterval(3600)
        )
        let seed: [String: Any] = [
            "access_token": goJWT,
            "account_id": goAccountID,
            "email": "spec-only-unique@example.com",
            "type": "codex",
        ]
        let resolved = CodexWorkspaceCredentials.resolve(
            preferredAccountID: teamAccountID,
            seed: seed,
            email: "spec-only-unique@example.com"
        )
        // No team lineage for this unique email → nil (must not return Go JWT).
        if let resolved {
            XCTAssertEqual(resolved.accountID.lowercased(), teamAccountID.lowercased())
            XCTAssertNotEqual(
                CodexWorkspaceCredentials.chatgptAccountID(from: resolved.accessToken)?.lowercased(),
                goAccountID.lowercased()
            )
        } else {
            XCTAssertNil(resolved)
        }
    }

    func testResolveOwnSeatFromSeed() {
        let goJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
            exp: Date().addingTimeInterval(3600)
        )
        let seed: [String: Any] = [
            "access_token": goJWT,
            "account_id": goAccountID,
            "email": "user@example.com",
            "type": "codex",
        ]
        let resolved = CodexWorkspaceCredentials.resolve(
            preferredAccountID: goAccountID,
            seed: seed,
            email: "user@example.com"
        )
        XCTAssertEqual(resolved?.accountID.lowercased(), goAccountID.lowercased())
        XCTAssertEqual(CodexWorkspaceCredentials.chatgptPlanType(from: resolved?.accessToken), "go")
    }

    func testSeatFilenameIsStablePerAccountID() {
        let a = CodexWorkspaceCredentials.seatFilename(accountID: teamAccountID)
        let b = CodexWorkspaceCredentials.seatFilename(accountID: teamAccountID.uppercased())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "codex-seat-\(teamAccountID).json")
        XCTAssertNotEqual(
            CodexWorkspaceCredentials.seatFilename(accountID: goAccountID),
            a
        )
    }

    func testKeychainAccountNameStable() {
        let home = URL(fileURLWithPath: "/Users/example/.codex")
        let name = CodexWorkspaceCredentials.keychainAccountName(codexHome: home)
        XCTAssertTrue(name.hasPrefix("cli|"))
        XCTAssertEqual(name.count, 20)
        XCTAssertEqual(name, CodexWorkspaceCredentials.keychainAccountName(codexHome: home))
    }

    func testPreferredPlanDoesNotDemoteTeamToGo() {
        let preferred = ChatGPTPlanFormatter.preferredPlanType(
            usagePlan: "go",
            membershipPlan: "team",
            jwtPlan: "go",
            structure: "workspace",
            workspaceName: "CR"
        )
        XCTAssertEqual(preferred, "team")
    }

    // MARK: - Auth identity (UI must not collapse Go + Team by email)

    func testCodexIdentityKeyIncludesAccountID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeproxy-seat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let goURL = dir.appendingPathComponent("codex-go.json")
        let teamURL = dir.appendingPathComponent("codex-team.json")
        let goJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
            exp: Date().addingTimeInterval(3600)
        )
        let teamJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": teamAccountID, "chatgpt_plan_type": "team"],
            exp: Date().addingTimeInterval(3600)
        )
        try writeAuth(at: goURL, email: "shubham.takankhar@gmail.com", access: goJWT, accountID: goAccountID, plan: "go")
        try writeAuth(at: teamURL, email: "shubham.takankhar@gmail.com", access: teamJWT, accountID: teamAccountID, plan: "team")

        let goAccount = AuthAccount(
            id: goURL.lastPathComponent,
            email: "shubham.takankhar@gmail.com",
            login: nil,
            type: .codex,
            expired: nil,
            filePath: goURL,
            isDisabled: false,
            planLabel: "ChatGPT Go"
        )
        let teamAccount = AuthAccount(
            id: teamURL.lastPathComponent,
            email: "shubham.takankhar@gmail.com",
            login: nil,
            type: .codex,
            expired: nil,
            filePath: teamURL,
            isDisabled: false,
            planLabel: "ChatGPT Team"
        )

        let goKey = AuthManager.identityKey(for: goAccount)
        let teamKey = AuthManager.identityKey(for: teamAccount)
        XCTAssertNotEqual(goKey, teamKey, "Go and Team seats must not share UI identity")
        XCTAssertTrue(goKey.contains(goAccountID.lowercased()))
        XCTAssertTrue(teamKey.contains(teamAccountID.lowercased()))
    }

    func testResolveFreshFailsWhenAccessExpiredAndRefreshDead() async {
        let expiredJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": goAccountID, "chatgpt_plan_type": "go"],
            exp: Date().addingTimeInterval(-7200)
        )
        let seed: [String: Any] = [
            "access_token": expiredJWT,
            "refresh_token": "rt.1.definitely-invalid-for-test-\(UUID().uuidString)",
            "account_id": goAccountID,
            "email": "fresh-fail-\(UUID().uuidString)@example.com",
            "type": "codex",
        ]
        let result = await CodexWorkspaceCredentials.resolveFresh(
            preferredAccountID: goAccountID,
            seed: seed,
            email: seed["email"] as? String
        )
        switch result {
        case .success:
            XCTFail("expected refresh failure for dead RT")
        case .failure(let err):
            if case .refreshFailed(let id, _) = err {
                XCTAssertEqual(id.lowercased(), goAccountID.lowercased())
            } else {
                XCTFail("unexpected error \(err)")
            }
        }
    }

    func testResolveFreshSucceedsWhenAccessStillValidWithoutRefresh() async {
        let liveJWT = Self.makeUnsignedJWT(
            auth: ["chatgpt_account_id": teamAccountID, "chatgpt_plan_type": "team"],
            exp: Date().addingTimeInterval(7200)
        )
        let seed: [String: Any] = [
            "access_token": liveJWT,
            "refresh_token": "rt.unused",
            "account_id": teamAccountID,
            "email": "live-ok-\(UUID().uuidString)@example.com",
            "type": "codex",
        ]
        let result = await CodexWorkspaceCredentials.resolveFresh(
            preferredAccountID: teamAccountID,
            seed: seed,
            email: seed["email"] as? String
        )
        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.accountID.lowercased(), teamAccountID.lowercased())
            XCTAssertEqual(CodexWorkspaceCredentials.chatgptPlanType(from: payload.accessToken), "team")
        case .failure(let err):
            XCTFail("unexpected failure \(err)")
        }
    }

    // MARK: - Helpers

    private func writeAuth(
        at url: URL,
        email: String,
        access: String,
        accountID: String,
        plan: String
    ) throws {
        let record: [String: Any] = [
            "type": "codex",
            "email": email,
            "access_token": access,
            "account_id": accountID,
            "plan_type": plan,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
        try data.write(to: url)
    }

    /// Minimal unsigned JWT (header.payload.sig) — only payload is parsed by production code.
    private static func makeUnsignedJWT(auth: [String: Any], exp: Date) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URL()
        var payloadObj: [String: Any] = [
            "https://api.openai.com/auth": auth,
            "exp": Int(exp.timeIntervalSince1970),
        ]
        // silence unused mutation warning if any
        _ = payloadObj
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadObj)
        let payload = payloadData.base64URL()
        return "\(header).\(payload).sig"
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
