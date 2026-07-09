#!/usr/bin/env bash
# Build Rocky.saver (a loadable screen-saver bundle) and install it to
# ~/Library/Screen Savers/. Reuses RockyCore.swift from the repo root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SAVER="$HERE/build/Rocky.saver"
MACOS="$SAVER/Contents/MacOS"

echo "▸ Building Rocky.saver…"
rm -rf "$SAVER"
mkdir -p "$MACOS"
cp "$HERE/Info.plist" "$SAVER/Contents/Info.plist"

# Compile the shared core + the saver view into a loadable bundle (MH_BUNDLE).
xcrun swiftc -O \
  -module-name RockySaver \
  -framework ScreenSaver \
  -emit-library -Xlinker -bundle \
  -o "$MACOS/Rocky" \
  "$ROOT/RockyCore.swift" "$HERE/RockySaverView.swift"

file "$MACOS/Rocky"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Library/Screen Savers/Rocky.saver"
  echo "▸ Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$SAVER" "$DEST"
  echo "✅ Installed. Open System Settings → Screen Saver and pick Rocky."
else
  echo "✅ Built at $SAVER  (re-run with --install to copy into ~/Library/Screen Savers/)"
fi
