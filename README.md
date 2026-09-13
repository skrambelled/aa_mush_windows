# mush_windows — shared window chrome for MUSHclient plugins

mush_windows is a MUSHclient plugin whose main job is to be a stable,
shared place for `winframe.lua` — a reusable "OS-style" miniwindow
module (draggable title bar, resize from any edge or corner,
minimize/maximize/close, persisted position/size, click-to-front,
edge-snapping while dragging) — to live on disk, so any other plugin
that wants a resizable window can depend on this one instead of
bundling its own copy.

It also hosts one small window of its own: a **Windows** list. Every
window created by any plugin using `winframe.lua` (OertheMap's map,
OertheInventory's inventory panel, etc.) shows up there by name.

- Click a window's name in the list to bring it to the front — this
  also un-minimizes it and un-hides it if it was closed.
- Click the small **x** next to a name to hide that window.
- Every winframe-based window also gets a close (**X**) button in its
  own title bar now, alongside minimize/maximize — closing a window
  hides it, it does not destroy it or lose its state; bring it back
  from the Windows list.
- If you ever close the Windows list itself, type `wf_windows` to bring
  it back.

## Installation

1. In MUSHclient, open the world you want these plugins active on.
2. Go to **File → Plugins...**
3. Click **Add**.
4. Select `mush_windows.xml` from wherever you saved this plugin's
   folder.
5. Click **Close**.

Keep `winframe.lua` in the same folder as `mush_windows.xml` — any
plugin depending on this one loads it from here automatically. You
don't need to do anything else with it.

Install this **before** (or alongside) any plugin that depends on it
(e.g. OertheMap) — a dependent plugin checks for this one by a fixed ID
when it starts up and will tell you plainly if it's missing.

Plugins are added per-world in MUSHclient. If you connect through more
than one saved world file, repeat the install step for each one.

## For plugin authors: depending on this plugin

See the comment block at the top of `mush_windows.xml` for the full
pattern (hardcoded plugin ID + `IsPluginInstalled`, MUSHclient's own
sanctioned way for one plugin to depend on another), and `winframe.lua`'s
own header comment for the window API itself. `OertheMap.xml` (in the
`oerthe_map` plugin) is a complete real example of a consumer.
