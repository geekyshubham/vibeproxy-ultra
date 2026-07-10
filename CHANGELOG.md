# Changelog

All notable changes to **VibeProxy Ultra** are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.2]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.2
[1.1.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.1
[1.1.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.1.0
[1.0.1]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.1
[1.0.0]: https://github.com/Geekyshubham/vibeproxy-ultra/releases/tag/v1.0.0
