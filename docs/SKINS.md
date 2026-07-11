# Skins

Rocky's hero pet is a **skin**: a pixel map plus a small draw routine. Two ship
today — the Classic Cat and **Rocky the Eridian** (*Project Hail Mary*) — and
adding a third is deliberately easy: the sprite is plain text, and everything
around it (mood motion, the typing keyboard, the padlock, sizing, the screen
saver) is shared.

Pick a skin from the right-click menu → **Skin**. The choice persists in
`UserDefaults` and is mirrored to `~/.claude/rocky/skin` so the sandboxed
screen saver follows it too.

## Anatomy of a skin

Everything lives in `RockyCore.swift`:

1. **`Skin`** — the enum users pick from. A new skin is a new case + label.
2. **A pixel map** — a text grid, one character per cell:

   ```swift
   // '.' transparent · 'o' outline · 'b' body(tint) · 'l' belly · 'p' pink · 'e' eye slot
   static let map = [
       "...oo.....oo.",
       "..obbo...obbo",
       ...
   ]
   ```

   The legend is per-skin (the Eridian uses `r` rock, `d` crack, `h` highlight
   instead of fur colours). Keep the grid inside the shared **13×13 budget**
   so all skins sit at the same scale in the panel and the saver.

3. **A draw routine** — `drawClassic` / `drawEridian` are the templates. A
   skin's routine renders the map and any animated parts (the cat's tail and
   stepping paws; the Eridian's five scuttling legs), and must:
   - honour the shared **mood motion** (bounce when happy, shake on alert,
     bob while working, slow breathing asleep, the wake stretch) so a mood
     reads the same whatever the skin;
   - end with `drawMoodProps(...)` — the typing keyboard and the padlock are
     the *signal*, and every skin shows them;
   - assume a **flipped** coordinate system (y grows downward), like both
     views that call it.

4. **Dispatch** — add your case to the `switch skin` in `Cat.draw`.

## Design notes

- Moods must read at 40×40 px from across a room. Whole-body motion + props
  carry most of it; faces are a bonus (the Eridian has no eyes at all and
  emotes with leg posture and musical notes).
- The panel and the space scene both sit on dark backgrounds — avoid
  near-black fills for load-bearing shapes.
- `tint` is passed in (the signature ginger); a skin may use it (cat fur,
  the Eridian's happy-chord notes) or keep a fixed palette (stone carapace).
- Check every mood: idle, working, happy, alert, sleeping — plus the
  screen saver, where the skin wears the space helmet.

## Why "Rocky the Eridian"?

The app is named Rocky. So is the eyeless, rock-carapaced, five-legged
engineer from *Project Hail Mary* who watches over a sleeping human and wakes
him when something needs attention. It was never really a choice. *Amaze.* ♪
