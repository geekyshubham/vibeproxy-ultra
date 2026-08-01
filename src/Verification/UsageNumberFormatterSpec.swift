import Foundation

/// Self-check for `UsageNumberFormatter` (no XCTest — only CommandLineTools is
/// installed on this machine, so `swift test` cannot run).
///
/// Compile and run from the repo root:
///   swiftc -O -o /tmp/usage-number-formatter-spec \
///     src/Verification/UsageNumberFormatterSpec.swift \
///     src/Sources/UsageNumberFormatter.swift \
///     src/Sources/UsageVolumeUnit.swift && /tmp/usage-number-formatter-spec
@main
struct UsageNumberFormatterSpec {
    static func main() {
        let recorder = FailureRecorder()

        run("tokens scale down to plain integers", recorder: recorder) {
            expectEqual(UsageNumberFormatter.tokens(0), "0", "zero", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(7), "7", "single digit", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(950), "950", "just under 1K", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(999), "999", "boundary below K", recorder: recorder)
        }

        run("tokens scale up through K/M/B/T", recorder: recorder) {
            expectEqual(UsageNumberFormatter.tokens(1_000), "1K", "exact K", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(12_400), "12.4K", "K with decimal", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(1_000_000), "1M", "exact M", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(4_200_000), "4.2M", "M with decimal", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(421_000_000), "421M", "M three digits, no decimal", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(1_000_000_000_000), "1T", "exact T", recorder: recorder)
        }

        // The bug this formatter exists to kill: MenuBarPanelView and
        // ProviderUsageCardView had no billions tier, so 3.1B rendered "3100.0M".
        run("billions never render as thousands-of-millions", recorder: recorder) {
            expectEqual(UsageNumberFormatter.tokens(3_100_000_000), "3.1B", "3.1 billion tokens", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(1_000_000_000), "1B", "exact B", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(15_000_000_000), "15B", "15 billion", recorder: recorder)
        }

        // Rounding must not produce a four-digit mantissa like "1000K".
        run("values rounding up promote to the next tier", recorder: recorder) {
            expectEqual(UsageNumberFormatter.tokens(999_951), "1M", "999,951 promotes to M", recorder: recorder)
            expectEqual(UsageNumberFormatter.tokens(999_999_999), "1B", "just under a billion promotes to B", recorder: recorder)
        }

        run("usd keeps cent precision where cents matter", recorder: recorder) {
            expectEqual(UsageNumberFormatter.usd(0), "$0.00", "zero cost", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(0.004), "<$0.01", "sub-cent is not shown as zero", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(0.42), "$0.42", "cents", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(18.4), "$18.40", "dollars and cents", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(999.99), "$999.99", "just under scaling", recorder: recorder)
        }

        run("usd scales up past a thousand dollars", recorder: recorder) {
            expectEqual(UsageNumberFormatter.usd(1_200), "$1.2K", "thousands", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(3_400_000), "$3.4M", "millions", recorder: recorder)
        }

        run("usd handles negative adjustments", recorder: recorder) {
            expectEqual(UsageNumberFormatter.usd(-5.5), "-$5.50", "negative dollars", recorder: recorder)
            expectEqual(UsageNumberFormatter.usd(-2_000), "-$2K", "negative thousands", recorder: recorder)
        }

        // Kiro stores millicredits (credits × 1000). Mislabelling these as tokens
        // would silently inflate token totals by 1000×.
        run("credits convert from millicredits and keep sub-credit precision", recorder: recorder) {
            expectEqual(UsageNumberFormatter.credits(millicredits: 0), "0 cr", "zero credits", recorder: recorder)
            expectEqual(UsageNumberFormatter.credits(millicredits: 500), "0.50 cr", "half a credit", recorder: recorder)
            expectEqual(UsageNumberFormatter.credits(millicredits: 1_500), "1.5 cr", "one and a half", recorder: recorder)
            expectEqual(UsageNumberFormatter.credits(millicredits: 15_000), "15 cr", "whole credits", recorder: recorder)
            expectEqual(UsageNumberFormatter.credits(millicredits: 1_500_000), "1.5K cr", "thousands of credits", recorder: recorder)
        }

        run("volume respects the provider's unit", recorder: recorder) {
            expectEqual(
                UsageNumberFormatter.volume(4_200_000, unit: .tokens),
                "4.2M",
                "tokens", recorder: recorder
            )
            expectEqual(
                UsageNumberFormatter.volume(4_200_000, unit: .estimatedTokens),
                "4.2M est",
                "estimated tokens are marked", recorder: recorder
            )
            expectEqual(
                UsageNumberFormatter.volume(1_500_000, unit: .credits),
                "1.5K cr",
                "credits are never labelled as tokens", recorder: recorder
            )
        }

        run("credits stay out of token aggregation", recorder: recorder) {
            expectEqual(UsageVolumeUnit.tokens.aggregatesAsTokens, true, "tokens aggregate", recorder: recorder)
            expectEqual(UsageVolumeUnit.estimatedTokens.aggregatesAsTokens, true, "estimates aggregate", recorder: recorder)
            expectEqual(UsageVolumeUnit.credits.aggregatesAsTokens, false, "credits do not aggregate", recorder: recorder)
        }

        if recorder.failures == 0 {
            print("UsageNumberFormatterSpec: all checks passed")
            Foundation.exit(EXIT_SUCCESS)
        }

        fputs("UsageNumberFormatterSpec: \(recorder.failures) check(s) failed\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}

private final class FailureRecorder {
    var failures = 0
}

private func run(_ name: String, recorder: FailureRecorder, _ body: () -> Void) {
    let startingFailures = recorder.failures
    body()
    let status = recorder.failures == startingFailures ? "PASS" : "FAIL"
    print("[\(status)] \(name)")
}

private func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: T,
    _ message: String,
    recorder: FailureRecorder
) {
    let value = actual()
    guard value == expected else {
        recorder.failures += 1
        fputs("  - \(message): expected \(expected), got \(value)\n", stderr)
        return
    }
}
