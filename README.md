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
- **Alerts** when a session finishes or needs permission: the cat's row
  pulses with a colored glow (green = done, red = needs permission) and a
  sound plays — all in Rocky itself, no macOS toast/banner. Nothing fires for
  routine tool calls.

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
| Collapse / expand | click anywhere on the header bar (or the ▾ pill) |
| Jump to a session | click its cat |
| Launch at login | right-click → Launch at Login |
| Quit | right-click → Quit Rocky |

The window is a non-activating panel: clicking it never steals keyboard focus
from your terminal, and clicks register on the first try.

## Uninstall

```bash
./uninstall.sh
```

Stops the agent, deletes `~/.claude/rocky/`, and removes only Rocky's hooks
from `settings.json`.

## Clicking a cat → the right terminal tab

- **iTerm2 / Terminal.app**: fully scriptable — Rocky selects the exact tab by
  tty. Works out of the box.
- **Warp**: Warp has no scripting API and no way to focus an existing tab via
  URL scheme, so Rocky drives it through the macOS **Accessibility API**: it
  finds the tab whose title matches the project and presses it. This requires a
  one-time grant:
  **System Settings → Privacy & Security → Accessibility → enable Rocky.**
  The first time you click a cat, macOS prompts for this. Until it's granted
  (or if Warp doesn't surface the tab in its accessibility tree), clicking just
  activates Warp. Tab matching is by title, so it's most reliable when each
  session's tab title contains the project/folder name.

## Notes / limitations

- Session files are pruned automatically when a session ends, its process dies,
  or it goes stale (>15 min with no events).
- Logs: `/tmp/rocky.log`.
