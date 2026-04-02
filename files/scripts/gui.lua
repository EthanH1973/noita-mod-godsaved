-- gui.lua: In-game GUI for godsaved mod
-- This script runs as a LuaComponent on the player entity, executing every frame.

dofile_once("mods/godsaved/files/scripts/snapshot.lua")

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
-- Snapshot indicator (near perks area, top-left)
-- ============================================================
GuiLayoutBeginHorizontal(gui, 2, 20, true)
if has_snapshot then
    GuiColorSetForNextWidget(gui, 0.2, 1.0, 0.2, 1.0)  -- Green for ON
    GuiText(gui, 0, 0, "SNAP: ON")
else
    GuiColorSetForNextWidget(gui, 0.7, 0.7, 0.7, 0.6)  -- Grey for OFF
    GuiText(gui, 0, 0, "SNAP: OFF")
end
GuiLayoutEnd(gui)

-- ============================================================
-- Buttons (near inventory area, right side)
-- Noita's GUI coordinate system: ~213x120 units
-- Inventory bar is near bottom-center
-- ============================================================

-- Snapshot button
GuiLayoutBeginHorizontal(gui, 76, 80, true)
local snap_id = new_id()
if GuiButton(gui, snap_id, 0, 0, "[Snapshot]") then
    godsaved_capture_snapshot()
end
GuiLayoutEnd(gui)

-- Restore button (only shown if snapshot exists)
if has_snapshot then
    GuiLayoutBeginHorizontal(gui, 76, 88, true)
    local restore_id = new_id()
    if GuiButton(gui, restore_id, 0, 0, "[Restore]") then
        godsaved_restore_snapshot()
    end
    GuiLayoutEnd(gui)
end
