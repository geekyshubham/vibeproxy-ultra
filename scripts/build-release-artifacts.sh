#!/bin/bash
# Build VibeProxy Ultra release artifacts for arm64 and x86_64 (zip + dmg + sha256).
# Ad-hoc signed only unless CODESIGN_IDENTITY is set (no Apple notarization secrets required).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${APP_VERSION:-1.0.0}"
VERSION="${VERSION#v}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist}"
RESOURCES="$PROJECT_DIR/src/Sources/Resources"
BINARY_PATH="$RESOURCES/cli-proxy-api-plus"
BACKUP_BINARY="$(mktemp)"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${BLUE}📦 VibeProxy Ultra release build v${VERSION}${NC}"
mkdir -p "$OUT_DIR"
# Preserve the committed binary and restore it after building all arches so the
# working tree isn't left holding whichever arch was built last.
cp "$BINARY_PATH" "$BACKUP_BINARY"
trap 'cp "$BACKUP_BINARY" "$BINARY_PATH"; rm -f "$BACKUP_BINARY"' EXIT

# Build the custom cli-proxy-api-plus (management UI embedded) from the vendored
# CLIProxyAPI fork for the target arch, instead of downloading the STOCK upstream
# binary. Delegates to scripts/build-cliproxy-plus.sh, which builds the UI,
# embeds it, cross-compiles, and fails if the custom UI marker is absent.
build_cliproxy() {
  local arch="$1" # arm64 | x86_64
  echo -e "${BLUE}🔧 Building custom cli-proxy-api-plus (UI embedded) for ${arch}${NC}"
  "$PROJECT_DIR/scripts/build-cliproxy-plus.sh" "$arch" "$BINARY_PATH"
  file "$BINARY_PATH"
}

make_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local stage
  stage=$(mktemp -d)
  cp -R "$app_path" "$stage/VibeProxy.app"
  # Brand the DMG volume with the rocket app icon (matches the CI create-dmg
  # --volicon path) so the mounted disk isn't a generic removable-disk icon.
  if [ -f "$RESOURCES/AppIcon.icns" ]; then
    cp "$RESOURCES/AppIcon.icns" "$stage/.VolumeIcon.icns"
  fi
  # Simple UDZO dmg (no Applications symlink required for usability)
  hdiutil create -volname "VibeProxy Ultra" -srcfolder "$stage" -ov -format UDZO "$dmg_path" >/dev/null
  rm -rf "$stage"
}

build_arch() {
  local arch="$1"
  echo ""
  echo -e "${BLUE}🏗️  Building ${arch}…${NC}"
  build_cliproxy "$arch"
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
