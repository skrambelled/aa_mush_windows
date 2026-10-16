--[[
winframe.lua -- reusable "OS-style" miniwindow chrome for MUSHclient plugins.

Gives any plugin a draggable title bar, resize from any edge or corner,
minimize/maximize buttons, a raised 3D border, a live size-preview while
resizing, and persisted position/size -- without that plugin needing to
reimplement any of it.

This module owns the CHROME (border, title bar, resize/drag hotspots,
min/max buttons). It knows nothing about what you draw inside the content
area -- that's entirely up to you, via the on_draw/on_resize callbacks.

This file lives in the mush_windows plugin, not in your own plugin's
directory -- every plugin that wants a window depends on mush_windows
being installed, and pulls this file in via loadfile() so it runs inside
your OWN plugin's Lua state (MUSHclient plugins are separate Lua VMs;
CallPlugin can only pass plain nil/boolean/number/string between them,
not functions or tables, so a shared module has to be loaded as source
into each consumer rather than "called into" like a service). See
mush_windows.xml's own comments for the dependency-check pattern
(hardcoded plugin GUID + IsPluginInstalled), and OertheMap.xml for a
complete real usage example of a plugin depending on it.

USAGE (from any plugin's own Lua script):

    local WINDOWS_PLUGIN_ID = "26a4ca2758d503d86efe902e"  -- mush_windows
    local winframe_path = GetPluginInfo(WINDOWS_PLUGIN_ID, 20) .. "winframe.lua"
    local winframe = assert(loadfile(winframe_path))()

    local win = winframe.new{
      id = "my_plugin_window",       -- must be unique across every plugin
                                      -- using winframe at the same time --
                                      -- e.g. prefix it with your own
                                      -- plugin's name, since two plugin
                                      -- authors won't otherwise coordinate
      title = "My Window",
      min_content_w = 100,
      min_content_h = 60,
      default_content_w = 300,
      default_content_h = 200,

      -- Called once after any resize/maximize/restore settles (not during
      -- a live drag). Recompute whatever your own layout needs here.
      on_resize = function(contentW, contentH)
        -- e.g. columns = math.floor(contentW / char_width)
      end,

      -- Called whenever the content needs a full repaint. Draw using
      -- win.win as the miniwindow name (e.g. WindowText(win.win, ...)).
      -- Content area starts at (0, win:contentTop()) and is
      -- contentW x contentH pixels.
      on_draw = function(contentW, contentH)
      end,

      -- Optional: called cheaply and often during a live resize drag, to
      -- get a short label shown centered over the window (e.g. "25x18").
      -- Must NOT do a full redraw -- just compute and return a string.
      preview_label = function(contentW, contentH)
        return contentW .. " x " .. contentH
      end,

      -- Optional: called after every redraw, once winframe has finished
      -- setting up its own chrome hotspots (drag/resize/buttons). Add your
      -- own hotspots here (e.g. WindowAddHotspot(win.win, ...) for a
      -- mouseover tooltip on some detail) -- winframe won't touch them
      -- again until the next redraw, when it clears and rebuilds everyone's
      -- hotspots from scratch.
      on_hotspots = function(contentW, contentH)
      end,
    }

    win:show()
    -- ... later, whenever your underlying data changes:
    win:redraw()

    -- During your OWN live drag inside the content area (e.g. panning),
    -- call win:repaintContent() on every move instead of win:redraw() --
    -- redraw() rebuilds every hotspot, which would delete the hotspot your
    -- drag is currently tracked on and silently end the drag. Then call
    -- win:redraw() (or just win:setupHotspots()) once on drag release.

    -- winframe raises a window to the front automatically for its own
    -- chrome interactions (title-bar drag, resize, min/max). If your
    -- content area has its own clickable hotspots (e.g. a pan/zoom
    -- surface), call win:bringToFront() from your own mouse-down handler
    -- too, so clicking into content also raises the window over any
    -- other overlapping window -- winframe has no way to see clicks on
    -- hotspots it didn't create itself.

    -- The chrome's close (X) button calls win:hide() -- it hides, it does
    -- NOT destroy. Every window (from every plugin) shows up in the shared
    -- "Windows" menu mush_windows itself hosts (Ctrl+Shift+W); picking an
    -- entry there brings that window back (calls back into THIS plugin's WinframeActivate,
    -- a dispatcher this file installs for you) regardless of which plugin
    -- created it. You don't need to build your own show/hide command for
    -- this specifically, though one doesn't hurt as a fallback.

See OertheMap.xml for a complete real usage example.
--]]

local winframe = {}
winframe.__index = winframe

