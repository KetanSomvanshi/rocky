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

# Compile the shared core + the saver view into a universal loadable bundle
# (MH_BUNDLE, arm64 + x86_64) so it runs on Apple Silicon and Intel.
SRCS=("$ROOT/RockyCore.swift" "$HERE/RockySaverView.swift")
for arch in arm64 x86_64; do
  xcrun swiftc -O \
    -target "$arch-apple-macos12.0" \
    -module-name RockySaver \
    -framework ScreenSaver \
    -emit-library -Xlinker -bundle \
    -o "$MACOS/Rocky.$arch" \
    "${SRCS[@]}"
done
lipo -create "$MACOS/Rocky.arm64" "$MACOS/Rocky.x86_64" -output "$MACOS/Rocky"
rm -f "$MACOS/Rocky.arm64" "$MACOS/Rocky.x86_64"

file "$MACOS/Rocky"
lipo -info "$MACOS/Rocky"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Library/Screen Savers/Rocky.saver"
  echo "▸ Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$SAVER" "$DEST"
  echo "✅ Installed. Open System Settings → Screen Saver and pick Rocky."
else
  echo "✅ Built at $SAVER  (re-run with --install to copy into ~/Library/Screen Savers/)"
fi
