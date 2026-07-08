# 🐾 Rocky

A floating pixel-cat desktop pet for Claude Code. Rocky sits on top of your
screen and shows one cat per active Claude Code session, animating to match
what each session is doing — and pings you when one finishes or needs
permission.

Native Swift/AppKit. Single ~180 KB binary, no runtime dependencies, near-zero
CPU when idle.

![states: working · needs-permission · your-turn · asleep](#)

## What it does

- **One cat per session**, stacked in a small always-on-top window, labelled
  with Claude's own session name (its `ai-title`, e.g. `rocky-desktop-pet`),
  falling back to the folder name. Each project gets its own fur colour
  (hashed from its path) so you can tell them apart at a glance.
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

Rocky merges two sources every 0.3s:

```
1. Claude's live session registry  ~/.claude/sessions/<pid>.json
      → the authoritative list of every running session (name, cwd, status).
        This is why ALL sessions appear — no hooks required.

2. Rocky's hook data                ~/.claude/rocky/sessions/<id>.json
      ← rocky-hook.py, fired by Claude Code hook events (async)
      → adds real-time detail: which tool is running, needs-permission,
        your-turn, and the finish/permission alerts.
```

Hooks run with `"async": true`, so they add zero latency to Claude's turns, and
if Rocky isn't running they're harmless no-ops. A session shows up the moment
it's running (from the registry); hooks just make its status richer.

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

- **Warp**: Rocky opens the session's `WARP_FOCUS_URL`
  (`warp://session/<uuid>`), which Warp exports in every session's
  environment — it jumps to the exact tab. No permissions, no config.
- **iTerm2 / Terminal.app**: fully scriptable — Rocky selects the exact tab by
  tty.

## Which sessions show up

**Every running Claude Code session appears automatically** — Rocky reads
Claude's live session registry (`~/.claude/sessions/`), so it doesn't depend on
hooks firing. Sessions stay listed as long as their process is alive (even when
idle) and drop off when they exit. Hooks aren't needed for a session to appear;
they only enrich its status (tool names, needs-permission, your-turn alerts).

## Notes / limitations

- Logs: `/tmp/rocky.log`.
