# mush_windows

Shared window chrome (drag, resize, minimize/maximize/close, edge-snapping)
for other MUSHclient plugins in this set, plus a small **Windows** list for
switching between them.

## Install

1. MUSHclient → **File → Plugins... → Add**
2. Select `mush_windows.xml`
3. **Close**

Keep `winframe.lua` next to `mush_windows.xml` — it loads automatically.

Install this **before** any plugin that depends on it (e.g. OertheMap,
OertheInventory).

## Windows list

- Click a window's name to bring it to the front.
- Click the **x** next to a name to hide that window.
- Every window also gets a close (**X**) button — closing hides, it
  doesn't destroy.
- Type `wf_windows` to bring the list back if you close it.
