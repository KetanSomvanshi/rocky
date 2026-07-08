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
swiftc -O "$SRC/main.swift" -o "$DEST/Rocky"

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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST_EOF

echo "▸ Installing hook script…"
cp "$SRC/rocky-hook.py" "$DEST/rocky-hook.py"
chmod +x "$DEST/rocky-hook.py"

echo "▸ Wiring Claude Code hooks into settings.json (merge, idempotent)…"
python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd = "python3 ~/.claude/rocky/rocky-hook.py"
events = ["UserPromptSubmit","PreToolUse","PostToolUse","Stop",
          "Notification","SessionStart","SessionEnd","PreCompact"]
try:
    with open(path) as f: cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
entry = {"type":"command","command":cmd,"async":True,"timeout":10}

def has_rocky(groups):
    for g in groups:
        for h in g.get("hooks", []):
            if h.get("command","").endswith("rocky-hook.py") or "rocky-hook.py" in h.get("command",""):
                return True
    return False

for ev in events:
    groups = hooks.setdefault(ev, [])
    if has_rocky(groups):
        continue
    # Prefer joining an existing wildcard/no-matcher group so we don't
    # duplicate a matcher; otherwise add our own group.
    target = next((g for g in groups if g.get("matcher") in (None,"*","")), None)
    if target is None:
        target = {"hooks": []}
        # keep the same matcher style Claude Island uses for tool events
        if ev in ("PreToolUse","PostToolUse","Notification"):
            target["matcher"] = "*"
        groups.append(target)
    target.setdefault("hooks", []).append(dict(entry))

with open(path,"w") as f:
    json.dump(cfg, f, indent=2)
print("  hooks wired for:", ", ".join(events))
PY

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
launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$PLIST"
launchctl kickstart -k "gui/$UID_N/$LABEL" 2>/dev/null || true

echo "✅ Rocky installed and running."
echo "   Open a new Claude Code session (or /hooks to reload) so the hooks take effect."
