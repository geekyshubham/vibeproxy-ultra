#!/bin/bash
# Build the custom cli-proxy-api-plus binary WITH the VibeProxy Ultra management
# UI embedded, from the vendored CLIProxyAPI fork in third_party/CLIProxyAPI.
#
# This REPLACES the old "download the stock upstream binary" step: the stock
# binary ships the upstream management panel, not ours. Building from the fork
# with our management-ui/dist embedded via go:embed guarantees every release
# carries our UI (favicon, branding, provider icons) and is immune to the
# upstream 3h auto-updater.
#
# Usage:  scripts/build-cliproxy-plus.sh <arm64|amd64|x86_64> [output_path]
# Output defaults to src/Sources/Resources/cli-proxy-api-plus.
set -euo pipefail

ARCH_IN="${1:?usage: build-cliproxy-plus.sh <arm64|amd64|x86_64> [output_path]}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$PROJECT_DIR/src/Sources/Resources/cli-proxy-api-plus}"

FORK_DIR="$PROJECT_DIR/third_party/CLIProxyAPI"
UI_DIR="$PROJECT_DIR/management-ui"
EMBED_TARGET="$FORK_DIR/internal/managementasset/management.html"
MARKER="VibeProxy Ultra"

# Normalize arch to GOARCH.
case "$ARCH_IN" in
  arm64|aarch64) GOARCH="arm64" ;;
  amd64|x86_64)  GOARCH="amd64" ;;
  *) echo "Unknown arch: $ARCH_IN (want arm64|amd64|x86_64)" >&2; exit 1 ;;
esac

echo "==> Building cli-proxy-api-plus for darwin/$GOARCH"

# 1) Build the single-file management UI (produces management-ui/dist/index.html).
if [ ! -d "$UI_DIR/node_modules" ]; then
  echo "==> Installing management-ui deps"
  (cd "$UI_DIR" && npm ci)
fi
echo "==> Building management UI"
(cd "$UI_DIR" && npm run build)

# 2) Embed the fresh dist into the vendored fork.
echo "==> Embedding management.html into vendored fork"
cp "$UI_DIR/dist/index.html" "$EMBED_TARGET"

# 3) Cross-compile the server (CGO off → clean cross-compile, no C deps).
echo "==> go build ./cmd/server"
(cd "$FORK_DIR" && GOOS=darwin GOARCH="$GOARCH" CGO_ENABLED=0 go build -trimpath -o "$OUT" ./cmd/server)
chmod +x "$OUT"

# 4) Fail loudly if the built binary does NOT carry our UI (would mean a stock
#    build slipped through — the exact regression we are guarding against).
if ! grep -a -q "$MARKER" "$OUT"; then
  echo "::error:: built binary is MISSING the custom management UI ('$MARKER' not found) — refusing to ship a stock build" >&2
  exit 1
fi

echo "==> OK: $(file -b "$OUT")"
echo "==> Custom UI marker hits: $(grep -a -c "$MARKER" "$OUT")"
