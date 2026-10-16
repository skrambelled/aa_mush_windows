# mush_windows

Shared window chrome (drag, resize, minimize/maximize/close, edge-snapping)
for other MUSHclient plugins in this set, plus a **Windows** menu (Ctrl+Shift+W)
for showing and hiding them.

## Install

1. MUSHclient → **File → Plugins... → Add**
2. Select `mush_windows.xml`
3. **Close**

Keep `winframe.lua` next to `mush_windows.xml` — it loads automatically.

Install this **before** any plugin that depends on it (e.g. OertheMap,
OertheInventory).

## Windows menu

Press **Ctrl+Shift+W** (or type `wf_windows`) to pop up a menu of every
plugin window.

- A check mark means the window is showing.
- Pick a window to hide it if it's showing, or bring it back if it's hidden.
- **Show all** / **Hide all** act on every window at once.
- Every window's close (**X**) button hides it; it doesn't destroy it.

## Prompt

mush_windows also reads your in-game prompt for the other plugins, so they
only ever depend on mush_windows, never on each other.

- `wf_prompt_setup`: reads your prompt with `prompt settings`. Run it once,
  and again after changing your prompt with `prompt set`. The prompt must
  include `|XCOORD|` and `|YCOORD|`.
- `wf_hide_coords` / `wf_show_coords`: hide or show the coordinate line in
  your output. It's hidden by default.
