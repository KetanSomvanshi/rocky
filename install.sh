#!/usr/bin/env bash
# Rocky installer — compiles the pet, installs it as a login agent, and wires
# the Claude Code hooks. Safe to re-run: every step is idempotent.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/rocky"
APP="$DEST/Rocky.app"
LABEL="com.ketan.rocky"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"

echo "▸ Compiling Rocky…"
mkdir -p "$DEST/sessions"
swiftc -O "$SRC/RockyCore.swift" "$SRC/main.swift" -o "$DEST/Rocky"

echo "▸ Building app bundle…"
mkdir -p "$APP/Contents/MacOS"
cp "$DEST/Rocky" "$APP/Contents/MacOS/Rocky"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Rocky</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Rocky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST_EOF

echo "▸ Installing hook script…"
cp "$SRC/rocky-hook.py" "$DEST/rocky-hook.py"
chmod +x "$DEST/rocky-hook.py"

echo "▸ Wiring Claude Code hooks into settings.json (merge, idempotent)…"
python3 "$SRC/scripts/wire-hooks.py" wire "python3 $DEST/rocky-hook.py"

echo "▸ Writing LaunchAgent ($PLIST)…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/Rocky</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardErrorPath</key><string>/tmp/rocky.log</string>
  <key>StandardOutPath</key><string>/tmp/rocky.log</string>
</dict></plist>
PLIST_EOF

echo "▸ (Re)loading agent…"
UID_N="$(id -u)"
# Best-effort reload: bootout can race with bootstrap and return a transient
# I/O error, so pause between them and never let it abort the installer.
launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_N/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--with-screensaver" ]]; then
  echo "▸ Building & installing the Rocky screen saver…"
  bash "$SRC/screensaver/build.sh" --install
fi

echo "✅ Rocky installed and running."
echo "   Open a new Claude Code session (or /hooks to reload) so the hooks take effect."
[[ "${1:-}" == "--with-screensaver" ]] && echo "   Screen saver installed — pick Rocky in System Settings → Screen Saver."
