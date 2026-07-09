# VibeProxy Ultra

<p align="center">
  <img src="icon.png" width="128" height="128" alt="VibeProxy Ultra Icon">
</p>

<p align="center">
<a href="https://github.com/Geekyshubham/vibeproxy-ultra/blob/main/LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-28a745"></a>
<a href="https://github.com/Geekyshubham/vibeproxy-ultra"><img alt="VibeProxy Ultra" src="https://img.shields.io/badge/Product-VibeProxy%20Ultra-6c5ce7"></a>
</p>

**VibeProxy Ultra** is a native macOS menu bar app for routing AI coding tools through your existing subscriptions.

> **Not affiliated with OpenAI, Anthropic, Google, xAI, GitHub, or any AI provider.** · License: **MIT** · © 2026 Geekyshubham

Use your existing Claude Code, ChatGPT/Codex, Gemini, Antigravity, GitHub Copilot, Z.AI GLM, Grok, Kimi, Qwen, OpenCode Go, and related subscriptions with local AI coding tools — **no separate API keys required** for OAuth-based providers.

OAuth, token management, and API routing use a bundled local proxy engine.

<p align="center">
  <img src="docs/screenshot-usage.png" width="720" alt="VibeProxy Ultra usage panel preview">
</p>

---

## What’s new in Ultra

Ultra keeps the native macOS menu bar experience and adds production-oriented account, usage, and session reliability features:

