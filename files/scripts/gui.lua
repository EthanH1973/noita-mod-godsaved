-- gui.lua: In-game GUI for godsaved mod
-- This script runs as a LuaComponent on the player entity, executing every frame.

dofile_once("mods/noita-mod-godsaved/files/scripts/snapshot.lua")

-- Create GUI once and reuse
if not godsaved_gui then
    godsaved_gui = GuiCreate()
end

local gui = godsaved_gui

-- Unique ID counter for GUI elements
local gui_id_counter = 47000

local function new_id()
    gui_id_counter = gui_id_counter + 1
    return gui_id_counter
end

-- Main GUI rendering
GuiStartFrame(gui)
gui_id_counter = 47000  -- Reset each frame for consistent IDs

local has_snapshot = godsaved_has_snapshot()

-- ============================================================
-- Snapshot indicator (below inventory bar, left side)
-- ============================================================
if has_snapshot then
    GuiColorSetForNextWidget(gui, 0.2, 1.0, 0.2, 1.0)  -- Green for ON
    GuiText(gui, 2, 28, "SNAP: ON")
else
    GuiColorSetForNextWidget(gui, 0.7, 0.7, 0.7, 0.6)  -- Grey for OFF
    GuiText(gui, 2, 28, "SNAP: OFF")
end

-- ============================================================
-- Buttons (below inventory bar, right of indicator)
-- Noita GUI coords: (0,0) = top-left
-- Inventory bar is at the top, ~y=0 to y=22
-- Place buttons just below at y=26
-- ============================================================

-- Snapshot button
local snap_id = new_id()
if GuiButton(gui, snap_id, 52, 28, "[Snapshot]") then
    godsaved_capture_snapshot()
end

-- Restore button (only shown if snapshot exists)
if has_snapshot then
    local restore_id = new_id()
    if GuiButton(gui, restore_id, 100, 28, "[Restore]") then
        godsaved_restore_snapshot()
    end
end