-- winframe.lua only ever ships inside the mush_windows plugin (see the
-- header above), so it's safe to hardcode mush_windows' own plugin id here
-- for the cross-plugin geometry registry (used for window-snapping) below --
-- every consumer already depends on this exact id being mush_windows.
local WINDOWS_PLUGIN_ID = "26a4ca2758d503d86efe902e"

local ABSOLUTE_LOCATION = 2   -- WindowCreate/WindowPosition flag bit

local TITLEBAR_H = 20
local TITLEBAR_BG = 0x3C3C3C
local TITLE_TEXT_COLOUR = 0xFFFFFF
local TITLE_FONT_SIZE = 10
local TITLE_FONT_NAME = "Courier New"

local BTN_SIZE = 16
local BTN_GAP = 2
local BTN_COLOUR = 0xDDDDDD
local BTN_HOVER_BG = 0x555555

local BORDER_ACTION = 5              -- WindowRectOp action: draw_edge
local BORDER_TYPE_RAISED = 5         -- Win32 EDGE_RAISED (coincidentally also numeric 5, but a separate parameter)
local BORDER_ALL_SOFT = 15 + 0x1000  -- BF_LEFT|TOP|RIGHT|BOTTOM, plus BF_SOFT for soft corners

local CORNER_PX = 12   -- size of each corner resize hotspot
local EDGE_PX = 6       -- thickness of each edge resize strip

local PREVIEW_BG = 0x000000
local PREVIEW_TEXT_COLOUR = 0xFFFF00

-- direction each resize handle affects: dx/dy of -1 means that edge is the
-- LEFT/TOP one (the opposite edge stays anchored, so position shifts too)
local RESIZE_DIRS = {
  edge_n    = { dx =  0, dy = -1, cursor_field = "cursor_ns_arrow" },
  edge_s    = { dx =  0, dy =  1, cursor_field = "cursor_ns_arrow" },
  edge_e    = { dx =  1, dy =  0, cursor_field = "cursor_ew_arrow" },
  edge_w    = { dx = -1, dy =  0, cursor_field = "cursor_ew_arrow" },
  corner_ne = { dx =  1, dy = -1, cursor_field = "cursor_ne_sw_arrow" },
  corner_nw = { dx = -1, dy = -1, cursor_field = "cursor_nw_se_arrow" },
  corner_se = { dx =  1, dy =  1, cursor_field = "cursor_nw_se_arrow" },
  corner_sw = { dx = -1, dy =  1, cursor_field = "cursor_ne_sw_arrow" },
}

local SNAP_PX = 8   -- max gap (px) an edge can be from a target and still snap to it

local instances = {}  -- id -> winframe instance, for the shared dispatchers below

-- Hotspot ids are "<instance id>|<handle>" so a small, fixed set of global
-- dispatcher functions (MUSHclient calls these by name) can find the right
-- instance and delegate to it, regardless of how many windows exist.
local function parseHotspotId(hotspotId)
  local id, handle = hotspotId:match("^(.-)|(.+)$")
  return instances[id], handle
end

-- ---------------------------------------------------------------------------
-- Geometry helpers
-- ---------------------------------------------------------------------------

function winframe:totalHeight()
  if self.minimized then return TITLEBAR_H end
  return TITLEBAR_H + self.content_h
end

function winframe:totalWidth()
  return self.content_w
end

function winframe:contentTop()
  return TITLEBAR_H
end

-- ---------------------------------------------------------------------------
-- Cross-plugin geometry registry (used for window snapping AND the shared
-- Windows menu mush_windows itself hosts)
--
-- mush_windows.xml keeps a small id -> record table and exposes it via
-- CallPlugin (WF_Registry_Update/Remove/Get), since that's the one place
-- able to see every plugin's windows at once -- each consumer plugin runs
-- winframe.lua in its own separate Lua VM and has no other way to find out
-- what any OTHER plugin's window looks like. CallPlugin can only carry
-- plain nil/boolean/number/string, so geometry crosses the boundary
-- packed into delimited strings, not tables.
-- ---------------------------------------------------------------------------

-- Wrapped in pcall: a registry hiccup should never break dragging itself,
-- only the (purely cosmetic) snapping/menu-listing built on top of it.
-- Title/owner/visibility ride along too (not just geometry) so mush_windows'
-- Windows menu can list every window and know which plugin to call back
-- into (WinframeActivate/WinframeHide, below) for a given entry.
function winframe:syncGeometry()
  pcall(CallPlugin, WINDOWS_PLUGIN_ID, "WF_Registry_Update",
    self.id, self.left, self.top, self:totalWidth(), self:totalHeight(),
    self.title, GetPluginID(), not self.hidden)
end

