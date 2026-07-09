# Installing VibeProxy Ultra

**VibeProxy Ultra** is the enhanced unofficial fork of [automazeio/vibeproxy](https://github.com/automazeio/vibeproxy) (MIT). Not affiliated with Automaze.

**Requirements:** macOS 13+ · **Apple Silicon** *or* **Intel** builds available on Releases.

## Option 1: Download Pre-built Release (Recommended)

### Step 1: Download

1. Go to **[Geekyshubham/vibeproxy-ultra Releases](https://github.com/Geekyshubham/vibeproxy-ultra/releases)**
2. Download for your Mac:
   - Apple Silicon: `VibeProxy-arm64.dmg` or `VibeProxy-arm64.zip`
   - Intel: `VibeProxy-x86_64.dmg` or `VibeProxy-x86_64.zip`
3. Optional: verify `*.sha256` with `shasum -a 256 -c …`

### Step 2: Install

**ZIP:**
1. Extract and drag `VibeProxy.app` to `/Applications`
2. Launch (Right-click → Open if Gatekeeper blocks)

**DMG:**
1. Open the DMG → drag `VibeProxy.app` to Applications
2. Eject DMG → launch from Applications

### Step 3: Gatekeeper

Ultra releases are **ad-hoc signed** (not Apple Developer ID notarized).

```bash
xattr -cr /Applications/VibeProxy.app
# or
xattr -cr "/Applications/VibeProxy Ultra.app"
```

Or: **Right-click → Open → Open**.

---

## Option 2: Build from Source

### Prerequisites

- macOS 13.0 (Ventura) or later
- Swift 5.9+
- Xcode Command Line Tools
- Git

### Build

```bash
git clone https://github.com/Geekyshubham/vibeproxy-ultra.git
cd vibeproxy-ultra
make app
# or
make install
```

Multi-arch packages:

```bash
APP_VERSION=1.1.0 ./scripts/build-release-artifacts.sh
```

---

## After install

1. Click the menu bar icon → **Settings**
2. Connect Claude Code, Codex, Gemini, Kiro, Copilot, etc.
3. Watch **usage limits**, **analytics**, and **status** in the Ultra popover

---

## Support

- Issues: [github.com/Geekyshubham/vibeproxy-ultra/issues](https://github.com/Geekyshubham/vibeproxy-ultra/issues)
- Releases: [github.com/Geekyshubham/vibeproxy-ultra/releases](https://github.com/Geekyshubham/vibeproxy-ultra/releases)
- Upstream VibeProxy (original): [automazeio/vibeproxy](https://github.com/automazeio/vibeproxy)

**VibeProxy Ultra — unofficial enhanced fork of automazeio/vibeproxy (MIT). Not affiliated with Automaze.**
