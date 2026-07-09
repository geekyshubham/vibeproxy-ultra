import Foundation

/// Rough public list prices (USD per 1M tokens) for local cost estimates.
/// These are *estimates* for analytics — not billing truth. Subscription quotas are separate.
enum TokenPricingCatalog {
    struct Rate: Equatable {
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double

        func costUSD(input: Int, output: Int, cacheRead: Int = 0) -> Double {
            let inCost = Double(input) / 1_000_000 * inputPerMTok
            let outCost = Double(output) / 1_000_000 * outputPerMTok
            let cacheCost = Double(cacheRead) / 1_000_000 * cacheReadPerMTok
            return inCost + outCost + cacheCost
        }
    }

    /// Default when model is unknown — conservative mid-tier blend.
    static let fallback = Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3)

    static func rate(forModel rawModel: String?) -> Rate {
        guard let rawModel, !rawModel.isEmpty else { return fallback }
        let model = rawModel.lowercased()

        // OpenAI / Codex family
        if model.contains("gpt-5") || model.contains("codex") {
            if model.contains("mini") || model.contains("nano") {
                return Rate(inputPerMTok: 0.25, outputPerMTok: 2.0, cacheReadPerMTok: 0.025)
            }
            return Rate(inputPerMTok: 1.25, outputPerMTok: 10.0, cacheReadPerMTok: 0.125)
        }
        if model.contains("o3") || model.contains("o4") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 8.0, cacheReadPerMTok: 0.5)
        }
        if model.contains("o1") {
            return Rate(inputPerMTok: 15.0, outputPerMTok: 60.0, cacheReadPerMTok: 7.5)
        }
        if model.contains("gpt-4o-mini") {
            return Rate(inputPerMTok: 0.15, outputPerMTok: 0.6, cacheReadPerMTok: 0.075)
        }
        if model.contains("gpt-4o") {
            return Rate(inputPerMTok: 2.5, outputPerMTok: 10.0, cacheReadPerMTok: 1.25)
        }
        if model.contains("gpt-4") {
            return Rate(inputPerMTok: 10.0, outputPerMTok: 30.0, cacheReadPerMTok: 5.0)
        }

        // Anthropic
        if model.contains("opus") {
            return Rate(inputPerMTok: 15.0, outputPerMTok: 75.0, cacheReadPerMTok: 1.5)
        }
        if model.contains("sonnet") {
            return Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3)
        }
        if model.contains("haiku") {
            return Rate(inputPerMTok: 0.8, outputPerMTok: 4.0, cacheReadPerMTok: 0.08)
        }
        if model.contains("claude") {
            return Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3)
        }

        // Google
        if model.contains("gemini") {
            if model.contains("flash") {
                return Rate(inputPerMTok: 0.1, outputPerMTok: 0.4, cacheReadPerMTok: 0.025)
            }
            if model.contains("pro") {
                return Rate(inputPerMTok: 1.25, outputPerMTok: 5.0, cacheReadPerMTok: 0.31)
            }
            return Rate(inputPerMTok: 0.5, outputPerMTok: 1.5, cacheReadPerMTok: 0.1)
        }

        // xAI
        if model.contains("grok") {
            return Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.75)
        }

        // DeepSeek / Qwen / Kimi / GLM
        if model.contains("deepseek") {
            return Rate(inputPerMTok: 0.27, outputPerMTok: 1.1, cacheReadPerMTok: 0.07)
        }
        if model.contains("qwen") {
            return Rate(inputPerMTok: 0.4, outputPerMTok: 1.2, cacheReadPerMTok: 0.1)
        }
        if model.contains("kimi") || model.contains("moonshot") {
            return Rate(inputPerMTok: 0.6, outputPerMTok: 2.5, cacheReadPerMTok: 0.15)
        }
        if model.contains("glm") {
            return Rate(inputPerMTok: 0.5, outputPerMTok: 2.0, cacheReadPerMTok: 0.1)
        }

        return fallback
    }

    static func estimateUSD(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0
    ) -> Double {
        rate(forModel: model).costUSD(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadTokens
        )
    }
}
