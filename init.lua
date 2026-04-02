-- init.lua: Main entry point for godsaved mod

function OnModInit()
    -- No file appends needed for the prototype
    -- Future: append custom perks, spells, etc.
end

function OnPlayerSpawned(player_entity)
    -- Guard against adding duplicate GUI components on respawn
    if GameHasFlagRun("godsaved_gui_init") then return end
    GameAddFlagRun("godsaved_gui_init")

    -- Attach GUI rendering script to the player entity
    EntityAddComponent2(player_entity, "LuaComponent", {
        script_source_file = "mods/godsaved/files/scripts/gui.lua",
        execute_every_n_frame = 1,
    })
end

function OnPlayerDied(player_entity)
    -- Snapshot data persists in GlobalsSetValue across death within a run.
    -- Future: implement fountain revive logic here.
    -- For now, just log the death.
    if GlobalsGetValue("godsaved_snapshot_exists", "0") == "1" then
        GamePrint("Godsaved: You died with an active snapshot. Find a fountain to revive!")
    end
end
