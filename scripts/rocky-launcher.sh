#!/bin/bash
# Installs "Start Rocky.app" — a tiny Spotlight-searchable launcher that
# restarts the brew --keep-alive service after you've quit Rocky from the
# menu. Built on demand (not during `brew install`) so nothing lands in
# /Applications uninvited.
#
# The formula installs this file executable (`chmod 0755` at build time, in
# the formula's `install` method), so it's already runnable for every user
# who installs via `brew install rocky` — no per-user chmod needed.
set -e
BREW="${1:?usage: rocky-launcher.sh <path-to-brew> <path-to-libexec>}"
LIBEXEC="${2:?usage: rocky-launcher.sh <path-to-brew> <path-to-libexec>}"
APP="/Applications/Start Rocky.app"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building launcher…"
SRC="$WORK/start-rocky.applescript"
cat > "$SRC" <<APPLESCRIPT
do shell script "$BREW services start rocky"
display notification "Rocky is back, running as a keep-alive service." with title "Start Rocky"
APPLESCRIPT

rm -rf "$APP"
osacompile -o "$APP" "$SRC"

echo "Rendering the app icon (Rocky the Eridian)…"
# Top-level statements only compile from a file literally named main.swift.
cp "$LIBEXEC/render-icon.swift" "$WORK/main.swift"
if xcrun swiftc -O "$LIBEXEC/RockyCore.swift" "$WORK/main.swift" -o "$WORK/render-icon" 2>/dev/null \
  && "$WORK/render-icon" "$WORK/icon.png"; then
  ICONSET="$WORK/StartRocky.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$WORK/icon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z "$sz2" "$sz2" "$WORK/icon.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$WORK/StartRocky.icns"
  cp "$WORK/StartRocky.icns" "$APP/Contents/Resources/applet.icns"

  # osacompile bundles ship an Assets.car asset catalog, and when
  # CFBundleIconName is set macOS prefers that catalog over the loose .icns
  # — so without removing it, the icon swap above is silently ignored.
  # Editing the bundle also invalidates its signature, so re-sign ad-hoc.
  plutil -remove CFBundleIconName "$APP/Contents/Info.plist" 2>/dev/null || true
  rm -f "$APP/Contents/Resources/Assets.car"
  codesign --remove-signature "$APP" 2>/dev/null || true
  codesign -s - --force --deep "$APP" 2>/dev/null || true

  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"
  touch "$APP"
  killall iconservicesagent 2>/dev/null || true
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true
else
  echo "  (icon render failed — Start Rocky.app still works, just with the default script icon)"
fi

echo "Installed \"$APP\" — search Spotlight for \"Start Rocky\" any time you want Rocky back after quitting it."
