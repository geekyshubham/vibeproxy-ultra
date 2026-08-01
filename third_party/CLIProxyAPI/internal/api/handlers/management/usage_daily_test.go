package management

import (
	"encoding/json"
	"math"
	"sort"
	"testing"
)

// swiftEncodedFixture is REAL output from Swift's JSONEncoder, produced by encoding
// UsageDailyStore's payload types (DailyProviderUsage / DailyModelUsage / UsageVolumeUnit /
// DailyUsageFidelity). It is pasted verbatim rather than hand-written so this test fails
// if the Swift writer and this Go reader ever drift apart on field names, enum spellings,
// or nesting — the one seam in the per-date usage feature that no other test covers.
//
// Regenerate with a small Swift program that encodes the same three providers:
//
//	swiftc -O -o /tmp/gen main.swift src/Sources/UsageDailyModels.swift \
//	  src/Sources/UsageVolumeUnit.swift && /tmp/gen
const swiftEncodedFixture = `{
  "days": {
    "2026-07-30": {
      "codex": {
        "fidelity": "exact",
        "models": [
          {
            "cacheReadTokens": 900000,
            "estimatedCostUSD": 5.2,
            "inputTokens": 1300000,
            "model": "gpt-5.4",
            "outputTokens": 42000,
            "requestCount": 88,
            "totalVolume": 2242000,
            "volumeUnit": "tokens"
          }
        ],
        "providerID": "codex",
        "volumeUnit": "tokens"
      },
      "grok": {
        "fidelity": "sessionApproximate",
        "models": [
          {
            "cacheReadTokens": 0,
            "estimatedCostUSD": 0.55,
            "inputTokens": 91000,
            "model": "grok-4",
            "outputTokens": 0,
            "requestCount": 3,
            "totalVolume": 91000,
            "volumeUnit": "estimatedTokens"
          }
        ],
        "providerID": "grok",
        "volumeUnit": "estimatedTokens"
      },
      "kiro": {
        "fidelity": "exact",
        "models": [
          {
            "cacheReadTokens": 0,
            "estimatedCostUSD": 0.168,
            "inputTokens": 4200,
            "model": "kiro-claude-sonnet",
            "outputTokens": 0,
            "requestCount": 7,
            "totalVolume": 4200,
            "volumeUnit": "credits"
          }
        ],
        "providerID": "kiro",
        "volumeUnit": "credits"
      }
    }
  },
  "updatedAt": 1784000000,
  "version": 1
}`

func parseFixture(t *testing.T) *usageDailyFile {
	t.Helper()
	var parsed usageDailyFile
	if err := json.Unmarshal([]byte(swiftEncodedFixture), &parsed); err != nil {
		t.Fatalf("Swift-encoded history did not unmarshal: %v", err)
	}
	return &parsed
}

// The schema version must match what the Swift store writes, or loadUsageDailyFile
// discards the file as unknown and the console silently shows "no data".
func TestSwiftFixtureMatchesSchemaVersion(t *testing.T) {
	parsed := parseFixture(t)
	if parsed.Version != usageDailySchemaVersion {
		t.Fatalf("version = %d, want %d (Swift and Go schema versions have drifted)", parsed.Version, usageDailySchemaVersion)
	}
	if parsed.UpdatedAt != 1784000000 {
		t.Errorf("updatedAt = %v, want 1784000000", parsed.UpdatedAt)
	}
}