function winframe:unregisterGeometry()
  pcall(CallPlugin, WINDOWS_PLUGIN_ID, "WF_Registry_Remove", self.id)
end

-- Snapshot of every OTHER window's rect right now, as {left,top,right,bottom}
-- entries. Taken once per drag gesture (not on every move tick) since it's a
-- cross-plugin call; a window that itself moves mid-drag just means we snap
-- against where it was when this drag started, which is an acceptable
-- trade-off for not doing a CallPlugin round trip on every mouse-move.
function winframe:fetchOtherRects()
  local ok, raw = pcall(CallPlugin, WINDOWS_PLUGIN_ID, "WF_Registry_Get", self.id)
  local rects = {}
  if not ok or type(raw) ~= "string" or raw == "" then return rects end
  for segment in raw:gmatch("[^|]+") do
    local left, top, w, h = segment:match(":(-?%d+),(-?%d+),(%d+),(%d+)$")
    if left then
      left, top, w, h = tonumber(left), tonumber(top), tonumber(w), tonumber(h)
      rects[#rects + 1] = { left = left, top = top, right = left + w, bottom = top + h }
    end
  end
  return rects
end

local function rangesOverlap(aMin, aMax, bMin, bMax)
  return aMin <= bMax and bMin <= aMax
end

-- Finds the smallest x/y shift (each independently, each within SNAP_PX)
-- that lines up one of our edges with a target edge -- other windows' edges
-- (only when our other axis' range actually overlaps theirs, so we don't
-- snap sideways to some window nowhere near us vertically) plus the four
-- screen edges (always considered). Returns 0, 0 when nothing is close
-- enough to snap to.
local function computeSnap(rects, myLeft, myTop, myW, myH, screenW, screenH)
  local myRight, myBottom = myLeft + myW, myTop + myH
  local bestDX, bestDXAbs = 0, SNAP_PX + 1
  local bestDY, bestDYAbs = 0, SNAP_PX + 1

  local function tryX(edge, target)
    local d = target - edge
    if math.abs(d) < bestDXAbs then bestDX, bestDXAbs = d, math.abs(d) end
  end
  local function tryY(edge, target)
    local d = target - edge
    if math.abs(d) < bestDYAbs then bestDY, bestDYAbs = d, math.abs(d) end
  end

  tryX(myLeft, 0); tryX(myRight, screenW)
  tryY(myTop, 0); tryY(myBottom, screenH)

  for _, r in ipairs(rects) do
    if rangesOverlap(myTop, myBottom, r.top, r.bottom) then
      tryX(myLeft, r.left);  tryX(myLeft, r.right)
      tryX(myRight, r.left); tryX(myRight, r.right)
    end
    if rangesOverlap(myLeft, myRight, r.left, r.right) then
      tryY(myTop, r.top);    tryY(myTop, r.bottom)
      tryY(myBottom, r.top); tryY(myBottom, r.bottom)
    end
  end

  if bestDXAbs > SNAP_PX then bestDX = 0 end
  if bestDYAbs > SNAP_PX then bestDY = 0 end
  return bestDX, bestDY
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function winframe:save()
  SetVariable("wf_" .. self.id .. "_left", tostring(self.left))
  SetVariable("wf_" .. self.id .. "_top", tostring(self.top))
  SetVariable("wf_" .. self.id .. "_cw", tostring(self.content_w))
  SetVariable("wf_" .. self.id .. "_ch", tostring(self.content_h))
end

-- ---------------------------------------------------------------------------
-- Z-order
-- ---------------------------------------------------------------------------

-- Raises this window above every other miniwindow (from any plugin --
-- WindowSetZOrder's ordering is global to the whole output frame, not
-- per-plugin). os.clock() is a process-wide wall clock in MUSHclient's Lua
-- (already relied on elsewhere in this file, see :throttled() below), so
-- it stays a valid "most recently touched" ordering even when compared
-- against a value some OTHER plugin's completely separate Lua state read
-- at a different time -- unlike a plain per-instance counter, which would
-- only be comparable within one plugin's own windows.
function winframe:bringToFront()
  WindowSetZOrder(self.win, math.floor(os.clock() * 1000))
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local function drawButtonGlyph(self, kind, l, t)
  -- Minimal glyphs drawn with plain rectangles/lines, so no extra fonts/
  -- symbols are needed: minimize = underscore-like bar near the bottom of
  -- the button; maximize = an outlined square; restore = two overlapping
  -- outlined squares; close = an X.
  local r, b = l + BTN_SIZE, t + BTN_SIZE
  if kind == "min" then
    WindowRectOp(self.win, 2, l + 3, b - 5, r - 3, b - 3, BTN_COLOUR, 0)
  elseif kind == "max" then
    WindowRectOp(self.win, 1, l + 3, t + 3, r - 3, b - 3, BTN_COLOUR, 0)
  elseif kind == "restore" then
    WindowRectOp(self.win, 1, l + 5, t + 3, r - 3, b - 5, BTN_COLOUR, 0)
    WindowRectOp(self.win, 1, l + 3, t + 5, r - 5, b - 3, BTN_COLOUR, 0)
  elseif kind == "close" then
    WindowLine(self.win, l + 3, t + 3, r - 3, b - 3, BTN_COLOUR, miniwin.pen_solid, 2)
    WindowLine(self.win, l + 3, b - 3, r - 3, t + 3, BTN_COLOUR, miniwin.pen_solid, 2)
  end
end

function winframe:drawChrome()
  local w = self:totalWidth()
  local h = self:totalHeight()

  WindowRectOp(self.win, 2, 0, 0, w, TITLEBAR_H, TITLEBAR_BG, 0)
  WindowText(self.win, self.titleFontId, self.title, 6, 2, w, TITLEBAR_H, TITLE_TEXT_COLOUR, false)

  -- Right to left: close (outermost), then maximize/restore, then minimize
  -- -- the usual desktop ordering.
  local bx = w - BTN_GAP - BTN_SIZE
  drawButtonGlyph(self, "close", bx, 2)
  bx = bx - BTN_GAP - BTN_SIZE
  drawButtonGlyph(self, self.maximized and "restore" or "max", bx, 2)
  bx = bx - BTN_GAP - BTN_SIZE
  drawButtonGlyph(self, "min", bx, 2)

  WindowRectOp(self.win, BORDER_ACTION, 0, 0, 0, 0, BORDER_TYPE_RAISED, BORDER_ALL_SOFT)
end

-- Repaints the bitmap (content + chrome) without touching hotspots. Use
-- this from a live-drag callback (e.g. panning content around inside the
-- window) instead of redraw() -- redraw() calls setupHotspots(), which
-- does WindowDeleteAllHotspots and would delete the very hotspot that
-- WindowDragHandler is currently tracking the drag on, silently ending
-- the drag after one move. Call setupHotspots() once yourself when the
-- drag releases to bring hotspots back in sync with the final content.
--
-- Skips WindowResize whenever the window's total size hasn't actually
-- changed since the last paint. Per MUSHclient's own docs, WindowResize
-- copies the window's *entire* existing bitmap into a freshly allocated
-- one on every call, even when the size passed in is identical to the
-- current size -- so calling it on every tick of a live pan or zoom,
-- where the window's total size never changes, was paying for a
-- full-framebuffer copy dozens of times a second for nothing.
-- self._paintedW/_paintedH track what's actually on the bitmap right
-- now, updated here and by any other code path (e.g. a live resize
-- drag) that calls WindowResize directly.
--
-- drawChrome() (border/title bar/buttons) is NOT part of that cost --
-- it's a handful of constant-size draw calls -- so it always runs, and
-- must: the content clear below touches the outer edge pixels where the
-- border lives, so skipping the border redraw after it would erase the
-- border (this is exactly what happened when that was tried).
function winframe:repaintContent()
  local w, h = self:totalWidth(), self:totalHeight()

  if w ~= self._paintedW or h ~= self._paintedH then
    WindowResize(self.win, w, h, self.bg_colour)
    self._paintedW, self._paintedH = w, h
  end

  WindowRectOp(self.win, 2, 0, 0, w, h, self.bg_colour, 0)

  if not self.minimized and self.on_draw then
    self.on_draw(self.content_w, self.content_h)
  end

  self:drawChrome()
  WindowShow(self.win, true)
end

function winframe:redraw()
  self:repaintContent()
  self:setupHotspots()
end

-- Returns true at most once every minInterval seconds, per (self, key).
-- For capping how often an expensive live-drag callback actually does
-- its work, independent of how often the underlying mouse-move events
-- fire -- which can vastly outpace what's worth redrawing, e.g. content
-- with more, smaller elements to redraw per event will also cross more
-- of them per pixel of mouse movement, compounding into a burst of
-- expensive redraws for one drag gesture. Pass reset=true (e.g. on
-- mouse-down) so the first move of a new gesture always paints
-- immediately rather than waiting out a stale interval from before.
-- Callers are still responsible for doing one final, accurate repaint
-- on drag release -- this only throttles the live-preview ticks.
function winframe:throttled(key, minInterval, reset)
  self._throttle = self._throttle or {}
  local now = os.clock()
  local last = self._throttle[key]
  if reset or not last or now - last >= minInterval then
    self._throttle[key] = now
    return true
  end
  return false
end

-- Live resize drags a lightweight preview at the live target rect instead
-- of touching the real window at all -- see onMouseDown/onDragMove/
-- onDragRelease's resize branches. WindowResize on the REAL window is a
-- full bitmap copy per MUSHclient's own docs (see repaintContent()'s
-- comment), and doing that on every mouse-move tick while also leaving
-- stale/partially redrawn content on screen in the meantime is what made
-- resizing feel clunky; the real window is now only ever resized once,
-- on release.
--
-- The preview itself is 4 thin separate miniwindows, one per edge (named
-- "<self.win>_resizeGhost_n/s/e/w"), tracing just the outline of the
-- target rect, plus one small one for the size label -- NOT one big
-- window covering the whole target rect. Miniwindows have no real
-- transparency to speak of, so the only reliable way to let whatever's
-- underneath (the window's own old content, another window, the game's
-- own output) show through the middle is to genuinely not put any window
-- there at all, rather than trying to fake see-through with some fill
-- colour.
local GHOST_EDGES = { "n", "s", "e", "w" }
local GHOST_BORDER_PX = 2
local GHOST_BORDER_COLOUR = 0xFFFF00  -- matches PREVIEW_TEXT_COLOUR/showPreview's own border colour

