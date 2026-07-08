# 🐾 Rocky

A floating pixel-cat desktop pet for Claude Code. Rocky sits on top of your
screen and shows one cat per active Claude Code session, animating to match
what each session is doing — and pings you when one finishes or needs
permission.

Native Swift/AppKit. Single ~180 KB binary, no runtime dependencies, near-zero
CPU when idle.

![states: working · needs-permission · your-turn · asleep](#)

## What it does

- **One cat per session**, stacked in a small always-on-top window. Each
  project gets its own fur colour (hashed from its path) so you can tell them
  apart at a glance.
- **Moods** driven by live session state:
  - walking/bobbing tail while Claude is working
  - happy bounce + "✅ your turn" when a session finishes
  - red shake + 🔒 accent bar when a session needs permission
  - curls up asleep with a `z` when idle for a few minutes
- **Click a cat** to jump to its terminal. That session then drops out of the
  "needs attention" spot back into the calm stack.
- **Collapse** (chevron top-right, or right-click → Collapse) to show only the
  session that currently wants you.
- **Notifications** (banner + sound) when a session finishes or needs
  permission — nothing for routine tool calls.

## Install

```bash
cd ~/ks/rocky
./install.sh
```

This compiles Rocky, installs it to `~/.claude/rocky/`, sets it to launch at
login (a `launchd` agent), and wires the Claude Code hooks into
`~/.claude/settings.json` (merged — your existing hooks, including Claude
Island, are left untouched). Open a fresh Claude Code session, or run `/hooks`
in an existing one, so the hooks load.

## How it works

```
Claude Code hook events (async)
  → ~/.claude/rocky/rocky-hook.py        writes one JSON file per session
  → ~/.claude/rocky/sessions/<id>.json
  → Rocky.app polls that folder (0.3s)   animates the cats + fires notifications
```

Hooks run with `"async": true`, so they add zero latency to Claude's turns. If
Rocky ever isn't running, the hooks are harmless no-ops.

## Controls

| Action | How |
|---|---|
| Move the window | drag it anywhere (position is remembered) |
| Collapse / expand | chevron top-right, or right-click menu |
| Jump to a session | click its cat |
| Launch at login | right-click → Launch at Login |
| Quit | right-click → Quit Rocky |

## Uninstall

```bash
./uninstall.sh
```

Stops the agent, deletes `~/.claude/rocky/`, and removes only Rocky's hooks
from `settings.json`.

## Notes / limitations

- **Warp**: clicking a cat activates Warp but can't select the exact tab —
  Warp has no per-tab AppleScript API. iTerm2 and Terminal.app select the exact
  tab by tty.
- Session files are pruned automatically when a session ends, its process dies,
  or it goes stale (>15 min with no events).
- Logs: `/tmp/rocky.log`.
