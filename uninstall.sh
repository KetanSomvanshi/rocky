#!/usr/bin/env bash
# Remove Rocky: stops the agent, deletes installed files, and strips the
# rocky-hook.py hooks from settings.json (leaving all other hooks intact).
set -euo pipefail

LABEL="com.ketan.rocky"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
UID_N="$(id -u)"

launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/.claude/rocky"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f: cfg = json.load(f)
for ev, groups in list(cfg.get("hooks", {}).items()):
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if "rocky-hook.py" not in h.get("command","")]
    cfg["hooks"][ev] = [g for g in groups if g.get("hooks")]
with open(path,"w") as f: json.dump(cfg, f, indent=2)
print("stripped rocky hooks from settings.json")
PY
fi
echo "✅ Rocky uninstalled."