function winframe:ghostWinName(part)
  return self.win .. "_resizeGhost_" .. part
end

function winframe:createResizeGhost()
  for _, edge in ipairs(GHOST_EDGES) do
    WindowCreate(self:ghostWinName(edge), 0, 0, 1, 1, 4, ABSOLUTE_LOCATION, GHOST_BORDER_COLOUR)
  end
  WindowCreate(self:ghostWinName("label"), 0, 0, 1, 1, 4, ABSOLUTE_LOCATION, PREVIEW_BG)
  WindowFont(self:ghostWinName("label"), self.titleFontId, TITLE_FONT_NAME, TITLE_FONT_SIZE, true, false, false, false, 0, 49)
end

function winframe:destroyResizeGhost()
  for _, edge in ipairs(GHOST_EDGES) do
    WindowDelete(self:ghostWinName(edge))
  end
  WindowDelete(self:ghostWinName("label"))
end

function winframe:drawResizeGhost(l, t, w, h, label)
  local bp = GHOST_BORDER_PX
  local edgeRects = {
    n = { l, t, w, bp },
    s = { l, t + h - bp, w, bp },
    w = { l, t, bp, h },
    e = { l + w - bp, t, bp, h },
  }
  for _, edge in ipairs(GHOST_EDGES) do
    local win = self:ghostWinName(edge)
    local rect = edgeRects[edge]
    local pw, ph = math.max(1, rect[3]), math.max(1, rect[4])
    WindowResize(win, pw, ph, GHOST_BORDER_COLOUR)
    WindowPosition(win, rect[1], rect[2], 0, ABSOLUTE_LOCATION)
    WindowSetZOrder(win, math.floor(os.clock() * 1000))
    WindowShow(win, true)
  end

  local labelWin = self:ghostWinName("label")
  if label then
    local tw = #label * 8 + 16
    local th = 20
    local lx = l + math.max(0, math.floor((w - tw) / 2))
    local ly = t + math.max(0, math.floor((h - th) / 2))
    WindowResize(labelWin, tw, th, PREVIEW_BG)
    WindowPosition(labelWin, lx, ly, 0, ABSOLUTE_LOCATION)
    WindowSetZOrder(labelWin, math.floor(os.clock() * 1000))
    WindowRectOp(labelWin, 2, 0, 0, tw, th, PREVIEW_BG, 0)
    WindowRectOp(labelWin, 1, 0, 0, tw, th, PREVIEW_TEXT_COLOUR, 0)
    WindowText(labelWin, self.titleFontId, label, 0, 3, tw, th, PREVIEW_TEXT_COLOUR, false)
    WindowShow(labelWin, true)
  else
    WindowShow(labelWin, false)
  end
