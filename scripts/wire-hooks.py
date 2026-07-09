#!/usr/bin/env python3
"""Wire (or unwire) Rocky's Claude Code hooks into ~/.claude/settings.json.

Usage:
    wire-hooks.py wire   "<hook-command>"   # merge Rocky's hooks in (idempotent)
    wire-hooks.py unwire                     # remove Rocky's hooks

<hook-command> is whatever should run for each event, e.g.
    "python3 /opt/homebrew/opt/rocky/libexec/rocky-hook.py"

The merge is idempotent and non-destructive: existing hooks (including other
tools like Claude Island) are preserved. Rocky is identified by the
"rocky-hook.py" substring in a hook command.
"""
import json
import os
import sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
          "Notification", "SessionStart", "SessionEnd", "PreCompact"]
MATCHER_EVENTS = {"PreToolUse", "PostToolUse", "Notification"}


def is_rocky(hook):
    return "rocky-hook.py" in hook.get("command", "")


def group_has_rocky(groups):
    return any(is_rocky(h) for g in groups for h in g.get("hooks", []))


def load():
    try:
        with open(SETTINGS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save(cfg):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w") as f:
        json.dump(cfg, f, indent=2)


def wire(cmd):
    cfg = load()
    hooks = cfg.setdefault("hooks", {})
    entry = {"type": "command", "command": cmd, "async": True, "timeout": 10}
    for ev in EVENTS:
        groups = hooks.setdefault(ev, [])
        if group_has_rocky(groups):
            continue
        # Prefer an existing wildcard/no-matcher group so we don't duplicate a
        # matcher; otherwise add our own group.
        target = next((g for g in groups if g.get("matcher") in (None, "*", "")), None)
        if target is None:
            target = {"hooks": []}
            if ev in MATCHER_EVENTS:
                target["matcher"] = "*"
            groups.append(target)
        target.setdefault("hooks", []).append(dict(entry))
    save(cfg)
    print("  Rocky hooks wired for:", ", ".join(EVENTS))


def unwire():
    cfg = load()
    hooks = cfg.get("hooks", {})
    for ev in list(hooks.keys()):
        groups = hooks[ev]
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if not is_rocky(h)]
        hooks[ev] = [g for g in groups if g.get("hooks")]
        if not hooks[ev]:
            del hooks[ev]
    save(cfg)
    print("  Rocky hooks removed.")


def main():
    args = sys.argv[1:]
    if args and args[0] == "wire" and len(args) >= 2:
        wire(args[1])
    elif args and args[0] == "unwire":
        unwire()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
