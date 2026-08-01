import Foundation

/// Self-check for `UsageDailyStore`'s in-memory merge/query semantics (no XCTest —
/// only CommandLineTools is installed, so `swift test` cannot run).
///
/// Compile and run from the repo root:
///   swiftc -O -o /tmp/usage-store-spec \
///     src/Verification/UsageDailyStoreSpec.swift \
///     src/Sources/UsageDailyStore.swift \
///     src/Sources/UsageDailyModels.swift \
///     src/Sources/UsageVolumeUnit.swift && /tmp/usage-store-spec
///
/// Uses the `*ForTesting` hooks so nothing touches Application Support. The disk
/// read/write path itself is exercised only by `swift build` plus manual runs.
@main
struct UsageDailyStoreSpec {
    static func main() {
        let recorder = FailureRecorder()

        let d1 = UsageDayKey(value: "2026-07-10")
        let d2 = UsageDayKey(value: "2026-07-11")
        let d3 = UsageDayKey(value: "2026-07-12")

        // The critical claim: each scan recomputes a day's totals from whole log files,
        // so folding a re-scan must REPLACE that (day, provider) rather than accumulate.
        // If this were additive, every refresh would inflate today's usage.
        run("re-recording the same day and provider replaces, never accumulates", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_500, cost: 1.50)])

            let summary = UsageDailyStore.summary(for: d1)
            expectEqual(summary.providers.count, 1, "still one provider row", recorder: recorder)
            expectEqual(summary.totalTokens, 1_500, "latest scan wins", recorder: recorder)
            expectEqual(summary.totalCostUSD, 1.50, "cost replaced, not summed", recorder: recorder)
        }

        run("different providers on the same day coexist", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d1: provider("claude", volume: 2_000, cost: 3.00)])

            let summary = UsageDailyStore.summary(for: d1)
            expectEqual(summary.providers.count, 2, "both providers retained", recorder: recorder)
            expectEqual(summary.totalTokens, 3_000, "volumes add across providers", recorder: recorder)
            expectEqual(summary.topProvider?.providerID, "claude", "ranked by cost", recorder: recorder)
        }

        // This is what makes history outlive the scanner: a scan that no longer sees an
        // old day must not erase it.
        run("recording a new day leaves earlier days untouched", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d3: provider("codex", volume: 4_000, cost: 4.00)])

            expectEqual(UsageDailyStore.summary(for: d1).totalTokens, 1_000, "old day survives", recorder: recorder)
            expectEqual(UsageDailyStore.summary(for: d3).totalTokens, 4_000, "new day recorded", recorder: recorder)
            expectEqual(UsageDailyStore.summary(for: d2).isEmpty, true, "untouched day stays empty", recorder: recorder)
        }

        run("an unknown day returns an empty summary rather than nil", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            let summary = UsageDailyStore.summary(for: UsageDayKey(value: "1999-01-01"))
            expectEqual(summary.isEmpty, true, "empty", recorder: recorder)
            expectEqual(summary.day.value, "1999-01-01", "echoes the requested day", recorder: recorder)
            expectEqual(summary.totalCostUSD, 0, "zero cost", recorder: recorder)
        }

        run("availableDays lists only days with usage, newest first", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d3: provider("claude", volume: 2_000, cost: 2.00)])
            // A provider present but with no model rows must not make the day "available".
            UsageDailyStore.recordForTesting([
                d2: DailyProviderUsage(providerID: "gemini", models: [], volumeUnit: .tokens, fidelity: .exact)
            ])

            expectEqual(
                UsageDailyStore.availableDays().map(\.value),
                ["2026-07-12", "2026-07-10"],
                "descending, empty day excluded",
                recorder: recorder
            )
            expectEqual(UsageDailyStore.earliestDay()?.value, "2026-07-10", "earliest is the oldest with data", recorder: recorder)
        }

        run("earliestDay is nil on an empty store", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            expectEqual(UsageDailyStore.earliestDay() == nil, true, "no floor to offer yet", recorder: recorder)
            expectEqual(UsageDailyStore.availableDays().isEmpty, true, "no days", recorder: recorder)
        }

        run("range queries are inclusive and ascending", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d2: provider("codex", volume: 2_000, cost: 2.00)])
            UsageDailyStore.recordForTesting([d3: provider("codex", volume: 3_000, cost: 3.00)])

            let all = UsageDailyStore.summaries(from: d1, to: d3)
            expectEqual(all.map(\.day.value), ["2026-07-10", "2026-07-11", "2026-07-12"], "ascending, inclusive", recorder: recorder)

            let middle = UsageDailyStore.summaries(from: d2, to: d2)
            expectEqual(middle.count, 1, "single-day range", recorder: recorder)
            expectEqual(middle.first?.totalTokens, 2_000, "correct day", recorder: recorder)
        }

        run("reversed range bounds are normalised", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([d1: provider("codex", volume: 1_000, cost: 1.00)])
            UsageDailyStore.recordForTesting([d3: provider("codex", volume: 3_000, cost: 3.00)])
            // A picker can hand us end < start; returning nothing would look like data loss.
            expectEqual(
                UsageDailyStore.summaries(from: d3, to: d1).map(\.day.value),
                ["2026-07-10", "2026-07-12"],
                "swapped bounds still return the range",
                recorder: recorder
            )
        }

        run("range queries exclude days outside the bounds", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            UsageDailyStore.recordForTesting([UsageDayKey(value: "2026-06-30"): provider("codex", volume: 500, cost: 0.5)])
            UsageDailyStore.recordForTesting([d2: provider("codex", volume: 2_000, cost: 2.00)])
            UsageDailyStore.recordForTesting([UsageDayKey(value: "2026-08-01"): provider("codex", volume: 900, cost: 0.9)])

            expectEqual(
                UsageDailyStore.summaries(from: d1, to: d3).map(\.day.value),
                ["2026-07-11"],
                "neighbouring months excluded",
                recorder: recorder
            )
        }

        run("replaceForTesting installs a whole history", recorder: recorder) {
            UsageDailyStore.replaceForTesting([
                d1: [provider("codex", volume: 1_000, cost: 1.00), provider("kiro", volume: 2_000, cost: 0.50)],
                d3: [provider("claude", volume: 3_000, cost: 3.00)],
            ])
            expectEqual(UsageDailyStore.summary(for: d1).providers.count, 2, "two providers on day 1", recorder: recorder)
            expectEqual(UsageDailyStore.availableDays().count, 2, "two days present", recorder: recorder)
            // Kiro volume is credits, so it must stay out of the token total.
            expectEqual(UsageDailyStore.summary(for: d1).totalTokens, 1_000, "credits excluded from tokens", recorder: recorder)
            expectEqual(UsageDailyStore.summary(for: d1).totalCostUSD, 1.50, "costs still combine", recorder: recorder)
        }

        run("provider ordering from the store is stable", recorder: recorder) {
            UsageDailyStore.resetForTesting()
            // Insert in non-alphabetical order; summary() sorts by ID so repeated reads
            // can't reshuffle rows under the user (dictionary order is not stable).
            UsageDailyStore.recordForTesting([d1: provider("kiro", volume: 10, cost: 0.1)])
            UsageDailyStore.recordForTesting([d1: provider("antigravity", volume: 10, cost: 0.1)])
            UsageDailyStore.recordForTesting([d1: provider("claude", volume: 10, cost: 0.1)])

            expectEqual(
                UsageDailyStore.summary(for: d1).providers.map(\.providerID),
                ["antigravity", "claude", "kiro"],
                "sorted by provider id",
                recorder: recorder
            )
        }

        if recorder.failures == 0 {
            print("UsageDailyStoreSpec: all checks passed")
            Foundation.exit(EXIT_SUCCESS)
        }

        fputs("UsageDailyStoreSpec: \(recorder.failures) check(s) failed\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }

    private static func provider(
        _ id: String,
        volume: Int,
        cost: Double,
        unit: UsageVolumeUnit? = nil
    ) -> DailyProviderUsage {
        // Kiro is the credit-unit provider in production; default accordingly so the
        // mixed-unit checks reflect real data shapes.
        let resolved = unit ?? (id == "kiro" ? .credits : .tokens)
        return DailyProviderUsage(
            providerID: id,
            models: [
                DailyModelUsage(
                    model: "\(id)-model",
                    inputTokens: volume,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    totalVolume: volume,
                    estimatedCostUSD: cost,
                    requestCount: 1,
                    volumeUnit: resolved
                )
            ],
            volumeUnit: resolved,
            fidelity: .exact
        )
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
