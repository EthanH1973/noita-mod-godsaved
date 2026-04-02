-- init.lua: Main entry point for godsaved mod

dofile_once("mods/noita-mod-godsaved/files/scripts/snapshot.lua")

local gui = nil
local _next_id = 100

local function next_id()
    _next_id = _next_id + 1
    return _next_id
end

function OnModInit()
end

function OnPlayerSpawned(player_entity)
    if not gui then
        gui = GuiCreate()
    end
end

function OnWorldPostUpdate()
    if not gui then return end

    GuiStartFrame(gui)
    _next_id = 100

    local has_snapshot = godsaved_has_snapshot()

    -- Buttons in a horizontal row above the inventory bar
    GuiLayoutBeginHorizontal(gui, 1, 1)

    if GuiButton(gui, 0, 0, "[Snapshot]", next_id()) then
        godsaved_capture_snapshot()
    end

    if GuiButton(gui, 0, 0, "[Restore]", next_id()) then
        godsaved_restore_snapshot()
    end

    -- Snapshot status indicator
    if has_snapshot then
        GuiColorSetForNextWidget(gui, 0.2, 1.0, 0.2, 1.0)
        GuiText(gui, 0, 0, "SNAP:ON")
    else
        GuiColorSetForNextWidget(gui, 0.7, 0.7, 0.7, 0.6)
        GuiText(gui, 0, 0, "SNAP:OFF")
    end

    GuiLayoutEnd(gui)
end

function OnPlayerDied(player_entity)
    if GlobalsGetValue("godsaved_snapshot_exists", "0") == "1" then
        GamePrint("Godsaved: You died with an active snapshot!")
    end
end