| Area | Ultra improvements |
|------|--------------------|
| **Usage limits** | Live per-account usage cards with streaming updates (results appear as each account finishes, not only after everything is done) |
| **Codex resets** | Clear reset countdowns (`Resets in 3h 12m · time`) on every quota window |
| **Status & incidents** | Live statuspage feeds (OpenAI, Anthropic, GitHub, Cursor, xAI) with active incidents |
| **Analytics accuracy** | Accurate token volume + estimated API-equivalent $ by provider and most-used models — Codex usage is now parsed from local session logs (previously showed zero), per-turn deltas end Codex cumulative-vs-delta double counting, model names are validated (Claude session-title slugs like `reply-with-exactly-the-...` no longer appear as models), and Gemini/Antigravity double-counting is removed |
| **Antigravity** | Separate Gemini Pro/Flash vs Claude/Opus quota groups via Cloud Code `retrieveUserQuota` + `retrieveUserQuotaSummary` |
| **ChatGPT / Codex** | Multi-subscription visibility; plan ranking so Enterprise/Team/Plus are not demoted to JWT “Go” |
| **Z.AI Coding Plan** | Quota limits from `api.z.ai` monitor endpoints (similar to zcode.z.ai) |
| **Account import** | Import configured local accounts for providers (Claude, Codex, Gemini, Antigravity, Z.AI, Copilot, Grok, OpenCode Go, and more) |
| **Account switching** | Detects the live account in native tools (Codex `~/.codex/auth.json`, Claude keychain, Gemini `google_accounts.json`) and switches with one click — writes the native auth atomically with a backup and restarts the desktop app when running; the already-active account shows an **Active** badge instead of the button (Cockpit-style) |
| **False expiry fix** | Access-token clock expiry alone no longer marks a session dead when a usable refresh token still exists |
| **Proactive refresh** | Background token refresh with grace window so sessions stay warm |
| **Auto quota wake** | Auto “wake 5h window” scheduler keeps supported provider sessions (Codex/Claude/Antigravity/Gemini) warm on a ~5h cadence with cooldown, grace, and back-off — configurable |
| **OpenCode Go** | First-class OpenAI-compatibility provider entry (not hidden as reserved) |
| **Menu bar UX** | CodexBar-inspired glass UI: Overview / Status / Analytics tabs, pulse strip, refined cards |
| **Preferences** | New settings pane: usage/status refresh cadence, analytics history window, show/hide cost estimates and the Status/Analytics tabs, restart-app-on-switch and confirm-before-switch toggles, and auto-wake provider selection + grace |
| **Menu bar badge** | Optional menu-bar badge showing peak quota % |
| **Performance** | Faster local log scanning: per-file mtime cache (unchanged files aren't re-parsed), coalesced timers (`Timer.tolerance`), configurable intervals, and a trimmed scan list |

Also includes: one-click server start/stop, multi-account round-robin, provider enable/disable, Vercel AI Gateway option for Claude, and a self-contained `.app` bundle.

---

## License

**Copyright (c) 2026 Geekyshubham / VibeProxy Ultra** — MIT. See [LICENSE](LICENSE).

---

## Important risks (read before using)

| Risk | Notes |
|------|--------|
| **Provider ToS** | Proxying Claude / ChatGPT / Gemini / other subscriptions may violate a provider’s terms depending on use. Use at your own risk. |
| **Branding** | Product name is **VibeProxy Ultra** (Geekyshubham). |
| **Secrets** | Never commit OAuth tokens, API keys, or credentials. Auth files live under `~/.cli-proxy-api/` on your machine only. |
| **Dependencies** | Bundled proxy binary and third-party libs may have their own licenses — verify before redistribution. |
| **Auto-updates** | Sparkle auto-checks are disabled; install releases from this repo manually. |

---

## Features (full list)

- Native SwiftUI macOS menu bar app
- One-click local proxy server management
- OAuth connect flows for major providers + API-key providers (e.g. Z.AI)
- Multi-account support with failover when rate-limited
- Provider priority / enable toggles with hot reload
- **Streaming usage dashboard** per account and quota window
- **Local app account import** for configured provider credentials
- **Proactive token refresh** + **quota wake** keep-alives
- Vercel AI Gateway routing option for Claude
- Dark-mode friendly icons and menu bar status
- Self-contained app bundle (binary + config)

---

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools / Swift 5.9+ to build from source

## Installation

### Download pre-built release (recommended)

1. Open **[Releases](https://github.com/geekyshubham/vibeproxy-ultra/releases)**
2. Download the right build for your Mac:

| Architecture | DMG | ZIP |
|--------------|-----|-----|
| **Apple Silicon** (M1/M2/M3/M4) | `VibeProxy-arm64.dmg` | `VibeProxy-arm64.zip` |
| **Intel** (x86_64) ⚠️ | `VibeProxy-x86_64.dmg` | `VibeProxy-x86_64.zip` |

3. Open the DMG (or extract the ZIP) and drag `VibeProxy.app` to **Applications**
4. Launch the app

> **Gatekeeper note:** Ultra releases are **ad-hoc signed** (not Apple Developer ID notarized). On first open, use **Right-click → Open → Open**, or remove quarantine with `xattr -cr /Applications/VibeProxy.app`.

Verify checksums (optional):

```bash
shasum -a 256 -c VibeProxy-arm64.zip.sha256
```

### Build from source

```bash
git clone https://github.com/geekyshubham/vibeproxy-ultra.git
cd vibeproxy-ultra
make app          # creates VibeProxy.app
make run          # build + launch
# or
make install      # install to /Applications
```

Local multi-arch release packages (same assets as GitHub Releases):

```bash
APP_VERSION=1.0.0 ./scripts/build-release-artifacts.sh
# outputs under dist/: VibeProxy-{arm64,x86_64}.{zip,dmg} + .sha256
```

See [INSTALLATION.md](INSTALLATION.md) for more detail (paths still refer to the app bundle name `VibeProxy.app`).

## Usage

1. Launch the app — a menu bar icon appears.
2. Click the icon for the **Ultra** popover (status, accounts, usage).
3. Open **Settings** to connect providers, import local accounts, and manage the server.
4. Point coding tools (Factory, Amp, etc.) at the local proxy (default thinking/proxy path uses ports documented in the original setup guides).

Setup guides from upstream still apply conceptually:

- [Factory CLI Setup](FACTORY_SETUP.md)
- [Amp CLI Setup](AMPCODE_SETUP.md)

Replace any `automazeio/vibeproxy` download links with this Ultra repo when installing the fork.

---

## Project structure

```text
vibeproxy-ultra/
├── LICENSE                 # MIT · © 2026 Geekyshubham
├── README.md
├── Makefile / create-app-bundle.sh
├── scripts/                # multi-arch release packaging
├── src/
│   ├── Package.swift
│   ├── Info.plist
│   ├── Sources/            # SwiftUI app + usage/import/refresh services
│   │   └── Resources/      # proxy binary, config.yaml, icons
│   └── Tests/
└── icon.png
```

Notable sources:

- `NativeUsageFetcher.swift` / `UsageStore.swift` / `ProviderUsageCardView.swift` — usage limits UI
- `ConfiguredAccountDiscovery.swift` / `ConfiguredAccountImporter.swift` — local account import
- `TokenRefreshService.swift` / `QuotaWakeService.swift` — session reliability
- `MenuBarPanelView.swift` / `MenuBarPopoverController.swift` — menu bar
- `LocalUsageAggregators.swift` / `KiroCLIUsageProbe.swift` — Kiro/Grok/OpenCode/Copilot analytics

---

## Credits

- **VibeProxy Ultra**: Geekyshubham
- **Local proxy engine**: open-source CLIProxy ecosystem

## Support

- **Issues**: [Geekyshubham/vibeproxy-ultra](https://github.com/Geekyshubham/vibeproxy-ultra/issues)
- **Releases**: [GitHub Releases](https://github.com/Geekyshubham/vibeproxy-ultra/releases)

---

© 2026 Geekyshubham · VibeProxy Ultra  
MIT License — see [LICENSE](LICENSE).
