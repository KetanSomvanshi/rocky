# 🐾 Rocky

A floating pixel-cat desktop pet for Claude Code. Rocky sits on top of your
screen and shows one cat per active Claude Code session, animating to match
what each session is doing — and pings you when one finishes or needs
permission.

Native Swift/AppKit. Single ~180 KB binary, no runtime dependencies, near-zero
CPU when idle.

![states: working · needs-permission · your-turn · asleep](#)

## What it does

- **One hero pet** (a ginger cat named Rocky) sits on your screen and animates
  with your overall mood — priority order: needs-permission › your-turn ›
  working › idle. A small badge shows the session count, turning red/green when
  a session needs you.
- **Moods**:
  - walking/bobbing tail while Claude is working
  - happy bounce when a session finishes ("your turn")
  - red shake when a session needs permission
  - curls up asleep with a `z` when everything's idle
- **Click the pet** to reveal the **session tabs** — one row per running
  session with a colour-coded status dot (🔴 needs permission · 🟢 your turn ·
  🔵 working · ⚪ idle), its name, and status. Click a tab to jump straight to
  that session's terminal tab. Click the pet again to collapse.
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
| Move the window | drag the pet anywhere (position is remembered) |
| Show / hide session tabs | click the pet |
| Jump to a session | click its tab |
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
