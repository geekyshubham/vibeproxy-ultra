import XCTest
@testable import CLIProxyMenuBar

/// Guards the auto-updating pricing pipeline: models.dev parsing, native-provider preference,
/// Anthropic cache-write derivation, and that a live rate overrides the static catalog.
final class RemotePricingCatalogTests: XCTestCase {

    override func tearDown() {
        // Never leak an injected table into other tests / the running app.
        RemotePricingCatalog.replaceRatesForTesting([:])
        super.tearDown()
    }

    private let sample = Data("""
    {
      "openai":   { "models": {
          "gpt-5.4": { "cost": { "input": 2.5, "output": 15, "cache_read": 0.25, "cache_write": 3.125 } },
          "gpt-5.6": { "cost": { "input": 5,   "output": 30, "cache_read": 0.5 } } } },
      "anthropic":{ "models": {
          "claude-opus-4-8": { "cost": { "input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25 } } } },
      "google":   { "models": {
          "gemini-3.5-flash": { "cost": { "input": 1.5, "output": 9 } } } },
      "zai-coding-plan": { "models": {
          "glm-5.2": { "cost": { "input": 0, "output": 0, "cache_read": 0 } } } },
      "zai": { "models": {
          "glm-5.2": { "cost": { "input": 1.4, "output": 4.4, "cache_read": 0.26 } } } },
      "somereseller": { "models": {
          "gpt-5.4": { "cost": { "input": 9, "output": 99, "cache_read": 9 } } } }
    }
    """.utf8)

    func testParsesCostIntoNormalizedKeys() {
        let r = RemotePricingCatalog.parse(sample)
        XCTAssertEqual(r["gpt-5-4"]?.outputPerMTok, 15, "gpt-5.4 -> dashed key 'gpt-5-4'")
        XCTAssertEqual(r["gpt-5-6"]?.inputPerMTok, 5)
        XCTAssertEqual(r["claude-opus-4-8"]?.inputPerMTok, 5)
    }

    func testNativeProviderBeatsReseller() {
        let r = RemotePricingCatalog.parse(sample)
        // Both "openai" (native) and "somereseller" list gpt-5.4; native list price must win.
        XCTAssertEqual(r["gpt-5-4"]?.inputPerMTok, 2.5)
        XCTAssertEqual(r["gpt-5-4"]?.outputPerMTok, 15)
    }

    func testAnthropicCacheWriteFromFeedOrDerived() {
        let r = RemotePricingCatalog.parse(sample)
        // Feed ships cache_write for Anthropic — prefer it over re-deriving.
        XCTAssertEqual(r["claude-opus-4-8"]?.cacheWritePerMTok, 6.25)
        // OpenAI feed cache_write is kept too.
        XCTAssertEqual(r["gpt-5-4"]?.cacheWritePerMTok, 3.125)
        // gpt-5.6 has no cache_write in the fixture and is not Anthropic → nil.
        XCTAssertNil(r["gpt-5-6"]?.cacheWritePerMTok)
    }

    func testCacheReadDefaultsToTenPercentWhenMissing() {
        let r = RemotePricingCatalog.parse(sample)
        // gemini line has no cache_read -> default 0.1x input.
        XCTAssertEqual(r["gemini-3-5-flash"]?.cacheReadPerMTok ?? -1, 0.15, accuracy: 0.0001)
    }

    func testSkipsZeroCostFreePlanRows() {
        let r = RemotePricingCatalog.parse(sample)
        // zai-coding-plan lists glm-5.2 at $0; native zai list price must win (and free row skipped).
        XCTAssertEqual(r["glm-5-2"]?.inputPerMTok, 1.4, accuracy: 0.001)
        XCTAssertEqual(r["glm-5-2"]?.outputPerMTok, 4.4, accuracy: 0.001)
    }

    func testAnthropicCacheWriteDerivedWhenFeedOmitsIt() {
        let data = Data("""
        {"anthropic":{"models":{"claude-sonnet-4-6":{"cost":{"input":3,"output":15,"cache_read":0.3}}}}}
        """.utf8)
        let r = RemotePricingCatalog.parse(data)
        XCTAssertEqual(r["claude-sonnet-4-6"]?.cacheWritePerMTok, 3.75, accuracy: 0.001)
    }

    func testGarbageParsesToEmpty() {
        XCTAssertTrue(RemotePricingCatalog.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(RemotePricingCatalog.parse(Data("{}".utf8)).isEmpty)
    }

    func testRemoteRateOverridesStaticCatalog() {
        // Static glm-5.2 is $0.50/$2.00; the live feed corrects it to ~$1.10/$3.85.
        let staticGlm = TokenPricingCatalog.rate(forModel: "glm-5.2")
        XCTAssertEqual(staticGlm.inputPerMTok, 0.5, accuracy: 0.001)

        RemotePricingCatalog.replaceRatesForTesting([
            "glm-5-2": TokenPricingCatalog.Rate(inputPerMTok: 1.1, outputPerMTok: 3.85, cacheReadPerMTok: 0.275),
        ])
        let liveGlm = TokenPricingCatalog.rate(forModel: "glm-5.2")
        XCTAssertEqual(liveGlm.inputPerMTok, 1.1, accuracy: 0.001, "live feed must override static")
        XCTAssertEqual(liveGlm.outputPerMTok, 3.85, accuracy: 0.001)

        // A model the feed doesn't have still falls back to static rules.
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "grok-composer-2.5-fast").outputPerMTok, 2.5, accuracy: 0.001)

        RemotePricingCatalog.replaceRatesForTesting([:])
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "glm-5.2").inputPerMTok, 0.5, accuracy: 0.001,
                       "clearing the feed restores the static fallback")
    }
}
