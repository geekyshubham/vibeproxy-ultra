import Foundation

/// List-price catalog aligned with CodexBar `CostUsagePricing` (per-token → USD / 1M tokens).
///
/// Pipeline:
/// 1. **Detect model** from the log line (Claude `message.model`, Codex preceding `turn_context`,
///    Kiro `rts_model_state.model_id`, Grok `primaryModelId`, OpenCode session.model JSON).
/// 2. **Normalize** ID (strip provider prefixes / date suffixes).
/// 3. **Price tokens** for that model only — never blend rates across models.
enum TokenPricingCatalog {
    struct Rate: Equatable {
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double
        let cacheWritePerMTok: Double?
        /// Human label for UI, e.g. "$2.50 / $15.00 per 1M"
        var listPriceLabel: String {
            String(format: "$%.2f / $%.2f per 1M tok", inputPerMTok, outputPerMTok)
        }

        init(
            inputPerMTok: Double,
            outputPerMTok: Double,
            cacheReadPerMTok: Double,
            cacheWritePerMTok: Double? = nil
        ) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cacheReadPerMTok = cacheReadPerMTok
            self.cacheWritePerMTok = cacheWritePerMTok
        }

        func costUSD(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double {
            let writeRate = cacheWritePerMTok ?? inputPerMTok
            return Double(input) / 1_000_000 * inputPerMTok
                + Double(output) / 1_000_000 * outputPerMTok
                + Double(cacheRead) / 1_000_000 * cacheReadPerMTok
                + Double(cacheWrite) / 1_000_000 * writeRate
        }
    }

    static let fallback = Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
    static let kiroUSDPerCredit: Double = 0.04

    /// CodexBar stores per-token; we use per-1M.
    private static func m(_ perToken: Double) -> Double { perToken * 1_000_000 }

    // MARK: - Normalize (CodexBar-compatible)

    /// Canonical model id for pricing lookup + analytics grouping.
    static func normalizeModelID(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        // Strip "[Codex] gpt-5" style labels
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // provider/model or anthropic.claude-…
        if name.hasPrefix("openai/") { name = String(name.dropFirst("openai/".count)) }
        if name.hasPrefix("anthropic.") { name = String(name.dropFirst("anthropic.".count)) }
        if name.hasPrefix("xai/") { name = String(name.dropFirst("xai/".count)) }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        // Bedrock-style …claude-xxx tail after last dot when tail starts with claude-
        if let lastDot = name.lastIndex(of: "."), name.contains("claude-") {
            let tail = String(name[name.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { name = tail }
        }
        // Strip :0 / -v1:0 suffixes
        if let r = name.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            name.removeSubrange(r)
        }
        // Strip dated suffix -20251001 if base is known later via contains matching
        if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(name[..<r.lowerBound])
            if !base.isEmpty { name = base }
        }
        // Kiro uses dots in versions (claude-opus-4.8) — normalize to dashes for matching
        // but keep a form that still contains family tokens.
        return name.isEmpty ? nil : name
    }

