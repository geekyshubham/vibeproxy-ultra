# Changelog

All notable changes to **VibeProxy Ultra** are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Rate-limit reset banks, with one-tap redemption** — The Overview now shows how many banked resets an account holds and lets you apply one in place, the same way the Wake button works for 5-hour windows. **Grok** joins ChatGPT/Codex: SuperGrok's one-time usage resets (the "clear your full weekly pool" tokens from Settings → Usage, expiring Sep 12, 2026) are read live via xAI's `ConsumerUiSvc` gRPC and can be redeemed from VibeProxy — pick the account, confirm, and the weekly pool clears without opening grok.com. Codex reset credits are now redeemable too (`wham/rate-limit-reset-credits/consume`, soonest-expiring credit first), instead of being display-only. The badge, compact row summary, and "Use rate-limit reset" button render automatically for any provider whose snapshot carries a bank, so future providers need only a fetcher.
- **Paste token JSON** on every provider — drop in `~/.codex/auth.json`, Claude credentials, Cursor token JSON, Copilot oauth, Gemini `oauth_creds.json`, or a CLIProxy auth file and the account is added. No browser round-trip required.
- **Cursor subscription** — usage-summary + Stripe profile (Total / Auto + Composer / API / On-Demand) and plan labels (Free / Pro / Pro+ / Business / Enterprise). Switch injects into Cursor’s `state.vscdb`.
- **Multi-instance** — Settings → Instances launches isolated Cursor / Codex / Claude / Antigravity / VS Code Copilot / Kiro / Gemini profiles, each bindable to a VibeProxy account (Cockpit-style `--user-data-dir` / `CODEX_HOME`).
- Import the signed-in Cursor desktop account from local `state.vscdb`.

