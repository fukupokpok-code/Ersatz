#!/usr/bin/env bash
# Build Ersatz in release mode and wrap the binary in a double-clickable app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: scripts/bundle.sh must be run on macOS." >&2
  exit 1
fi

swift build -c release --product Ersatz
BIN_DIR="$(swift build -c release --product Ersatz --show-bin-path)"
BIN="${BIN_DIR}/Ersatz"
if [[ ! -x "$BIN" ]]; then
  echo "error: missing executable at $BIN" >&2
  exit 1
fi

APP="${ROOT}/build/Ersatz.app"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/Ersatz"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
chmod +x "${APP}/Contents/MacOS/Ersatz"

ICONSET="${ROOT}/Resources/AppIcon.iconset"
ICNS="${ROOT}/Resources/AppIcon.icns"
MASTER="${ROOT}/Resources/AppIcon-1024.png"
if [[ -d "$ICONSET" ]] && command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET" -o "$ICNS"
elif [[ -f "$MASTER" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  mkdir -p "$ICONSET"
  sips -z 16 16 "$MASTER" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$MASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$MASTER" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ICNS"
else
  echo "note: iconutil is unavailable; the app will use a generic icon until it is built on macOS."
fi
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "${APP}/Contents/Resources/AppIcon.icns"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP"
fi

echo "Built ${APP}"
echo "Open it with: open \"${APP}\""