end

-- ---------------------------------------------------------------------------
-- Hotspots
-- ---------------------------------------------------------------------------

function winframe:setupHotspots()
  WindowDeleteAllHotspots(self.win)

  local w, h = self:totalWidth(), self:totalHeight()

  local bx = w - BTN_GAP - BTN_SIZE
  WindowAddHotspot(self.win, self.id .. "|btn_close", bx, 2, bx + BTN_SIZE, 2 + BTN_SIZE,
    "", "", "", "", "WinframeOnButtonClick", "Close (hides the window; bring it back with Ctrl+Shift+W)", miniwin.cursor_hand, 0)
  bx = bx - BTN_GAP - BTN_SIZE
  WindowAddHotspot(self.win, self.id .. "|btn_max", bx, 2, bx + BTN_SIZE, 2 + BTN_SIZE,
    "", "", "", "", "WinframeOnButtonClick", "Maximize/restore", miniwin.cursor_hand, 0)
  bx = bx - BTN_GAP - BTN_SIZE
  WindowAddHotspot(self.win, self.id .. "|btn_min", bx, 2, bx + BTN_SIZE, 2 + BTN_SIZE,
    "", "", "", "", "WinframeOnButtonClick", "Minimize", miniwin.cursor_hand, 0)

  if self.minimized or self.maximized then
    -- No free-form resize while minimized/maximized, matching normal
    -- desktop window behaviour; restore first via the buttons.
    WindowAddHotspot(self.win, self.id .. "|zz_drag", 0, 0, 0, TITLEBAR_H,
      "", "", "WinframeOnMouseDown", "", "",
      "Drag to move", miniwin.cursor_hand, 0)
    WindowDragHandler(self.win, self.id .. "|zz_drag", "WinframeOnDragMove", "WinframeOnDragRelease", 0)
    if not self.minimized and self.on_hotspots then
      self.on_hotspots(self.content_w, self.content_h)
    end
    return
  end

  local function addResizeHotspot(handle, l, t, r, b)
    local dir = RESIZE_DIRS[handle]
    local hid = self.id .. "|" .. handle
    WindowAddHotspot(self.win, hid, l, t, r, b,
      "", "", "WinframeOnMouseDown", "", "",
      "Drag to resize", miniwin[dir.cursor_field], 0)
    WindowDragHandler(self.win, hid, "WinframeOnDragMove", "WinframeOnDragRelease", 0)
  end

  addResizeHotspot("corner_nw", 0, 0, CORNER_PX, CORNER_PX)
  addResizeHotspot("corner_ne", w - CORNER_PX, 0, w, CORNER_PX)
  addResizeHotspot("corner_sw", 0, h - CORNER_PX, CORNER_PX, h)
  addResizeHotspot("corner_se", w - CORNER_PX, h - CORNER_PX, w, h)
  addResizeHotspot("edge_n", CORNER_PX, 0, w - CORNER_PX, EDGE_PX)
  addResizeHotspot("edge_s", CORNER_PX, h - EDGE_PX, w - CORNER_PX, h)
  addResizeHotspot("edge_w", 0, CORNER_PX, EDGE_PX, h - CORNER_PX)
  addResizeHotspot("edge_e", w - EDGE_PX, CORNER_PX, w, h - CORNER_PX)

  WindowAddHotspot(self.win, self.id .. "|zz_drag", 0, 0, 0, TITLEBAR_H,
    "", "", "WinframeOnMouseDown", "", "",
    "Drag to move", miniwin.cursor_hand, 0)
  WindowDragHandler(self.win, self.id .. "|zz_drag", "WinframeOnDragMove", "WinframeOnDragRelease", 0)

  if self.on_hotspots then
    self.on_hotspots(self.content_w, self.content_h)
  end