### Fixed
- **Idle OAuth expiry is not Codex-only** — Claude, Gemini, Kimi, Kiro, and Cursor refresh tokens are now rotated on the same keep-alive loop. Duplicate files that share a refresh token still refresh once and fan the new token out. Native copies (`~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, Cursor `state.vscdb`) stay in lockstep so a leftover CLI refresh cannot revoke the family.

## [1.3.1] - 2026-08-02

Usage by date, everywhere numbers are shown.

### Added
- **"What did I use on this day?"** — A date picker in the menu bar **Overview** and in the management console top bar, backed by one shared data layer. Pick a day to see that day's tokens, estimated API $, request count, the provider you leaned on most (as a share of spend), and the per-model breakdown.
- **Persisted day history** — Daily totals accumulate in `~/Library/Application Support/VibeProxy/usage-daily.json` (atomic writes, 400-day retention), so history outlives a restart and survives session logs aging out of the scan window. Each scan **replaces** a day's totals per provider rather than adding to them, so refreshing never inflates today.
- **Honest day attribution** — Every provider the Overview counts also appears in the by-date view, so the two can't disagree about a day. Where the per-day figure is weaker, it says so instead of being dropped or dressed up as exact: Copilot reports real day totals but can't name the answering model, and Grok pins a whole session's estimate to its last-active day. OpenCode is read per-turn rather than from its cumulative session row, so a session resumed across several days no longer lands entirely on one.
- **Optional management password** — New Settings toggle, **off by default**: the console is a loopback tool, so a login prompt on a single-user Mac adds friction without adding protection. Turning it on restores the password gate. While auth is off, the server serves the management API only to callers whose TCP peer address is genuinely loopback, and only to same-origin or loopback browser origins — so the port being reachable off-box is not by itself enough to read your keys. It is still an unauthenticated API for anything already running on your Mac; turn the password on if that matters to you.
- Management API: `GET /v0/management/usage-daily` (a day's totals and breakdown) and `GET /v0/management/auth-mode`.

### Security
Both of these were found by an adversarial audit of this release before it shipped, and both were reachable with the default settings.
- **Forwarded headers could forge a loopback caller** — The management API decided "is this caller local" with gin's `ClientIP()`, which honours `X-Forwarded-For` / `X-Real-IP` from any peer because the engine never declared its trusted proxies. With the new password toggle off, that check was the only gate, so `curl -H 'X-Forwarded-For: 127.0.0.1'` from another machine could read plaintext provider keys and linked accounts. Loopback is now judged solely by the TCP peer address, which a header cannot forge. The 5-strike ban is keyed on it too, so an attacker can no longer rotate a header for unlimited key guesses or poison another caller's ban entry.
- **Any website could read the management API from your browser** — Every route answered with `Access-Control-Allow-Origin: *`. That was survivable while a management key was required, but with the password off a management request needs no headers at all, making it a CORS-simple request: any page you happened to visit could `fetch('http://127.0.0.1:8318/v0/management/config')` and read your keys out of the response, or issue a write with no preflight. `/v0/management/*` now refuses browser origins that are neither same-origin nor loopback, before the handler runs, and never echoes the wildcard. The inference endpoints keep the open policy — they require a real API key.

### Fixed
- **Partial days could overwrite complete history** — The per-day scanners filtered log *files* by modification time but not the *days* inside them, so a session file touched today also yielded fragments of days older than the scan window. Since each scan replaces a day's totals per provider, those fragments overwrote complete records that had been saved while the day was current.
- **Large numbers rendered wrong** — `formatTokens` had been copy-pasted into three views with *divergent* tiers: the analytics dashboard handled billions, but the menu bar panel and provider cards stopped at millions, so a 3.1B-token total displayed as `3100.0M`. Every surface now routes through one formatter that scales both up and down — `950`, `12.4K`, `4.2M`, `3.1B`, `2.5T` — and the same rule applies to costs (`<$0.01`, `$18.40`, `$1.2K`) and Kiro credits.
- **"Today" button could vanish after midnight** — A console left open overnight captured today's date once, so the button that returns you to today stayed hidden on a now-stale day. It re-arms at each midnight.
- The same number could round differently in the app and the console (`4.25` → `4.2` vs `4.3`): Swift's `String(format:)` rounds half-to-even, JavaScript's `toFixed` rounds half-away-from-zero. Both now round half away from zero.
- The console's provider-name table was missing Cursor, CodeBuddy, GitLab and Kilo, and mis-cased unknown providers.

### Changed
- The app bundle is now named **VibeProxy Ultra.app**, matching the name already shown in the menu bar and About window. Settings and usage history are unaffected — they are keyed on the bundle identifier and a fixed Application Support path, not the bundle filename. Downloadable archives keep their existing space-free names (`VibeProxy-arm64.zip`), so download URLs are unchanged.
- Kiro plan credits are kept out of token totals throughout (they are stored as millicredits, so summing them would inflate a token count ~1000× per credit). Providers are ranked by **cost**, the only basis comparable across unlike units.
- Version **1.3.1**.

### Note
Day history starts accumulating when this version first runs, so dates before that will legitimately read empty.

## [1.2.4] - 2026-07-29

### Fixed
- **Dual “Active” on ChatGPT Team** — Two different users on the same Team org share one `chatgpt_account_id`. Only the login that matches the native Codex session email is marked **Active** now (seat id alone was enough before).
- **Management UI / icons** — Ship the custom management UI in release builds (embedded in `cli-proxy-api-plus`); branded favicon, icon consistency, and reviewed UI wiring bugs.

### Changed
- Release builds compile `cli-proxy-api-plus` from the vendored fork with the custom UI instead of downloading stock upstream.
- Version **1.2.4**.

## [1.2.3] - 2026-07-14

### Fixed
- **Codex multi-subscription switch** — One OAuth login can own Go + Team/Enterprise. Switching the whole account always pinned JWT **Go**. Each subscription row now has its own **Switch to …** control that writes that workspace id into `~/.codex/auth.json` `tokens.account_id`.
- **Cockpit-style app restart** — On switch (when enabled), kill & relaunch Codex/ChatGPT/Claude (and related CLI processes via `pgrep`) so the desktop app actually reloads the chosen account.
- **Grok usage limits** — Prefer live `~/.grok` tokens, skip dead cli-proxy tokens, auto-refresh once on auth failure, and replace cryptic URLSession “unexpected” errors with actionable messages.

### Changed
- Version **1.2.3**.

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

[1.2.4]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.4
[1.2.3]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.3
[1.2.2]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.2
[1.2.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.1
[1.2.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.2.0
[1.1.2]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.2
[1.1.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.1
[1.1.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.0
[1.0.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.1
[1.0.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.0