    static func rate(forModel rawModel: String?) -> Rate {
        guard let normalized = normalizeModelID(rawModel) else { return fallback }
        // Matching key: lowercase + dots→dashes for version fragments
        let model = normalized.lowercased()
        let dashed = model.replacingOccurrences(of: ".", with: "-")

        // --- OpenAI / Codex (most-specific first, like CodexBar tables) ---
        if dashed.contains("gpt-5-5-pro") || model.contains("gpt-5.5-pro") {
            return Rate(inputPerMTok: 30.0, outputPerMTok: 180.0, cacheReadPerMTok: 0)
        }
        if dashed.contains("gpt-5-5") || model.contains("gpt-5.5") || dashed.contains("chat-latest") {
            return Rate(inputPerMTok: 5.0, outputPerMTok: 30.0, cacheReadPerMTok: 0.5)
        }
        if dashed.contains("gpt-5-4-pro") || dashed.contains("gpt-5.4-pro") || model.contains("gpt-5.4-pro") {
            return Rate(inputPerMTok: m(3e-5), outputPerMTok: m(1.8e-4), cacheReadPerMTok: 0)
        }
        if dashed.contains("gpt-5-4-mini") || model.contains("gpt-5.4-mini") {
            return Rate(inputPerMTok: m(7.5e-7), outputPerMTok: m(4.5e-6), cacheReadPerMTok: m(7.5e-8))
        }
        if dashed.contains("gpt-5-4-nano") || model.contains("gpt-5.4-nano") {
            return Rate(inputPerMTok: m(2e-7), outputPerMTok: m(1.25e-6), cacheReadPerMTok: m(2e-8))
        }
        if dashed.contains("gpt-5-4") || model.contains("gpt-5.4") {
            // $2.50 / $15.00 — user's real Codex model
            return Rate(inputPerMTok: m(2.5e-6), outputPerMTok: m(1.5e-5), cacheReadPerMTok: m(2.5e-7))
        }
        if dashed.contains("gpt-5-3-codex-spark") {
            return Rate(inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0)
        }
        if dashed.contains("gpt-5-3") || model.contains("gpt-5.3") {
            return Rate(inputPerMTok: m(1.75e-6), outputPerMTok: m(1.4e-5), cacheReadPerMTok: m(1.75e-7))
        }
        if dashed.contains("gpt-5-2-pro") || model.contains("gpt-5.2-pro") {
            return Rate(inputPerMTok: m(2.1e-5), outputPerMTok: m(1.68e-4), cacheReadPerMTok: 0)
        }
        if dashed.contains("gpt-5-2") || model.contains("gpt-5.2") {
            return Rate(inputPerMTok: m(1.75e-6), outputPerMTok: m(1.4e-5), cacheReadPerMTok: m(1.75e-7))
        }
        if dashed.contains("gpt-5-pro") {
            return Rate(inputPerMTok: m(1.5e-5), outputPerMTok: m(1.2e-4), cacheReadPerMTok: 0)
        }
        if dashed.contains("gpt-5-nano") {
            return Rate(inputPerMTok: m(5e-8), outputPerMTok: m(4e-7), cacheReadPerMTok: m(5e-9))
        }
        if dashed.contains("gpt-5-mini") || dashed.contains("codex-mini") {
            return Rate(inputPerMTok: m(2.5e-7), outputPerMTok: m(2e-6), cacheReadPerMTok: m(2.5e-8))
        }
        if dashed.contains("gpt-5") || dashed.contains("codex") {
            return Rate(inputPerMTok: m(1.25e-6), outputPerMTok: m(1e-5), cacheReadPerMTok: m(1.25e-7))
        }
        if dashed.contains("o3") || dashed.contains("o4") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 8.0, cacheReadPerMTok: 0.5)
        }
        if dashed.contains("o1") {
            return Rate(inputPerMTok: 15.0, outputPerMTok: 60.0, cacheReadPerMTok: 7.5)
        }
        if dashed.contains("gpt-4o-mini") {
            return Rate(inputPerMTok: 0.15, outputPerMTok: 0.6, cacheReadPerMTok: 0.075)
        }
        if dashed.contains("gpt-4o") {
            return Rate(inputPerMTok: 2.5, outputPerMTok: 10.0, cacheReadPerMTok: 1.25)
        }
        if dashed.contains("gpt-4") {
            return Rate(inputPerMTok: 10.0, outputPerMTok: 30.0, cacheReadPerMTok: 5.0)
        }

        // --- Anthropic / Kiro Claude (Opus 4.5–4.8: $5/$25) ---
        if dashed.contains("fable-5") || dashed.contains("mythos-5") || dashed.contains("mythos-preview") {
            return Rate(
                inputPerMTok: 10.0,
                outputPerMTok: 50.0,
                cacheReadPerMTok: 1.0,
                cacheWritePerMTok: 12.5
            )
        }
        if dashed.contains("sonnet-5") {
            // Current introductory pricing through 2026-08-31.
            return Rate(
                inputPerMTok: 2.0,
                outputPerMTok: 10.0,
                cacheReadPerMTok: 0.2,
                cacheWritePerMTok: 2.5
            )
        }
        if dashed.contains("opus-4-8") || dashed.contains("opus-4.8")
            || dashed.contains("opus-4-7") || dashed.contains("opus-4-6")
            || dashed.contains("opus-4-5") || model.contains("claude-opus-4.8")
            || model.contains("claude-opus-4.7") || model.contains("claude-opus-4.6")
        {
            return Rate(
                inputPerMTok: m(5e-6),
                outputPerMTok: m(2.5e-5),
                cacheReadPerMTok: m(5e-7),
                cacheWritePerMTok: m(6.25e-6)
            )
        }
        // Legacy Opus (Anthropic platform: Opus 3 / 4 / 4.1 = $15/$75; 4.5+ = $5/$25).
        if dashed.contains("claude-3-opus") || dashed.contains("opus-3")
            || dashed.contains("claude-opus-3")
            || dashed.contains("opus-4-1") || dashed.contains("opus-4-2025")
            || dashed.contains("opus-4-0")
            || (dashed.contains("opus-4")
                && !dashed.contains("opus-4-5") && !dashed.contains("opus-4-6")
                && !dashed.contains("opus-4-7") && !dashed.contains("opus-4-8")
                && !model.contains("claude-opus-4.5") && !model.contains("claude-opus-4.6")
                && !model.contains("claude-opus-4.7") && !model.contains("claude-opus-4.8"))
        {
            return Rate(
                inputPerMTok: m(1.5e-5),
                outputPerMTok: m(7.5e-5),
                cacheReadPerMTok: m(1.5e-6),
                cacheWritePerMTok: m(1.875e-5)
            )
        }
        // Generic / current Opus family (4.5+ default when version not pinned).
        if dashed.contains("opus") {
            return Rate(
                inputPerMTok: m(5e-6),
                outputPerMTok: m(2.5e-5),
                cacheReadPerMTok: m(5e-7),
                cacheWritePerMTok: m(6.25e-6)
            )
        }
        if dashed.contains("sonnet") {
            return Rate(
                inputPerMTok: m(3e-6),
                outputPerMTok: m(1.5e-5),
                cacheReadPerMTok: m(3e-7),
                cacheWritePerMTok: m(3.75e-6)
            )
        }
        if dashed.contains("haiku") {
            return Rate(
                inputPerMTok: m(1e-6),
                outputPerMTok: m(5e-6),
                cacheReadPerMTok: m(1e-7),
                cacheWritePerMTok: m(1.25e-6)
            )
        }
        if dashed.contains("claude") {
            return Rate(
                inputPerMTok: m(3e-6),
                outputPerMTok: m(1.5e-5),
                cacheReadPerMTok: m(3e-7),
                cacheWritePerMTok: m(3.75e-6)
            )
        }

        // --- Google ---
        if dashed.contains("gemini") {
            if dashed.contains("flash") {
                return Rate(inputPerMTok: 0.1, outputPerMTok: 0.4, cacheReadPerMTok: 0.025)
            }
            if dashed.contains("pro") {
                return Rate(inputPerMTok: 1.25, outputPerMTok: 5.0, cacheReadPerMTok: 0.31)
            }
            return Rate(inputPerMTok: 0.5, outputPerMTok: 1.5, cacheReadPerMTok: 0.1)
        }

        // --- xAI ---
        if dashed.contains("grok") {
            if dashed.contains("composer") || dashed.contains("fast") || dashed.contains("mini") {
                return Rate(inputPerMTok: 0.2, outputPerMTok: 0.5, cacheReadPerMTok: 0.05)
            }
            return Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.75)
        }

        // --- Open-weight / China ---
        if dashed.contains("deepseek") {
            return Rate(inputPerMTok: 0.27, outputPerMTok: 1.1, cacheReadPerMTok: 0.07)
        }
        if dashed.contains("qwen") {
            return Rate(inputPerMTok: 0.4, outputPerMTok: 1.2, cacheReadPerMTok: 0.1)
        }
        if dashed.contains("kimi") || dashed.contains("moonshot") {
            return Rate(inputPerMTok: 0.6, outputPerMTok: 2.5, cacheReadPerMTok: 0.15)
        }
        if dashed.contains("glm") {
            return Rate(inputPerMTok: 0.5, outputPerMTok: 2.0, cacheReadPerMTok: 0.1)
        }

        return fallback
    }

    static func estimateUSD(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) -> Double {
        rate(forModel: model).costUSD(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheWriteTokens
        )
    }

    /// Kiro analytics $ is always API-equivalent credits × list overage rate ($0.04).
    /// Do **not** substitute CLI "Est. cost" overage invoice $ here — that is a different metric
    /// (bill-shaped, often only the overage portion) and is not comparable to other providers.
    static func kiroCostUSD(credits: Double) -> Double {
        max(0, credits) * kiroUSDPerCredit
    }
}