end

-- ---------------------------------------------------------------------------
-- Move / resize drag handling
-- ---------------------------------------------------------------------------

function winframe:applyResize(contentW, contentH, callResize)
  self.content_w = contentW
  self.content_h = contentH
  if callResize and self.on_resize then
    self.on_resize(self.content_w, self.content_h)
  end
end

function winframe:onMouseDown(handle)
  self:bringToFront()

  if handle == "zz_drag" then
    self.dragState = {
      startMouseX = WindowInfo(self.win, 14),
      startMouseY = WindowInfo(self.win, 15),
      -- Snapshot taken once per drag, not re-fetched every move tick --
      -- see fetchOtherRects()'s own comment for why that's an acceptable
      -- trade-off.
      others = self:fetchOtherRects(),
    }
    return
  end

  local dir = RESIZE_DIRS[handle]
  if not dir then return end
  local startW, startH = self:totalWidth(), self:totalHeight()
  self.resizeState = {
    dir = dir,
    -- Pure mouse-movement delta needs BOTH readings relative to the same
    -- fixed frame (the output window), unlike the move-drag trick above
    -- which deliberately mixes frames to get an absolute position.
    startMouseX = WindowInfo(self.win, 17),
    startMouseY = WindowInfo(self.win, 18),
    startW = startW,
    startH = startH,
    startLeft = self.left,
    startTop = self.top,
    -- Updated on every move tick below; onDragRelease reads these back
    -- instead of querying the real window's bitmap size, since the real
    -- window is never touched until release (see drawResizeGhost).
    newW = startW,
    newH = startH,
    newLeft = self.left,
    newTop = self.top,
  }

  self:createResizeGhost()
  self:drawResizeGhost(self.left, self.top, startW, startH)
