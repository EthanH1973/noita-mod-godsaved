-- save_load.lua: Core save and load logic for godsaved mod

local EZWand = dofile_once("mods/noita-mod-godsaved/files/scripts/lib/ezwand.lua")
dofile_once("mods/noita-mod-godsaved/files/scripts/perk_utils.lua")

-- Separator constants (chosen to avoid conflicts with EZWand's ";" separator)
local WAND_SEP   = "<<<>>>"  -- between wands
local ITEM_SEP   = "<<<>>>"  -- between items
local MAT_SEP    = "@@"      -- between xml_path and material data within an item
local CHARGE_SEP = "|||"     -- between wand serialization and spell charges
local SLOT_SEP   = "###"     -- between spell charges and inventory slot index
local EFFECT_SEP = ";;;"     -- between status effects
local SPELL_SEP  = "<<<>>>"  -- between loose spells

local CUSTOM_FLASK_XML = "mods/noita-mod-godsaved/files/entities/godsaved_flask.xml"

-- Names of child entities that must never be killed during effect/perk cleanup
local PROTECTED_CHILDREN = {
    inventory_quick = true, inventory_full = true,
    arm_r = true, arm_l = true, cape = true,
}

local function get_child_by_name(player_entity, name)
    local children = EntityGetAllChildren(player_entity) or {}
    for _, child in ipairs(children) do
        if EntityGetName(child) == name then return child end
    end
    return nil
end

local function get_inventory_quick(player_entity)
    return get_child_by_name(player_entity, "inventory_quick")
end

local function is_wand(entity_id)
    local ability = EntityGetFirstComponentIncludingDisabled(entity_id, "AbilityComponent")
    if ability then
        return ComponentGetValue2(ability, "use_gun_script") == true
    end
    return false
end

-- Splits str by sep (plain string match). Always returns at least one part.
local function split_by_sep(str, sep)
    local parts = {}
    local pos = 1
    while true do
        local s, e = str:find(sep, pos, true)
        if s then
            table.insert(parts, str:sub(pos, s - 1))
            pos = e + 1
        else
            table.insert(parts, str:sub(pos))
            break
        end
    end
    return parts
end

-- Clears a table-or-string typed component field by trying both "" and {}.
-- Some Noita fields (stain_effects, ingestion_effects, count_per_material_type)
-- are table-typed internally; ComponentSetValue2 with the wrong type silently fails.
local function clear_field(comp, field)
    pcall(ComponentSetValue2, comp, field, "")
    pcall(ComponentSetValue2, comp, field, {})
end

-- Safely converts a ComponentGetValue2 result to a string.
-- Some fields return tables instead of strings depending on the Noita version.
local function value_to_string(val)
    if val == nil then return "" end
    if type(val) == "string" then return val end
    if type(val) == "table" then
        local parts = {}
        for i, v in ipairs(val) do parts[i] = tostring(v) end
        return table.concat(parts, ",")
    end
    return tostring(val)
end

local function capture_hp(player_entity)
    local dmg = EntityGetFirstComponentIncludingDisabled(player_entity, "DamageModelComponent")
    if dmg then
        return tostring(ComponentGetValue2(dmg, "hp")) .. ";"
            .. tostring(ComponentGetValue2(dmg, "max_hp")) .. ";"
            .. tostring(ComponentGetValue2(dmg, "max_hp_cap"))
    end
    return ""
end

local function capture_gold(player_entity)
    local wallet = EntityGetFirstComponentIncludingDisabled(player_entity, "WalletComponent")
    if wallet then return tostring(ComponentGetValue2(wallet, "money")) end
    return "0"
end

-- Format: "EFFECT_NAME:frames;;;EFFECT_NAME2:frames2"
-- Permanent effects (frames == -1) are perk-owned and handled by the perk system; skip them here.
local function capture_effects(player_entity)
    local comps = EntityGetAllComponents(player_entity) or {}
    local effects = {}
    for _, comp in ipairs(comps) do
        if ComponentGetTypeName(comp) == "GameEffectComponent" then
            local effect_name = ComponentGetValue2(comp, "effect")
            local frames = ComponentGetValue2(comp, "frames")
            if effect_name and effect_name ~= "" and frames ~= -1 then
                table.insert(effects, effect_name .. ":" .. tostring(frames))
            end
        end
    end
    return table.concat(effects, EFFECT_SEP)
end

-- Returns comma-separated uses_remaining values matching spell order on the wand
local function capture_spell_charges(wand_entity)
    local children = EntityGetAllChildren(wand_entity) or {}
    local charges = {}
    for _, spell in ipairs(children) do
        local item_comp = EntityGetFirstComponentIncludingDisabled(spell, "ItemComponent")
        if item_comp then
            table.insert(charges, tostring(ComponentGetValue2(item_comp, "uses_remaining")))
        else
            table.insert(charges, "-1")
        end
    end
    return table.concat(charges, ",")
end

local function capture_wands(player_entity)
    local inv = get_inventory_quick(player_entity)
    if not inv then return "" end

    local children = EntityGetAllChildren(inv) or {}
    local wand_strings = {}

    for _, child in ipairs(children) do
        if is_wand(child) then
            local success, result = pcall(function()
                local w = EZWand(child)
                local serialized = w:Serialize()
                local charges = capture_spell_charges(child)
                local slot = 0
                local item_comp = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
                if item_comp then slot = ComponentGetValue2(item_comp, "inventory_slot") or 0 end
                return serialized .. CHARGE_SEP .. charges .. SLOT_SEP .. tostring(slot)
            end)
            if success and result then table.insert(wand_strings, result) end
        end
    end

    return table.concat(wand_strings, WAND_SEP)
end

-- count_per_material_type returns a table indexed by (material_id + 1).
-- We use CellFactory_GetName for reliable round-tripping via AddMaterialInventoryMaterial.
local function serialize_flask_materials(entity_id)
    local mat_inv = EntityGetFirstComponentIncludingDisabled(entity_id, "MaterialInventoryComponent")
    if not mat_inv then return "" end

    local counts = ComponentGetValue2(mat_inv, "count_per_material_type")
    if not counts then return "" end

    local materials = {}
    if type(counts) == "table" then
        for i, count in ipairs(counts) do
            if type(count) == "number" and count > 0 then
                local mat_name = CellFactory_GetName(i - 1)
                if mat_name and mat_name ~= "" then
                    table.insert(materials, mat_name .. ":" .. tostring(math.floor(count)))
                end
            end
        end
    elseif type(counts) == "string" and counts ~= "" then
        local mat_id = 0
        for count_str in counts:gmatch("[^,]+") do
            local count = tonumber(count_str) or 0
            if count > 0 then
                local mat_name = CellFactory_GetName(mat_id)
                if mat_name and mat_name ~= "" then
                    table.insert(materials, mat_name .. ":" .. tostring(math.floor(count)))
                end
            end
            mat_id = mat_id + 1
        end
    end

    return table.concat(materials, ",")
end

local function capture_items(player_entity)
    local inv = get_inventory_quick(player_entity)
    if not inv then return "" end

    local children = EntityGetAllChildren(inv) or {}
    local item_strings = {}

    for _, child in ipairs(children) do
        if not is_wand(child) then
            local xml_path = EntityGetFilename(child) or ""
            if xml_path ~= "" then
                local mat_data = serialize_flask_materials(child)
                table.insert(item_strings, xml_path .. MAT_SEP .. mat_data)
            end
        end
    end

    return table.concat(item_strings, ITEM_SEP)
end

-- Spells are identified by action_id (not XML path), since they are created
-- dynamically via CreateItemActionEntity, not from XML files.
-- Format: "ACTION_ID@@uses_remaining<<<>>>ACTION_ID@@uses_remaining"
local function capture_spells(player_entity)
    local inv_full = get_child_by_name(player_entity, "inventory_full")
    if not inv_full then return "" end

    local children = EntityGetAllChildren(inv_full) or {}
    local spell_strings = {}

    for _, child in ipairs(children) do
        local action_comp = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
        if action_comp then
            local action_id = ComponentGetValue2(action_comp, "action_id") or ""
            if action_id ~= "" then
                local uses = -1
                local item_comp = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
                if item_comp then uses = ComponentGetValue2(item_comp, "uses_remaining") or -1 end
                table.insert(spell_strings, action_id .. MAT_SEP .. tostring(uses))
            end
        end
    end

    return table.concat(spell_strings, SPELL_SEP)
end

-- Visual pixel stains on the player sprite cannot be saved from Lua;
-- only the gameplay effects (fire extinguish probability, etc.) can.
-- Format: "stain_effects;;;ingestion_effects;;;extinguish_prob;;;stain_team"
local function capture_stains(player_entity)
    local comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if not comps or #comps == 0 then return "" end
    local comp = comps[1]
    local stain_effects    = value_to_string(ComponentGetValue2(comp, "stain_effects"))
    local ingestion_effects = value_to_string(ComponentGetValue2(comp, "ingestion_effects"))
    local extinguish_prob  = ComponentGetValue2(comp, "stain_effects_extinguish_fire_probability") or 0
    local stain_team       = ComponentGetValue2(comp, "stain_team_id") or 0
    return stain_effects .. EFFECT_SEP .. ingestion_effects .. EFFECT_SEP
        .. tostring(extinguish_prob) .. EFFECT_SEP .. tostring(stain_team)
end

local function capture_ingestion(player_entity)
    local comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if not comps or #comps == 0 then return "" end
    return value_to_string(ComponentGetValue2(comps[1], "count_per_material_type"))
end

local function capture_position(player_entity)
    local x, y = EntityGetTransform(player_entity)
    if x and y then return tostring(x) .. ";" .. tostring(y) end
    return ""
end

function godsaved_save()
    local players = EntityGetWithTag("player_unit")
    if #players == 0 then
        GamePrint("Godsaved: No player found!")
        return false
    end
    local player = players[1]
    for i = 2, #players do EntityKill(players[i]) end

    GlobalsSetValue("godsaved_save_exists", "1")
    GlobalsSetValue("godsaved_hp",        capture_hp(player))
    GlobalsSetValue("godsaved_gold",      capture_gold(player))
    GlobalsSetValue("godsaved_effects",   capture_effects(player))
    GlobalsSetValue("godsaved_wands",     capture_wands(player))
    GlobalsSetValue("godsaved_items",     capture_items(player))
    GlobalsSetValue("godsaved_spells",    capture_spells(player))
    GlobalsSetValue("godsaved_perks",     godsaved_capture_perks())
    GlobalsSetValue("godsaved_position",  capture_position(player))
    GlobalsSetValue("godsaved_stains",    capture_stains(player))
    GlobalsSetValue("godsaved_ingestion", capture_ingestion(player))

    GamePrint("Godsaved: Game saved!")
    return true
end

local function load_hp(player_entity, hp_string)
    if hp_string == "" then return end
    local parts = {}
    for part in hp_string:gmatch("[^;]+") do table.insert(parts, tonumber(part)) end
    if #parts < 2 then return end

    local dmg = EntityGetFirstComponentIncludingDisabled(player_entity, "DamageModelComponent")
    if dmg then
        ComponentSetValue2(dmg, "max_hp", parts[2])
        ComponentSetValue2(dmg, "hp", parts[1])
        if parts[3] then ComponentSetValue2(dmg, "max_hp_cap", parts[3]) end
    end
end

local function load_gold(player_entity, gold_string)
    if gold_string == "" then return end
    local money = tonumber(gold_string)
    if not money then return end
    local wallet = EntityGetFirstComponentIncludingDisabled(player_entity, "WalletComponent")
    if wallet then ComponentSetValue2(wallet, "money", money) end
end

local function clear_effects(player_entity)
    -- Remove GameEffectComponents directly on the player entity
    local comps = EntityGetAllComponents(player_entity) or {}
    for _, comp in ipairs(comps) do
        if ComponentGetTypeName(comp) == "GameEffectComponent" then
            EntityRemoveComponent(player_entity, comp)
        end
    end

    -- Kill child entities carrying GameEffectComponents;
    -- effects loaded via LoadGameEffectEntityTo live as child entities, not direct components
    local children = EntityGetAllChildren(player_entity) or {}
    for _, child in ipairs(children) do
        local name = EntityGetName(child) or ""
        if not PROTECTED_CHILDREN[name] then
            local child_comps = EntityGetAllComponents(child) or {}
            for _, comp in ipairs(child_comps) do
                if ComponentGetTypeName(comp) == "GameEffectComponent" then
                    EntityKill(child)
                    break
                end
            end
        end
    end

    -- Clear ingestion material tracking so stain-based effects don't re-apply
    local ingestion_comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if ingestion_comps then
        for _, comp in ipairs(ingestion_comps) do
            clear_field(comp, "count_per_material_type")
        end
    end

    -- Clear StatusEffectDataComponent stain state
    local status_comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if status_comps then
        for _, comp in ipairs(status_comps) do
            ComponentSetValue2(comp, "stain_effects_extinguish_fire_probability", 0)
            ComponentSetValue2(comp, "stain_team_id", 0)
            clear_field(comp, "stain_effects")
            clear_field(comp, "ingestion_effects")
        end
    end
end

local function load_effects(player_entity, effects_string)
    clear_effects(player_entity)
    if effects_string == "" then return end

    for _, entry in ipairs(split_by_sep(effects_string, EFFECT_SEP)) do
        if entry ~= "" then
            local colon = entry:find(":", 1, true)
            if colon then
                local effect_name = entry:sub(1, colon - 1)
                local frames = tonumber(entry:sub(colon + 1))
                if effect_name ~= "" and frames then
                    local effect_comp = GetGameEffectLoadTo(player_entity, effect_name, true)
                    if effect_comp then ComponentSetValue2(effect_comp, "frames", frames) end
                end
            end
        end
    end
end

-- Format: "stain_effects;;;ingestion_effects;;;extinguish_prob;;;stain_team"
local function load_stains(player_entity, stain_string)
    if stain_string == "" then return end
    local parts = split_by_sep(stain_string, EFFECT_SEP)
    if #parts < 4 then return end

    local comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if not comps or #comps == 0 then return end
    local comp = comps[1]
    -- stain_effects and ingestion_effects are table-typed fields; try string first
    pcall(ComponentSetValue2, comp, "stain_effects", parts[1])
    pcall(ComponentSetValue2, comp, "ingestion_effects", parts[2])
    ComponentSetValue2(comp, "stain_effects_extinguish_fire_probability", tonumber(parts[3]) or 0)
    ComponentSetValue2(comp, "stain_team_id", tonumber(parts[4]) or 0)
end

local function load_ingestion(player_entity, ingestion_string)
    if ingestion_string == "" then return end
    local comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if not comps or #comps == 0 then return end
    -- count_per_material_type is table-typed; try string first
    pcall(ComponentSetValue2, comps[1], "count_per_material_type", ingestion_string)
end

local function load_spell_charges(wand_entity, charges_string)
    if charges_string == "" then return end
    local charges = {}
    for val in charges_string:gmatch("[^,]+") do table.insert(charges, tonumber(val)) end

    local children = EntityGetAllChildren(wand_entity) or {}
    for i, spell in ipairs(children) do
        if charges[i] then
            local item_comp = EntityGetFirstComponentIncludingDisabled(spell, "ItemComponent")
            if item_comp then ComponentSetValue2(item_comp, "uses_remaining", charges[i]) end
        end
    end
end

local function clear_inventory(player_entity)
    local inv_quick = get_inventory_quick(player_entity)
    if inv_quick then
        for _, child in ipairs(EntityGetAllChildren(inv_quick) or {}) do EntityKill(child) end
    end
    local inv_full = get_child_by_name(player_entity, "inventory_full")
    if inv_full then
        for _, child in ipairs(EntityGetAllChildren(inv_full) or {}) do EntityKill(child) end
    end
end

local function is_in_inventory(player_entity, entity_id)
    if not EntityGetIsAlive(entity_id) then return false end
    local parent = EntityGetParent(entity_id)
    if not parent or parent == 0 then return false end
    local inv_quick = get_inventory_quick(player_entity)
    local inv_full = get_child_by_name(player_entity, "inventory_full")
    return parent == inv_quick or parent == inv_full or parent == player_entity
end

local function load_wands(player_entity, wand_string)
    if wand_string == "" then return end

    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    for _, entry in ipairs(split_by_sep(wand_string, WAND_SEP)) do
        if entry ~= "" then
            -- Format: serialized|||charges###slot
            local charge_sep_pos = entry:find(CHARGE_SEP, 1, true)
            local serialized = entry
            local charges_string = ""
            local saved_slot = nil
            if charge_sep_pos then
                serialized = entry:sub(1, charge_sep_pos - 1)
                local rest = entry:sub(charge_sep_pos + #CHARGE_SEP)
                local slot_sep_pos = rest:find(SLOT_SEP, 1, true)
                if slot_sep_pos then
                    charges_string = rest:sub(1, slot_sep_pos - 1)
                    saved_slot = tonumber(rest:sub(slot_sep_pos + #SLOT_SEP))
                else
                    charges_string = rest
                end
            end

            local wand_entity = nil
            local success, err = pcall(function()
                local w = EZWand(serialized, spawn_x, spawn_y)
                wand_entity = w.entity_id
                if charges_string ~= "" then load_spell_charges(wand_entity, charges_string) end
                local item_comp = EntityGetFirstComponentIncludingDisabled(wand_entity, "ItemComponent")
                if item_comp then
                    ComponentSetValue2(item_comp, "has_been_picked_by_player", true)
                    if saved_slot then ComponentSetValue2(item_comp, "inventory_slot", saved_slot) end
                end
                -- Use GamePickUpInventoryItem directly; EZWand's PutInPlayersInventory has a
                -- stale child count check that fails after clearing inventory in the same frame
                GamePickUpInventoryItem(player_entity, wand_entity, false)
            end)
            if not success then
                GamePrint("Godsaved: Failed to load wand: " .. tostring(err))
                if wand_entity and EntityGetIsAlive(wand_entity) then EntityKill(wand_entity) end
            elseif wand_entity and not is_in_inventory(player_entity, wand_entity) then
                EntityKill(wand_entity)
                GamePrint("Godsaved: Wand cleanup - removed orphaned entity")
            end
        end
    end
end

local function load_items(player_entity, item_string)
    if item_string == "" then return end

    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    for _, entry in ipairs(split_by_sep(item_string, ITEM_SEP)) do
        if entry ~= "" then
            local sep_pos = entry:find(MAT_SEP, 1, true)
            local xml_path = entry
            local mat_data = ""
            if sep_pos then
                xml_path = entry:sub(1, sep_pos - 1)
                mat_data = entry:sub(sep_pos + #MAT_SEP)
            end

            -- For flasks (items with saved material data), load our custom flask XML whose
            -- init script reads from a global instead of randomizing flask contents.
            local load_xml = xml_path
            if mat_data ~= "" then
                GlobalsSetValue("godsaved_flask_materials", mat_data)
                load_xml = CUSTOM_FLASK_XML
            end

            local item_entity = nil
            local load_ok, load_err = pcall(function()
                item_entity = EntityLoad(load_xml, spawn_x, spawn_y)
            end)

            if not load_ok or not item_entity then
                if mat_data ~= "" then GlobalsSetValue("godsaved_flask_materials", "") end
                GamePrint("Godsaved: Failed to load item: " .. tostring(load_err))
            else
                local pickup_ok, pickup_err = pcall(GamePickUpInventoryItem, player_entity, item_entity, false)
                if not pickup_ok then
                    GamePrint("Godsaved: Failed to pick up item: " .. tostring(pickup_err))
                    if EntityGetIsAlive(item_entity) then EntityKill(item_entity) end
                end
            end
        end
    end
end

local function load_spells(player_entity, spell_string)
    if spell_string == "" then return end

    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    for _, entry in ipairs(split_by_sep(spell_string, SPELL_SEP)) do
        if entry ~= "" then
            local sep_pos = entry:find(MAT_SEP, 1, true)
            local action_id = entry
            local uses = -1
            if sep_pos then
                action_id = entry:sub(1, sep_pos - 1)
                uses = tonumber(entry:sub(sep_pos + #MAT_SEP)) or -1
            end

            local spell_entity = nil
            local success, err = pcall(function()
                spell_entity = CreateItemActionEntity(action_id, spawn_x, spawn_y)
                if spell_entity then
                    if uses ~= -1 then
                        local item_comp = EntityGetFirstComponentIncludingDisabled(spell_entity, "ItemComponent")
                        if item_comp then ComponentSetValue2(item_comp, "uses_remaining", uses) end
                    end
                    GamePickUpInventoryItem(player_entity, spell_entity, false)
                end
            end)
            if not success then
                GamePrint("Godsaved: Failed to load spell " .. action_id .. ": " .. tostring(err))
                if spell_entity and EntityGetIsAlive(spell_entity) then EntityKill(spell_entity) end
            elseif spell_entity and not is_in_inventory(player_entity, spell_entity) then
                EntityKill(spell_entity)
                GamePrint("Godsaved: Spell cleanup - removed orphaned entity")
            end
        end
    end
end

local function load_position(player_entity, pos_string)
    if pos_string == "" then return end
    local parts = {}
    for part in pos_string:gmatch("[^;]+") do table.insert(parts, tonumber(part)) end
    if #parts >= 2 and parts[1] and parts[2] then
        EntitySetTransform(player_entity, parts[1], parts[2])
    end
end

function godsaved_load()
    if GlobalsGetValue("godsaved_save_exists", "0") ~= "1" then
        GamePrint("Godsaved: No save found!")
        return false
    end

    -- Check load count limit
    local max_loads = tonumber(ModSettingGet("noita-mod-godsaved.max_loads")) or 0
    if max_loads > 0 then
        local used = tonumber(GlobalsGetValue("godsaved_loads_used", "0")) or 0
        if used >= max_loads then
            GamePrint("Godsaved: No loads remaining!")
            return false
        end
    end

    local players = EntityGetWithTag("player_unit")
    if #players == 0 then
        GamePrint("Godsaved: No player found!")
        return false
    end
    local player = players[1]
    for i = 2, #players do EntityKill(players[i]) end

    local hp_data        = GlobalsGetValue("godsaved_hp",        "")
    local gold_data      = GlobalsGetValue("godsaved_gold",      "")
    local effects_data   = GlobalsGetValue("godsaved_effects",   "")
    local wand_data      = GlobalsGetValue("godsaved_wands",     "")
    local item_data      = GlobalsGetValue("godsaved_items",     "")
    local spell_data     = GlobalsGetValue("godsaved_spells",    "")
    local perk_data      = GlobalsGetValue("godsaved_perks",     "")
    local pos_data       = GlobalsGetValue("godsaved_position",  "")
    local stain_data     = GlobalsGetValue("godsaved_stains",    "")
    local ingestion_data = GlobalsGetValue("godsaved_ingestion", "")

    clear_inventory(player)
    load_hp(player, hp_data)
    load_gold(player, gold_data)
    load_wands(player, wand_data)
    load_items(player, item_data)
    load_spells(player, spell_data)
    load_position(player, pos_data)
    godsaved_clear_perks(player)
    -- Effects cleared here; perk load comes after so perk effects aren't immediately wiped
    load_effects(player, effects_data)

    if ModSettingGet("noita-mod-godsaved.restore_stains") then
        load_stains(player, stain_data)
        load_ingestion(player, ingestion_data)
    end

    if ModSettingGet("noita-mod-godsaved.restore_perks") then
        local loaded_count, failed = godsaved_load_perks(player, perk_data)
        if #failed > 0 then
            GamePrint("Godsaved: Some perks failed to load")
        else
            GamePrint("Godsaved: Loaded " .. tostring(loaded_count) .. " perks")
        end
    end

    -- Kill any duplicate player entities spawned during load
    local final_players = EntityGetWithTag("player_unit")
    for i = 2, #final_players do EntityKill(final_players[i]) end

    -- Increment load counter
    local used = tonumber(GlobalsGetValue("godsaved_loads_used", "0")) or 0
    GlobalsSetValue("godsaved_loads_used", tostring(used + 1))

    GamePrint("Godsaved: Game loaded!")
    return true
end

function godsaved_has_save()
    return GlobalsGetValue("godsaved_save_exists", "0") == "1"
end
