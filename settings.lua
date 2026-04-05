dofile("data/scripts/lib/mod_settings.lua")

local mod_id = "noita-mod-godsaved"

mod_settings_version = 1

mod_settings = {
    {
        id = "restore_perks",
        ui_name = "Restore Perks on Revive",
        ui_description = "When enabled, restoring a snapshot will also re-apply perks. May cause issues with some perks that add duplicate components.",
        value_default = false,
        scope = MOD_SETTING_SCOPE_RUNTIME,
    },
    {
        id = "restore_stains",
        ui_name = "Restore Stains & Ingestion",
        ui_description = "When enabled, restoring a snapshot will also restore stain effects (blood, oil, etc.) and ingestion state (eaten/drunk materials). Visual pixel stains on the player sprite are not restored, only gameplay effects.",
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