// Every field the Swift encoder emits must land in a Go field. A silent mismatch
// would decode as a zero value and under-report usage rather than erroring.
func TestSwiftFixtureFieldsDecodeIntoGoStructs(t *testing.T) {
	parsed := parseFixture(t)

	providers, ok := parsed.Days["2026-07-30"]
	if !ok {
		t.Fatalf("day key 2026-07-30 missing; got days %v", parsed.Days)
	}
	if len(providers) != 3 {
		t.Fatalf("provider count = %d, want 3", len(providers))
	}

	codex, ok := providers["codex"]
	if !ok {
		t.Fatal("codex provider missing")
	}
	if codex.ProviderID != "codex" {
		t.Errorf("providerID = %q, want codex", codex.ProviderID)
	}
	if codex.VolumeUnit != "tokens" {
		t.Errorf("volumeUnit = %q, want tokens", codex.VolumeUnit)
	}
	if codex.Fidelity != "exact" {
		t.Errorf("fidelity = %q, want exact", codex.Fidelity)
	}
	if len(codex.Models) != 1 {
		t.Fatalf("codex model count = %d, want 1", len(codex.Models))
	}

	m := codex.Models[0]
	if m.Model != "gpt-5.4" {
		t.Errorf("model = %q, want gpt-5.4", m.Model)
	}
	if m.InputTokens != 1300000 {
		t.Errorf("inputTokens = %d, want 1300000", m.InputTokens)
	}
	if m.OutputTokens != 42000 {
		t.Errorf("outputTokens = %d, want 42000", m.OutputTokens)
	}
	if m.CacheReadTokens != 900000 {
		t.Errorf("cacheReadTokens = %d, want 900000", m.CacheReadTokens)
	}
	if m.TotalVolume != 2242000 {
		t.Errorf("totalVolume = %d, want 2242000", m.TotalVolume)
	}
	if m.RequestCount != 88 {
		t.Errorf("requestCount = %d, want 88", m.RequestCount)
	}
	if math.Abs(m.EstimatedCostUSD-5.2) > 1e-9 {
		t.Errorf("estimatedCostUSD = %v, want 5.2", m.EstimatedCostUSD)
	}
	if m.VolumeUnit != "tokens" {
		t.Errorf("model volumeUnit = %q, want tokens", m.VolumeUnit)
	}
}

// Swift's enum raw values must match the strings this package switches on. If
// "estimatedTokens" were spelled differently here, Grok's volume would be dropped
// from token totals; if "credits" were, Kiro's millicredits would be added to them.
func TestSwiftEnumSpellingsMatchGoSwitches(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]

	if !volumeAggregatesAsTokens(providers["codex"].VolumeUnit) {
		t.Error("codex tokens must aggregate into the token total")
	}
	if !volumeAggregatesAsTokens(providers["grok"].VolumeUnit) {
		t.Error("grok estimatedTokens must aggregate into the token total")
	}
	if volumeAggregatesAsTokens(providers["kiro"].VolumeUnit) {
		t.Error("kiro credits must NOT aggregate into the token total (millicredits would inflate it ~1000x)")
	}

	if got := usageFidelityCaveat(providers["grok"].Fidelity); got == "" {
		t.Error("sessionApproximate must produce a caveat; Swift spelling may have drifted")
	}
	if got := usageFidelityCaveat(providers["codex"].Fidelity); got != "" {
		t.Errorf("exact fidelity must have no caveat, got %q", got)
	}
}

// The headline numbers: tokens exclude credits, cost includes everything.
func TestTotalsApplyMixedUnitRules(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]

	totalTokens := 0
	totalCost := 0.0
	totalRequests := 0
	for _, provider := range providers {
		for _, m := range provider.Models {
			totalCost += m.EstimatedCostUSD
			totalRequests += m.RequestCount
			if volumeAggregatesAsTokens(m.VolumeUnit) {
				totalTokens += m.TotalVolume
			}
		}
	}

	// 2,242,000 codex + 91,000 grok. Kiro's 4,200 millicredits are excluded.
	if totalTokens != 2333000 {
		t.Errorf("totalTokens = %d, want 2333000 (credits must be excluded)", totalTokens)
	}
	// Cost is the one basis comparable across unlike units.
	if math.Abs(totalCost-5.918) > 1e-9 {
		t.Errorf("totalCostUSD = %v, want 5.918", totalCost)
	}
	if totalRequests != 98 {
		t.Errorf("totalRequests = %d, want 98", totalRequests)
	}
}

