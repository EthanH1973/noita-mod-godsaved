dofile("data/scripts/lib/mod_settings.lua")

local mod_id = "noita-mod-godsaved"

mod_settings_version = 1

mod_settings = {
    {
        id = "max_loads",
        ui_name = "Loads Per Run",
        ui_description = "Maximum number of times you can load your save per run. Set to 0 for unlimited.",
        value_default = 3,
        value_min = 0,
        value_max = 10,
        value_display_multiplier = 1,
        scope = MOD_SETTING_SCOPE_RUNTIME,
    },
    {
        id = "restore_perks",
        ui_name = "Load Perks on Load",
        ui_description = "When enabled, loading a save will also re-apply perks. May cause issues with some perks that add duplicate components.",
        value_default = false,
        scope = MOD_SETTING_SCOPE_RUNTIME,
    },
    {
        id = "restore_stains",
        ui_name = "Load Stains & Ingestion",
        ui_description = "When enabled, loading a save will also restore stain effects (blood, oil, etc.) and ingestion state (eaten/drunk materials). Visual pixel stains on the player sprite are not restored, only gameplay effects.",
        value_default = false,
        scope = MOD_SETTING_SCOPE_RUNTIME,
    },
}

function ModSettingsUpdate(init_scope)
    mod_settings_update(mod_id, mod_settings, init_scope)
end

function ModSettingsGuiCount()
    return mod_settings_gui_count(mod_id, mod_settings)
end

function ModSettingsGui(gui, in_main_menu)
    mod_settings_gui(mod_id, mod_settings, gui, in_main_menu)
end
