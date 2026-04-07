-- init.lua: Main entry point for godsaved mod

dofile_once("mods/noita-mod-godsaved/files/scripts/save_load.lua")

local gui = nil
local _next_id = 100

local function next_id()
    _next_id = _next_id + 1
    return _next_id
end

function OnModInit()
    -- Build a custom flask entity XML by reading the real potion.xml and
    -- replacing its randomizing LuaComponent init script with our own.
    -- This custom XML is used at load time so EntityLoad fills the flask
    -- with our saved materials instead of randomizing them.
    local potion_xml = ModTextFileGetContent("data/entities/items/pickup/potion.xml")
    if potion_xml and potion_xml ~= "" then
        -- Replace the LuaComponent's script with our custom flask_init.lua.
        -- The vanilla script is at data/scripts/items/potion.lua — swap it out.
        local custom_xml = potion_xml:gsub(
            'data/scripts/items/potion%.lua',
            'mods/noita-mod-godsaved/files/scripts/flask_init.lua'
        )
        ModTextFileSetContent(
            "mods/noita-mod-godsaved/files/entities/godsaved_flask.xml",
            custom_xml
        )
    end
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

    local has_save = godsaved_has_save()
    local max_loads = tonumber(ModSettingGet("noita-mod-godsaved.max_loads")) or 0
    local loads_used = tonumber(GlobalsGetValue("godsaved_loads_used", "0")) or 0
    local loads_remaining = max_loads - loads_used
    local can_load = has_save and (max_loads == 0 or loads_remaining > 0)

    -- Buttons in a horizontal row above the inventory bar
    GuiLayoutBeginHorizontal(gui, 1, 1)

    if GuiButton(gui, 0, 0, "[SAVE]", next_id()) then
        godsaved_save()
    end

    if can_load then
        local label = (max_loads > 0) and ("[LOAD (" .. loads_remaining .. " left)]") or "[LOAD]"
        if GuiButton(gui, 0, 0, label, next_id()) then
            godsaved_load()
        end
    end

    GuiLayoutEnd(gui)
end

function OnPlayerDied(player_entity)
    if GlobalsGetValue("godsaved_save_exists", "0") == "1" then
        GamePrint("Godsaved: You died with an active save!")
    end
end