end

function winframe:onDragMove(handle)
  if handle == "zz_drag" then
    if not self.dragState then return end
    local posx = WindowInfo(self.win, 17) - self.dragState.startMouseX
    local posy = WindowInfo(self.win, 18) - self.dragState.startMouseY

    local screenW, screenH = GetInfo(281), GetInfo(280)
    local dx, dy = computeSnap(self.dragState.others, posx, posy,
      self:totalWidth(), self:totalHeight(), screenW, screenH)
    posx, posy = posx + dx, posy + dy

    local maxX = screenW - 20
    local maxY = screenH - 20
    if posx < 0 then posx = 0 elseif posx > maxX then posx = maxX end
    if posy < 0 then posy = 0 elseif posy > maxY then posy = maxY end
    SetCursor(miniwin.cursor_hand)
    WindowPosition(self.win, posx, posy, 0, ABSOLUTE_LOCATION)
    self.left, self.top = posx, posy

    -- Throttled like the repaint-during-drag pattern elsewhere in this
    -- file: keeps other plugins' snap targets reasonably fresh without a
    -- CallPlugin round trip on every single mouse-move tick.
    if self:throttled("wf_registry_sync", 0.2) then
      self:syncGeometry()
    end
    return
  end

  if not self.resizeState then return end
  local rs = self.resizeState
  local dir = rs.dir
  local dx = WindowInfo(self.win, 17) - rs.startMouseX
  local dy = WindowInfo(self.win, 18) - rs.startMouseY
  local minW = self.min_content_w
  local minH = TITLEBAR_H + self.min_content_h

  local newW = rs.startW
  if dir.dx ~= 0 then
    newW = math.max(minW, rs.startW + dir.dx * dx)
  end
  local newH = rs.startH
  if dir.dy ~= 0 then
    newH = math.max(minH, rs.startH + dir.dy * dy)
  end

  local newLeft = rs.startLeft
  local newTop = rs.startTop
  if dir.dx == -1 then newLeft = rs.startLeft + (rs.startW - newW) end
  if dir.dy == -1 then newTop = rs.startTop + (rs.startH - newH) end

  rs.newW, rs.newH, rs.newLeft, rs.newTop = newW, newH, newLeft, newTop

  SetCursor(miniwin[dir.cursor_field])

  local label = self.preview_label and self.preview_label(newW, math.max(0, newH - TITLEBAR_H)) or nil
  self:drawResizeGhost(newLeft, newTop, newW, newH, label)
end

function winframe:onDragRelease(handle)
  if handle == "zz_drag" then
    self.dragState = nil
    self:save()
    self:syncGeometry()
    Repaint()
    return
  end

  if not self.resizeState then return end
  local rs = self.resizeState
  self.resizeState = nil
  self:destroyResizeGhost()

  if rs.newLeft ~= self.left or rs.newTop ~= self.top then
    WindowPosition(self.win, rs.newLeft, rs.newTop, 0, ABSOLUTE_LOCATION)
    self.left, self.top = rs.newLeft, rs.newTop
  end
  -- self._paintedW/_paintedH are still whatever they were before this
  -- gesture started (the real window was never touched during it -- see
  -- drawResizeGhost's comment), so repaintContent() (called via redraw()
  -- below) will see the size actually changed and do the one real
  -- WindowResize this whole gesture ever needed.
  self:applyResize(rs.newW, math.max(0, rs.newH - TITLEBAR_H), true)
  self:save()
  self:syncGeometry()
  self:redraw()
  Repaint()
end

function winframe:onButtonClick(handle)
  self:bringToFront()

  if handle == "btn_min" then
    if self.minimized then
      self.minimized = false
    else
      self.minimized = true
      self.maximized = false
    end
    self:redraw()
    self:save()
  elseif handle == "btn_max" then
    if self.maximized then
      self.maximized = false
      self.left, self.top = self.pre_maximize_geom[1], self.pre_maximize_geom[2]
      self.content_w, self.content_h = self.pre_maximize_geom[3], self.pre_maximize_geom[4]
      WindowPosition(self.win, self.left, self.top, 0, ABSOLUTE_LOCATION)
    else
      self.pre_maximize_geom = { self.left, self.top, self.content_w, self.content_h }
      self.maximized = false  -- cleared so :totalHeight()/Width() use content_w/h below, not stale flag
      self.minimized = false
      self.left, self.top = 8, 8
      self.content_w = math.max(self.min_content_w, GetInfo(281) - 16)
      self.content_h = math.max(self.min_content_h, GetInfo(280) - 16 - TITLEBAR_H)
      self.maximized = true
      WindowPosition(self.win, self.left, self.top, 0, ABSOLUTE_LOCATION)
    end
    if self.on_resize then self.on_resize(self.content_w, self.content_h) end
    self:redraw()
    self:save()
  elseif handle == "btn_close" then
    self:hide()  -- hides, doesn't destroy -- bring it back from mush_windows' Windows menu (Ctrl+Shift+W)
  end
  self:syncGeometry()
