import Foundation

/// Billing/volume unit for analytics rows. Token-like units may be summed together;
/// credit units stay separate so Kiro millicredits never inflate "token" totals.
///
/// Lives in its own file (rather than beside the scanner that produces it) so the
/// standalone Verification specs can compile display/aggregation logic against this
/// type without pulling in the whole scanning stack.
enum UsageVolumeUnit: String, Codable, Equatable {
    /// Real token counts from CLI session logs.
    case tokens
    /// Kiro plan credits stored as millicredits (credits × 1000) for sub-credit precision.
    case credits
    /// Rough char/4 (or similar) estimates — still token-like for aggregation.
    case estimatedTokens

    /// Whether this unit may contribute to global token volume totals.
    var aggregatesAsTokens: Bool {
        switch self {
        case .tokens, .estimatedTokens: return true
        case .credits: return false
        }
    }
}
