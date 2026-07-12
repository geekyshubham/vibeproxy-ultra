# Changelog

All notable changes to **VibeProxy Ultra** are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.2] - 2026-07-12

### Fixed
- **Today $ undercount (Grok)** — Running builds before 1.2.1 treated Grok `contextTokensUsed` as total usage (often &lt;$1/day) while Kiro alone filled the Today tile (~$16). Cumulative turn estimate + Composer pricing restore Grok’s share.
- **Grok day bucket** — Prefer `summary.json` `updated_at`/`created_at` over signals mtime so active sessions aren’t dropped from Today.
- **Cost re-scan freshness** — Activity probe walks one level of session dirs so nested Grok/Kiro writes trigger a rescan (root dir mtime often stayed stale).

### Changed
- Analytics provider rows show **today $** under each name so Kiro vs Grok vs Codex is obvious.
- Grok volume marked as estimated tokens.
- Version **1.2.2**.

## [1.2.1] - 2026-07-12

Analytics accuracy and live model pricing.

### Fixed
- **Gemini analytics** — Parse top-level `tokens` (not OpenAI-style `usage`); bill thinking as output; subtract cached from input; **dedupe rewritten message ids** so tool-call rewrites no longer ~2× inflate volume.
- **Codex analytics** — Skip `token_count` re-emits when cumulative usage is unchanged (rate-limit refreshes were over-counting).
- **Grok analytics** — Estimate cumulative tokens from turn count × context growth (was a final-window snapshot undercount); request count from assistant messages.
- **Kiro / Copilot “today”** — Bucket by per-turn / per-message timestamps (and Kiro `created_at` fallback), not file mtime, so resumed sessions don’t dump history into today.
- **OpenCode “today”** — Detect ms vs seconds epoch units; sum today’s rows from the `message` table instead of attributing a whole multi-day session total.
- **Pricing** — GPT-5.6 Sol/Terra/Luna, Grok 4.5 / Composer / Build, DeepSeek V4, Kimi K2.6, Gemini 3.x flash tiers; free/coding-plan $0 remote rows no longer clobber list prices.

### Added
- **Auto-updating list prices** from [models.dev](https://models.dev) (daily TTL + disk cache), with Settings toggle. When off, only the built-in catalog is used.
- Faster cost re-scan when local session roots change (activity mtime probe).

### Changed
- Version **1.2.1**.

## [1.2.0] - 2026-07-10

Full menu bar + Settings UI/UX revamp with Apple **Liquid Glass** styling on macOS 26 (Tahoe), backward compatible with earlier macOS.

### Added
- **Liquid Glass** (macOS 26+) — cards, tiles, buttons, and the segmented tab pill use `.glassEffect`; automatically falls back to the existing translucent material on macOS 13–15 via `if #available`.
- Shared design system: spacing/motion tokens, a sliding segmented tab bar, hover-aware button styles, animated stat tiles, and a pulsing live-status dot.

### Changed
- **Menu bar panel** — pulsing live-status header, icon tabs with a sliding indicator, richer overview strip, redesigned footer, and a clear "Connect a provider" empty state with a call to action.
- **Provider cards, usage bars & analytics** — hover highlights, springier expand/collapse, glossy animated progress bars, and per-provider colored analytics bars.
- **Settings window** — right-sized (was oversized), consistent tabbed navigation with icons, brand-tinted provider icons, and unified color tokens.
- **Panel sizing** — screen-aware height with an explicit popover size so the whole panel always fits on screen (fixes off-screen overflow with many providers).
- Version **1.2.0**.

## [1.1.2] - 2026-07-10

### Fixed
- **Grok usage limits** — Prefer valid `~/.grok/auth.json` tokens over stale cli-proxy OAuth for SuperGrok billing (`GetGrokCreditsConfig`). Empty-body `grpc-status: 7` (bad-credentials) is reported clearly instead of “Could not parse billing usage”.
- **ChatGPT/Codex rate-limit resets** — Fetch `wham/rate-limit-reset-credits` and show remaining manual resets (Cockpit-style) on the usage card.

### Changed
- Version **1.1.2**.

## [1.1.1] - 2026-07-09

### Fixed
- **Menu bar port label** — Proxy port no longer shows a locale thousands separator (e.g. `8,337` → `8337`).

### Changed
- Removed remaining third-party fork/attribution branding; product is VibeProxy Ultra only.

## [1.1.0] - 2026-07-09

Analytics accuracy, Kiro quota ground truth, focus-steal fix, and branding cleanup.

### Fixed
- **Settings / focus steal** — Auth/config watchers no longer force Settings to the front. Closed windows clear via `windowWillClose`.
- **Kiro analytics** — Rolling 30-day volume from local session metering only (not billing-period CLI totals).
- **Kiro quota UI** — No invented credit pool; percent-only CLI uses percent display.
- **Volume units** — Credits excluded from global token totals; dashboard formats credits separately.
- **Legacy Opus pricing** — Claude 3 / Opus 4 / 4.1 at $15/$75; 4.5+ at $5/$25.
- **Claude scan roots** — Honors `CLAUDE_CONFIG_DIR/projects`.

### Added
- Local aggregators for Kiro, Grok, OpenCode, and Copilot JB transcripts.
- `kiro-cli /usage` probe (single-flight cache, soft-failure retention, SIGKILL on timeout).
- Expanded token pricing catalog (cache write rates, richer model matching).

### Changed
- Branding is **VibeProxy Ultra** only (About, settings footer, docs, copyright).
- Version **1.1.0**.

## [1.0.1] - 2026-07-09

Accurate quotas, status, and menu UX.

## [1.0.0] - 2026-07-09

Initial VibeProxy Ultra release — usage limits, account import, session reliability, multi-arch packaging.

### Added
- Live per-account usage cards with streaming updates
- Current-account detection + one-click switching (Codex / Claude / Gemini)
- Auto “wake 5h window” scheduler
- Preferences pane (refresh cadence, analytics window, cost estimates, wake controls)
- Menu-bar usage badge (optional)
- Provider status & incidents
- Local token analytics by provider and model
- Configured account import
- Proactive token refresh
- Multi-arch release packaging (arm64 + x86_64)

### Fixed
- Analytics accuracy (Codex deltas, model name validation, Gemini/Antigravity double-count)
- False session expiry when refresh token remains valid

[1.2.2]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.2
[1.2.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.1
[1.2.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.0
[1.1.2]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.2
[1.1.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.1
[1.1.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.0
[1.0.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.1
[1.0.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.0