end

-- ---------------------------------------------------------------------------
-- Global dispatchers (MUSHclient calls these by name; they route to the
-- right instance based on the "<id>|<handle>" hotspot id)
-- ---------------------------------------------------------------------------

function WinframeOnMouseDown(flags, hotspotId)
  local inst, handle = parseHotspotId(hotspotId)
  if inst then inst:onMouseDown(handle) end
end

function WinframeOnDragMove(flags, hotspotId)
  local inst, handle = parseHotspotId(hotspotId)
  if inst then inst:onDragMove(handle) end
end

function WinframeOnDragRelease(flags, hotspotId)
  local inst, handle = parseHotspotId(hotspotId)
  if inst then inst:onDragRelease(handle) end
end

function WinframeOnButtonClick(flags, hotspotId)
  local inst, handle = parseHotspotId(hotspotId)
  if inst then inst:onButtonClick(handle) end
end

-- Called via CallPlugin from mush_windows' own Windows menu
-- when its entry for this id is picked, to bring the window in THIS plugin
-- forward (and un-minimize/un-hide it) or hide it -- mush_windows only
-- knows the id and which plugin owns it (from the registry), not the
-- winframe instance itself, since that only exists in this Lua state.
function WinframeActivate(id)
  local inst = instances[id]
  if not inst then return false end
  inst.minimized = false
  inst:show()
  return true
end

function WinframeHide(id)
  local inst = instances[id]
  if not inst then return false end
  inst:hide()
  return true
end

-- ---------------------------------------------------------------------------
-- Public constructor / methods
-- ---------------------------------------------------------------------------

function winframe.new(cfg)
  assert(cfg.id, "winframe.new requires an id")
  assert(not cfg.id:find("|"), "winframe id must not contain '|'")
  assert(not cfg.id:find(":"), "winframe id must not contain ':'")  -- reserved by the geometry-registry wire format
  assert(not instances[cfg.id], "winframe id already in use: " .. cfg.id)

  local self = setmetatable({}, winframe)
  self.id = cfg.id
  self.win = "winframe_" .. cfg.id
  self.title = cfg.title or cfg.id
  self.bg_colour = cfg.bg_colour or 0x000000
  self.min_content_w = cfg.min_content_w or 40
  self.min_content_h = cfg.min_content_h or 40
  self.on_resize = cfg.on_resize
  self.on_draw = cfg.on_draw
  self.preview_label = cfg.preview_label
  self.on_hotspots = cfg.on_hotspots
  self.titleFontId = "wf_title_" .. cfg.id

  self.left = tonumber(GetVariable("wf_" .. self.id .. "_left")) or cfg.default_left or 4
  self.top = tonumber(GetVariable("wf_" .. self.id .. "_top")) or cfg.default_top or 4
  self.content_w = tonumber(GetVariable("wf_" .. self.id .. "_cw")) or cfg.default_content_w or 300
  self.content_h = tonumber(GetVariable("wf_" .. self.id .. "_ch")) or cfg.default_content_h or 200
  self.content_w = math.max(self.min_content_w, self.content_w)
  self.content_h = math.max(self.min_content_h, self.content_h)
  self.minimized = false
  self.maximized = false
  self.hidden = true  -- flips to false in show(), called once by the consumer right after new()

  instances[cfg.id] = self

  WindowCreate(self.win, self.left, self.top, self:totalWidth(), self:totalHeight(), 4, ABSOLUTE_LOCATION, self.bg_colour)
  WindowFont(self.win, self.titleFontId, TITLE_FONT_NAME, TITLE_FONT_SIZE, true, false, false, false, 0, 49)
  self:syncGeometry()

  if self.on_resize then
    self.on_resize(self.content_w, self.content_h)
  end

  return self
end

function winframe:show()
  self.hidden = false
  self:bringToFront()
  self:redraw()
  self:syncGeometry()
end

function winframe:hide()
  self.hidden = true
  WindowShow(self.win, false)
  self:syncGeometry()
end

function winframe:setTitle(title)
  self.title = title
  self:drawChrome()
  WindowShow(self.win, true)
end

function winframe:destroy()
  WindowDelete(self.win)
  self:unregisterGeometry()
  instances[self.id] = nil
end

return winframe
