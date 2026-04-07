-- gui.lua: In-game GUI for godsaved mod
-- This script runs as a LuaComponent on the player entity, executing every frame.

dofile_once("mods/noita-mod-godsaved/files/scripts/save_load.lua")

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

local has_save = godsaved_has_save()
local max_loads = tonumber(ModSettingGet("noita-mod-godsaved.max_loads")) or 0
local loads_used = tonumber(GlobalsGetValue("godsaved_loads_used", "0")) or 0
local loads_remaining = max_loads - loads_used
local can_load = has_save and (max_loads == 0 or loads_remaining > 0)

-- ============================================================
-- Buttons (below inventory bar, right of indicator)
-- Noita GUI coords: (0,0) = top-left
-- Inventory bar is at the top, ~y=0 to y=22
-- Place buttons just below at y=26
-- ============================================================

-- Save button
local save_id = new_id()
if GuiButton(gui, save_id, 52, 28, "[SAVE]") then
    godsaved_save()
end

-- Load button (only shown when a save exists and loads remain)
if can_load then
    local label = (max_loads > 0) and ("[LOAD (" .. loads_remaining .. " left)]") or "[LOAD]"
    local load_id = new_id()
    if GuiButton(gui, load_id, 100, 28, label) then
        godsaved_load()
    end
end
