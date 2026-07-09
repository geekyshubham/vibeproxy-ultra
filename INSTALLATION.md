# Installing VibeProxy Ultra

**Requirements:** macOS 13+ · Apple Silicon *or* Intel builds on Releases.

## Option 1: Download Pre-built (Recommended)

1. Open **[Geekyshubham/vibeproxy-ultra Releases](https://github.com/Geekyshubham/vibeproxy-ultra/releases)**
2. Download for your Mac:
   - Apple Silicon: `VibeProxy-arm64.dmg` or `VibeProxy-arm64.zip`
   - Intel: `VibeProxy-x86_64.dmg` or `VibeProxy-x86_64.zip`
3. Optional: `shasum -a 256 -c VibeProxy-arm64.zip.sha256`

### Install

**ZIP:** extract → drag `VibeProxy.app` to `/Applications` → launch  

**DMG:** open → drag to Applications → eject → launch  

### Gatekeeper

Releases are **ad-hoc signed**:

```bash
xattr -cr /Applications/VibeProxy.app
# or
xattr -cr "/Applications/VibeProxy Ultra.app"
```

Or **Right-click → Open → Open**.

---

## Option 2: Build from Source

- macOS 13.0+ · Swift 5.9+ · Xcode Command Line Tools · Git

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

1. Menu bar icon → **Settings**  
2. Connect providers (Claude Code, Codex, Gemini, Kiro, Copilot, …)  
3. Use **usage limits**, **analytics**, and **status** in the popover  

---

## Support

- Issues: [github.com/Geekyshubham/vibeproxy-ultra/issues](https://github.com/Geekyshubham/vibeproxy-ultra/issues)  
- Releases: [github.com/Geekyshubham/vibeproxy-ultra/releases](https://github.com/Geekyshubham/vibeproxy-ultra/releases)

© 2026 Geekyshubham · VibeProxy Ultra · MIT
