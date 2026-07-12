import XCTest
@testable import CLIProxyMenuBar

/// Pins model→rate routing and the corrected 2026 list prices for the models the user's tools
/// actually log. Guards against a model silently falling through to the wrong `contains()` branch
/// or the Sonnet-priced fallback (the high-impact pricing bug class).
final class TokenPricingCatalogTests: XCTestCase {

    private func rate(_ model: String) -> TokenPricingCatalog.Rate {
        TokenPricingCatalog.rate(forModel: model)
    }
    private func assertRate(_ model: String, in inp: Double, out: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        let r = rate(model)
        XCTAssertEqual(r.inputPerMTok, inp, accuracy: 0.001, "\(model) input", file: file, line: line)
        XCTAssertEqual(r.outputPerMTok, out, accuracy: 0.001, "\(model) output", file: file, line: line)
    }

    // MARK: - The two headline mispricings that were fixed

    func testGPT56SolIsFlagshipPriced() {
        // Was falling through to base gpt-5 ($1.25/$10) — a ~4x undercount of the user's Codex model.
        assertRate("gpt-5.6-sol", in: 5.0, out: 30.0)
        XCTAssertGreaterThan(rate("gpt-5.6-sol").inputPerMTok, rate("gpt-5").inputPerMTok)
    }

    func testGPT56TiersDistinct() {
        assertRate("gpt-5.6-terra", in: 2.5, out: 15.0)
        assertRate("gpt-5.6-luna", in: 1.0, out: 6.0)
        assertRate("gpt-5.6", in: 5.0, out: 30.0) // bare family id defaults to Sol
    }

    func testGrok45NotOverpriced() {
        // Was $3/$15; real Grok 4.5 is $2/$6, cached $0.50.
        assertRate("grok-4.5", in: 2.0, out: 6.0)
        XCTAssertEqual(rate("grok-4.5").cacheReadPerMTok, 0.5, accuracy: 0.001)
    }

    func testGrokComposerVsFastSplit() {
        assertRate("grok-composer-2.5-fast", in: 0.5, out: 2.5) // Composer wins over "fast"
        assertRate("grok-4.1-fast", in: 0.2, out: 0.5)
        assertRate("grok-build", in: 1.0, out: 2.0)
    }

    func testOpenWeightUpdated() {
        assertRate("deepseek-v4-pro", in: 0.435, out: 0.87)
        assertRate("kimi-k2.6", in: 0.95, out: 4.0)
        assertRate("moonshotai/kimi-k2.6", in: 0.95, out: 4.0) // provider prefix stripped
    }

    // MARK: - Regression guards for models that were already correct

    func testUnchangedRatesStaySane() {
        assertRate("gpt-5.4", in: 2.5, out: 15.0)
        assertRate("gpt-5.5", in: 5.0, out: 30.0)
        assertRate("gpt-5", in: 1.25, out: 10.0)
        assertRate("claude-opus-4.8", in: 5.0, out: 25.0)
        assertRate("claude-sonnet-4-6", in: 3.0, out: 15.0)
        assertRate("claude-haiku-4-5-20251001", in: 1.0, out: 5.0) // date suffix stripped
        assertRate("anthropic.claude-opus-4-6-v1", in: 5.0, out: 25.0) // bedrock prefix + opus 4.6
    }

    func testGemini35FlashNotLegacy20Rate() {
        // Was matching bare "flash" at gemini-2.0 rates ($0.10/$0.40).
        assertRate("gemini-3.5-flash", in: 1.5, out: 9.0)
        assertRate("gemini-2.5-flash", in: 0.3, out: 2.5)
        assertRate("gemini-2.0-flash", in: 0.1, out: 0.4)
    }

    // MARK: - Rate math + invariants

    func testEstimateUSDMath() {
        // 1M input + 1M output = input + output rate.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "gpt-5.6-sol", inputTokens: 1_000_000, outputTokens: 1_000_000),
            35.0, accuracy: 0.001
        )
        // Anthropic cache: read @0.1x + write @1.25x of $3 sonnet input = $0.30 + $3.75.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "claude-sonnet-4-6", inputTokens: 0, outputTokens: 0,
                                            cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000),
            4.05, accuracy: 0.001
        )
        // OpenAI models have no explicit cache-write rate → falls back to input rate.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "gpt-5.4", inputTokens: 0, outputTokens: 0,
                                            cacheReadTokens: 0, cacheWriteTokens: 1_000_000),
            2.5, accuracy: 0.001
        )
    }

    func testInvariantsAcrossUserModels() {
        for m in ["gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "grok-4.5",
                  "grok-composer-2.5-fast", "claude-opus-4.8", "claude-sonnet-4-6",
                  "deepseek-v4-pro", "kimi-k2.6", "glm-5.2", "gemini-3.5-flash"] {
            let r = rate(m)
            XCTAssertLessThanOrEqual(r.cacheReadPerMTok, r.inputPerMTok + 0.0001, "\(m): cacheRead ≤ input")
            XCTAssertGreaterThanOrEqual(r.outputPerMTok, r.inputPerMTok, "\(m): output ≥ input")
            XCTAssertGreaterThan(r.inputPerMTok, 0, "\(m): nonzero input rate")
        }
        // mini tier must stay cheaper than its base.
        XCTAssertLessThan(rate("gpt-5.4-mini").inputPerMTok, rate("gpt-5.4").inputPerMTok)
    }
}
