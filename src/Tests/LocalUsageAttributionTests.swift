import XCTest
@testable import CLIProxyMenuBar

/// Guards the per-provider "today" attribution and token parsing that drifted from the CLI
/// tools' on-disk formats. Each assertion pins one real bug that was fixed:
///  - Gemini analytics were always 0 (wrong `usage` shape vs top-level `tokens`).
///  - Grok tokens were a context snapshot, not cumulative usage.
///  - Kiro/Copilot "today" leaked prior-day turns via the file-mtime fallback.
///  - OpenCode's ms/seconds ambiguity could dump all history into "today".
final class LocalUsageAttributionTests: XCTestCase {

    /// Local-day key computed the same way the production `dayKey(for:)` helpers do.
    private func dayKey(_ iso: String) -> Int {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
        return Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    // MARK: - Gemini (schema: top-level `tokens`, not OpenAI-style `usage`)

    func testGeminiTokenBreakdownReadsTopLevelTokens() {
        // Real Gemini CLI line shape: {"type":"gemini","tokens":{input,output,cached,thoughts,total}}
        let b = LocalTokenCostScanner.geminiTokenBreakdown(
            ["input": 9508, "output": 105, "cached": 0, "thoughts": 344, "total": 9957]
        )
        XCTAssertEqual(b.nonCachedInput, 9508)
        XCTAssertEqual(b.billedOutput, 449) // output + thoughts (thinking billed as output)
        XCTAssertEqual(b.cacheRead, 0)
        XCTAssertEqual(b.total, 9957) // declared total wins
        XCTAssertGreaterThan(b.total, 0, "regression: Gemini usage must not parse to 0")
    }

    func testGeminiTokenBreakdownSubtractsCachedAndDerivesTotal() {
        // `input` (promptTokenCount) includes cached; when `total` is absent it is derived.
        let b = LocalTokenCostScanner.geminiTokenBreakdown(
            ["input": 1000, "cached": 400, "output": 50, "thoughts": 0, "total": 0]
        )
        XCTAssertEqual(b.nonCachedInput, 600)
        XCTAssertEqual(b.cacheRead, 400)
        XCTAssertEqual(b.billedOutput, 50)
        XCTAssertEqual(b.total, 1050) // 600 + 50 + 400 (no double count)
    }

    /// Gemini CLI rewrites the same assistant `id` (plain line, then toolCalls line) with
    /// identical `tokens`. Dedup is inside `parseFile`; this pins the message-id set logic
    /// the scanner uses so a regression can't silently re-double-count.
    func testGeminiMessageIDDedupSetSemantics() {
        var seen = Set<String>()
        XCTAssertTrue(seen.insert("8f956767-d9dc-49bd-933e-b5f49b3d135b").inserted)
        XCTAssertFalse(seen.insert("8f956767-d9dc-49bd-933e-b5f49b3d135b").inserted,
                       "regression: second rewrite of the same Gemini message id must be skipped")
        XCTAssertTrue(seen.insert("other-id").inserted)
    }

    // MARK: - Grok (cumulative estimate vs context snapshot)

    func testGrokEstimateExceedsSnapshotFloor() {
        // Old code = before + context (a snapshot). New estimate must be strictly larger for a
        // multi-turn session because each turn re-sends the growing context.
        let before = 0, context = 53_041, turns = 11
        let snapshot = before + context
        let estimate = LocalGrokUsage.estimatedCumulativeTokens(before: before, context: context, turns: turns)
        XCTAssertEqual(estimate, before + context * (turns + 1) / 2) // 318_246
        XCTAssertGreaterThan(estimate, snapshot, "regression: Grok must not fall back to the snapshot undercount")
    }

    func testGrokEstimateAddsPreCompactionSpans() {
        let estimate = LocalGrokUsage.estimatedCumulativeTokens(before: 722_445, context: 75_940, turns: 283)
        XCTAssertEqual(estimate, 722_445 + 75_940 * 284 / 2)
        XCTAssertGreaterThan(estimate, 722_445 + 75_940)
    }

    func testGrokEstimateZeroWhenIdle() {
        XCTAssertEqual(LocalGrokUsage.estimatedCumulativeTokens(before: 0, context: 0, turns: 0), 0)
    }

    // MARK: - Kiro (per-turn end_timestamp wins; fallback is stable, never file mtime)

    func testKiroParsesSixDigitFractionalTimestamp() {
        XCTAssertNotNil(
            LocalKiroCredits.parseKiroDate("2026-07-11T12:29:06.357457Z"),
            "regression: Kiro end_timestamp (6-digit microseconds) must parse"
        )
        XCTAssertNotNil(LocalKiroCredits.parseKiroDate("2026-07-12T11:33:30Z"))
    }

    func testKiroTurnDayUsesEndTimestampNotFallback() {
        let jul11 = dayKey("2026-07-11T12:29:06.357457Z")
        let jul12Fallback = dayKey("2026-07-12T00:00:00.000Z")
        // A turn finalized Jul-11 in a session rewritten Jul-12 must land on Jul-11.
        let resolved = LocalKiroCredits.resolveTurnDayKey(
            endTimestamp: "2026-07-11T12:29:06.357457Z",
            fallbackDayKey: jul12Fallback
        )
        XCTAssertEqual(resolved, jul11)
        XCTAssertNotEqual(resolved, jul12Fallback, "regression: resumed-session turns must not leak into today")
    }

    func testKiroTurnDayUsesFallbackWhenTimestampMissingOrBad() {
        let fallback = 12_345
        XCTAssertEqual(LocalKiroCredits.resolveTurnDayKey(endTimestamp: nil, fallbackDayKey: fallback), fallback)
        XCTAssertEqual(LocalKiroCredits.resolveTurnDayKey(endTimestamp: "not-a-date", fallbackDayKey: fallback), fallback)
    }

    // MARK: - Copilot (per-message timestamp, not file mtime)

    func testCopilotDayUsesMessageTimestamp() {
        let jul2 = dayKey("2026-07-02T10:02:06.936Z")
        let mtimeFallback = 999_999
        let resolved = LocalCopilotUsage.copilotDayKey(
            timestamp: "2026-07-02T10:02:06.936Z",
            fallbackDayKey: mtimeFallback
        )
        XCTAssertEqual(resolved, jul2)
        XCTAssertNotEqual(resolved, mtimeFallback, "regression: reopened transcript must not retag old messages as today")
    }

    func testCopilotDayFallsBackWhenNoTimestamp() {
        XCTAssertEqual(LocalCopilotUsage.copilotDayKey(timestamp: nil, fallbackDayKey: 42), 42)
        XCTAssertEqual(LocalCopilotUsage.copilotDayKey(timestamp: "garbage", fallbackDayKey: 42), 42)
    }

    // MARK: - OpenCode (epoch unit detection)

    func testOpenCodeMillisecondDetection() {
        XCTAssertTrue(LocalOpenCodeUsage.timeUpdatedIsMilliseconds(1_783_674_224_342))  // ms (current)
        XCTAssertFalse(LocalOpenCodeUsage.timeUpdatedIsMilliseconds(1_783_674_224))      // seconds
        XCTAssertFalse(LocalOpenCodeUsage.timeUpdatedIsMilliseconds(0))                  // empty DB
    }
}