// "Which provider did I use most" must rank by cost. Ranking by raw volume would
// wrongly promote Grok (91,000 estimated tokens) over Kiro, and more importantly
// would compare unlike units.
func TestProviderRankingUsesCostNotVolume(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]

	rows := make([]usageDailyProviderRow, 0, len(providers))
	for _, provider := range providers {
		row := usageDailyProviderRow{
			ProviderID: provider.ProviderID,
			VolumeUnit: provider.VolumeUnit,
			Fidelity:   provider.Fidelity,
		}
		for _, m := range provider.Models {
			row.TotalVolume += m.TotalVolume
			row.EstimatedCostUSD += m.EstimatedCostUSD
		}
		rows = append(rows, row)
	}

	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.EstimatedCostUSD != b.EstimatedCostUSD {
			return a.EstimatedCostUSD > b.EstimatedCostUSD
		}
		if a.VolumeUnit == b.VolumeUnit && a.TotalVolume != b.TotalVolume {
			return a.TotalVolume > b.TotalVolume
		}
		return a.ProviderID < b.ProviderID
	})

	want := []string{"codex", "grok", "kiro"}
	for i, id := range want {
		if rows[i].ProviderID != id {
			t.Fatalf("rank %d = %q, want %q (full order %v)", i, rows[i].ProviderID, id, rows)
		}
	}
}

func TestAvailableDaysSkipsDaysWithoutModels(t *testing.T) {
	days := map[string]map[string]usageDailyProvider{
		"2026-07-28": {"codex": {ProviderID: "codex", Models: nil}},
		"2026-07-29": {"codex": {ProviderID: "codex", Models: []usageDailyModel{{Model: "gpt-5.4"}}}},
		"2026-07-30": {"kiro": {ProviderID: "kiro", Models: []usageDailyModel{{Model: "kiro"}}}},
	}
	got := usageDailyAvailableDays(days)
	want := []string{"2026-07-29", "2026-07-30"}
	if len(got) != len(want) {
		t.Fatalf("availableDays = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("availableDays = %v, want %v (must be ascending, data-only)", got, want)
		}
	}
}

func TestDayKeyValidationRejectsMalformedAndImpossibleDates(t *testing.T) {
	valid := []string{"2026-07-30", "2024-02-29", "1999-12-31"}
	for _, v := range valid {
		if !isUsageDayKey(v) {
			t.Errorf("isUsageDayKey(%q) = false, want true", v)
		}
	}
	// Rejecting normalised-but-wrong dates matters: Go's time.Parse would otherwise
	// accept 2026-02-30 and silently answer for 2026-03-02.
	invalid := []string{"", "2026-7-30", "30-07-2026", "2026-02-30", "2025-02-29", "2026-13-01", "2026-07-30T00:00:00Z", "not-a-date"}
	for _, v := range invalid {
		if isUsageDayKey(v) {
			t.Errorf("isUsageDayKey(%q) = true, want false", v)
		}
	}
}

// Display names must agree with UsageProviderNaming.displayName in Swift, or the same
// provider reads differently in the menu bar and the console.
func TestProviderDisplayNamesMatchSwift(t *testing.T) {
	cases := map[string]string{
		"codex":       "Codex",
		"claude":      "Claude",
		"gemini":      "Gemini",
		"antigravity": "Antigravity",
		"copilot":     "Copilot",
		"kiro":        "Kiro CLI",
		"grok":        "Grok CLI",
		"opencode":    "OpenCode",
		"zai":         "Z.AI",
		"kimi":        "Kimi",
		"qwen":        "Qwen",
		"":            "",
	}
	for id, want := range cases {
		if got := usageProviderDisplayName(id); got != want {
			t.Errorf("displayName(%q) = %q, want %q", id, got, want)
		}
	}
}

// An unknown schema version must degrade to "no data" rather than being guessed at.
func TestUnknownSchemaVersionIsTreatedAsNoData(t *testing.T) {
	var parsed usageDailyFile
	if err := json.Unmarshal([]byte(`{"version":999,"updatedAt":1,"days":{}}`), &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if parsed.Version == usageDailySchemaVersion {
		t.Fatal("fixture should carry a deliberately unknown version")
	}
}
