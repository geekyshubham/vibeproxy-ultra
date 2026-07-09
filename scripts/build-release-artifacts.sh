#!/bin/bash
# Build VibeProxy Ultra release artifacts for arm64 and x86_64 (zip + dmg + sha256).
# Ad-hoc signed only unless CODESIGN_IDENTITY is set (no Apple notarization secrets required).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${APP_VERSION:-1.0.0}"
VERSION="${VERSION#v}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist}"
CLIPROXY_TAG="${CLIPROXY_TAG:-}"
RESOURCES="$PROJECT_DIR/src/Sources/Resources"
BINARY_PATH="$RESOURCES/cli-proxy-api-plus"
BACKUP_BINARY="$(mktemp)"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${BLUE}📦 VibeProxy Ultra release build v${VERSION}${NC}"
mkdir -p "$OUT_DIR"
cp "$BINARY_PATH" "$BACKUP_BINARY"
trap 'cp "$BACKUP_BINARY" "$BINARY_PATH"; rm -f "$BACKUP_BINARY"' EXIT

resolve_cliproxy_tag() {
  if [ -n "$CLIPROXY_TAG" ]; then
    echo "$CLIPROXY_TAG"
    return
  fi
  if command -v gh >/dev/null 2>&1; then
    gh release view --repo router-for-me/CLIProxyAPI --json tagName -q .tagName
  else
    curl -fsSL https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])'
  fi
}

download_cliproxy() {
  local arch="$1" # arm64 | x86_64
  local tag regex url tmp
  tag="$(resolve_cliproxy_tag)"
  if [ "$arch" = "arm64" ]; then
    regex='darwin_(aarch64|arm64)'
  else
    regex='darwin_amd64'
  fi
  echo -e "${BLUE}⬇️  CLIProxyAPI ${tag} for ${arch}${NC}"
  if command -v gh >/dev/null 2>&1; then
    local json
    json=$(gh api "repos/router-for-me/CLIProxyAPI/releases/tags/${tag}")
    url=$(echo "$json" | python3 -c "
import sys,json,re
assets=json.load(sys.stdin)['assets']
rx=re.compile(r'^CLIProxyAPI_.+_${regex}\\.tar\\.gz$')
for a in assets:
    if rx.match(a['name']):
        print(a['browser_download_url']); break
")
  else
    url=$(curl -fsSL "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/tags/${tag}" | python3 -c "
import sys,json,re
assets=json.load(sys.stdin)['assets']
rx=re.compile(r'^CLIProxyAPI_.+_${regex}\\.tar\\.gz$')
for a in assets:
    if rx.match(a['name']):
        print(a['browser_download_url']); break
")
  fi
  if [ -z "${url:-}" ]; then
    echo -e "${RED}Could not resolve CLIProxyAPI asset for ${arch}${NC}" >&2
    exit 1
  fi
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/cliproxy.tar.gz" "$url"
  tar -xzf "$tmp/cliproxy.tar.gz" -C "$tmp"
  local found
  found=$(find "$tmp" -type f \( -name 'CLIProxyAPI' -o -name 'cli-proxy-api' -o -name 'CLIProxyAPIPlus' -o -name 'cli-proxy-api-plus' \) | head -1)
  if [ -z "$found" ]; then
    found=$(find "$tmp" -type f -perm +111 | head -1)
  fi
  if [ -z "$found" ]; then
    echo -e "${RED}Binary not found in tarball for ${arch}${NC}" >&2
    ls -la "$tmp"
    exit 1
  fi
  cp "$found" "$BINARY_PATH"
  chmod +x "$BINARY_PATH"
  file "$BINARY_PATH"
  rm -rf "$tmp"
}

make_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local stage
  stage=$(mktemp -d)
  cp -R "$app_path" "$stage/VibeProxy.app"
  # Simple UDZO dmg (no Applications symlink required for usability)
  hdiutil create -volname "VibeProxy Ultra" -srcfolder "$stage" -ov -format UDZO "$dmg_path" >/dev/null
  rm -rf "$stage"
}

build_arch() {
  local arch="$1"
  echo ""
  echo -e "${BLUE}🏗️  Building ${arch}…${NC}"
  download_cliproxy "$arch"
  rm -rf "$PROJECT_DIR/VibeProxy.app"
  APP_VERSION="$VERSION" TARGET_ARCH="$arch" ./create-app-bundle.sh
  if [ ! -d "$PROJECT_DIR/VibeProxy.app" ]; then
    echo -e "${RED}VibeProxy.app missing after build (${arch})${NC}" >&2
    exit 1
  fi

  local zip_path="$OUT_DIR/VibeProxy-${arch}.zip"
  local dmg_path="$OUT_DIR/VibeProxy-${arch}.dmg"
  rm -f "$zip_path" "$dmg_path" "${zip_path}.sha256" "${dmg_path}.sha256"

  echo -e "${BLUE}📦 ZIP ${arch}${NC}"
  ditto -c -k --sequesterRsrc --keepParent "VibeProxy.app" "$zip_path"
  shasum -a 256 "$zip_path" | awk '{print $1 "  " $2}' | sed "s|$OUT_DIR/||" > "${zip_path}.sha256"
  # rewrite sha256 file to basenames for users
  (cd "$OUT_DIR" && shasum -a 256 "VibeProxy-${arch}.zip" > "VibeProxy-${arch}.zip.sha256")

  echo -e "${BLUE}💿 DMG ${arch}${NC}"
  make_dmg "VibeProxy.app" "$dmg_path"
  (cd "$OUT_DIR" && shasum -a 256 "VibeProxy-${arch}.dmg" > "VibeProxy-${arch}.dmg.sha256")

  ls -lh "$zip_path" "$dmg_path"
  echo -e "${GREEN}✅ ${arch} artifacts ready${NC}"
}

# Prefer native first
build_arch arm64
build_arch x86_64

echo ""
echo -e "${GREEN}All artifacts in ${OUT_DIR}:${NC}"
ls -lh "$OUT_DIR"
