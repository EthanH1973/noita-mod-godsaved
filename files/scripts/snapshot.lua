-- snapshot.lua: Core snapshot capture and restore logic for godsaved mod

local EZWand = dofile_once("mods/noita-mod-godsaved/files/scripts/lib/ezwand.lua")
dofile_once("mods/noita-mod-godsaved/files/scripts/perk_utils.lua")

-- Separator constants (chosen to avoid conflicts with EZWand's ";" separator)
local WAND_SEP = "<<<>>>"  -- between wands
local ITEM_SEP = "<<<>>>"  -- between items
local MAT_SEP = "@@"       -- between xml_path and material data within an item
local CHARGE_SEP = "|||"   -- between wand serialization and spell charges
local SLOT_SEP = "###"     -- between spell charges and inventory slot index
local EFFECT_SEP = ";;;"   -- between status effects
local SPELL_SEP = "<<<>>>" -- between loose spells

-- ============================================================
-- HELPER: Get a named child entity of the player
-- ============================================================
local function get_child_by_name(player_entity, name)
    local children = EntityGetAllChildren(player_entity) or {}
    for _, child in ipairs(children) do
        if EntityGetName(child) == name then
            return child
        end
    end
    return nil
end

local function get_inventory_quick(player_entity)
    return get_child_by_name(player_entity, "inventory_quick")
end

-- ============================================================
-- HELPER: Check if entity is a wand
-- ============================================================
local function is_wand(entity_id)
    local ability = EntityGetFirstComponentIncludingDisabled(entity_id, "AbilityComponent")
    if ability then
        return ComponentGetValue2(ability, "use_gun_script") == true
    end
    return false
end

-- ============================================================
-- CAPTURE: HP
-- ============================================================
local function capture_hp(player_entity)
    local dmg = EntityGetFirstComponentIncludingDisabled(player_entity, "DamageModelComponent")
    if dmg then
        local hp = ComponentGetValue2(dmg, "hp")
        local max_hp = ComponentGetValue2(dmg, "max_hp")
        local max_hp_cap = ComponentGetValue2(dmg, "max_hp_cap")
        return tostring(hp) .. ";" .. tostring(max_hp) .. ";" .. tostring(max_hp_cap)
    end
    return ""
end

-- ============================================================
-- CAPTURE: Gold
-- ============================================================
local function capture_gold(player_entity)
    local wallet = EntityGetFirstComponentIncludingDisabled(player_entity, "WalletComponent")
    if wallet then
        return tostring(ComponentGetValue2(wallet, "money"))
    end
    return "0"
end

-- ============================================================
-- CAPTURE: Status Effects (wet, burning, poisoned, etc.)
-- Format: "EFFECT_NAME:frames;;;EFFECT_NAME2:frames2"
-- ============================================================
local function capture_effects(player_entity)
    local comps = EntityGetAllComponents(player_entity) or {}
    local effects = {}
    for _, comp in ipairs(comps) do
        if ComponentGetTypeName(comp) == "GameEffectComponent" then
            local effect_name = ComponentGetValue2(comp, "effect")
            local frames = ComponentGetValue2(comp, "frames")
            if effect_name and effect_name ~= "" then
                table.insert(effects, effect_name .. ":" .. tostring(frames))
            end
        end
    end
    return table.concat(effects, EFFECT_SEP)
end

-- ============================================================
-- CAPTURE: Spell charges for a single wand
-- Returns comma-separated uses_remaining values matching spell order
-- ============================================================
local function capture_spell_charges(wand_entity)
    local children = EntityGetAllChildren(wand_entity) or {}
    local charges = {}
    for _, spell in ipairs(children) do
        local item_comp = EntityGetFirstComponentIncludingDisabled(spell, "ItemComponent")
        if item_comp then
            local uses = ComponentGetValue2(item_comp, "uses_remaining")
            table.insert(charges, tostring(uses))
        else
            table.insert(charges, "-1")
        end
    end
    return table.concat(charges, ",")
end

-- ============================================================
-- CAPTURE: Wands
-- ============================================================
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
                -- Append spell charges after CHARGE_SEP
                local charges = capture_spell_charges(child)
                -- Capture inventory slot position for ordering
                local slot = 0
                local item_comp = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
                if item_comp then
                    slot = ComponentGetValue2(item_comp, "inventory_slot") or 0
                end
                return serialized .. CHARGE_SEP .. charges .. SLOT_SEP .. tostring(slot)
            end)
            if success and result then
                table.insert(wand_strings, result)
            end
        end
    end

    return table.concat(wand_strings, WAND_SEP)
end

-- ============================================================
-- CAPTURE: Items (non-wand inventory items)
-- Captures XML path + material contents for flasks/potions
-- ============================================================
-- ============================================================
-- HELPER: Serialize flask material contents as "name:count,name:count"
-- Uses CellFactory_GetName to convert material IDs to names for
-- reliable round-tripping via AddMaterialInventoryMaterial on restore.
-- ============================================================
local function serialize_flask_materials(entity_id)
    local mat_inv = EntityGetFirstComponentIncludingDisabled(entity_id, "MaterialInventoryComponent")
    if not mat_inv then return "" end

    local counts = ComponentGetValue2(mat_inv, "count_per_material_type")
    if not counts then return "" end

    -- count_per_material_type returns a table of counts indexed by (material_id + 1).
    -- We extract non-zero entries as "material_name:count" pairs using
    -- CellFactory_GetName for reliable round-tripping via AddMaterialInventoryMaterial.
    local materials = {}
    if type(counts) == "table" then
        for i, count in ipairs(counts) do
            if type(count) == "number" and count > 0 then
                local mat_name = CellFactory_GetName(i - 1)  -- table is 1-indexed, material IDs are 0-indexed
                if mat_name and mat_name ~= "" then
                    table.insert(materials, mat_name .. ":" .. tostring(math.floor(count)))
                end
            end
        end
    elseif type(counts) == "string" and counts ~= "" then
        -- Fallback: some Noita versions may return a comma-separated string
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
                -- Format: xml_path@@material_data
                table.insert(item_strings, xml_path .. MAT_SEP .. mat_data)
            end
        end
    end

    return table.concat(item_strings, ITEM_SEP)
end

-- ============================================================
-- CAPTURE: Loose spells (inventory_full - spell cards not on wands)
-- Spells are identified by action_id (not XML path), since they are
-- created dynamically via CreateItemActionEntity, not from XML files.
-- Format: "ACTION_ID@@uses_remaining<<<>>>ACTION_ID@@uses_remaining"
-- ============================================================
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
                if item_comp then
                    uses = ComponentGetValue2(item_comp, "uses_remaining") or -1
                end
                table.insert(spell_strings, action_id .. MAT_SEP .. tostring(uses))
            end
        end
    end

    return table.concat(spell_strings, SPELL_SEP)
end

-- ============================================================
-- HELPER: Safely convert a ComponentGetValue2 result to a string.
-- Some fields (stain_effects, ingestion_effects, count_per_material_type)
-- return tables instead of strings from ComponentGetValue2.
-- ============================================================
local function value_to_string(val)
    if val == nil then return "" end
    if type(val) == "string" then return val end
    if type(val) == "table" then
        -- Convert numeric table to comma-separated string
        local parts = {}
        for i, v in ipairs(val) do
            parts[i] = tostring(v)
        end
        return table.concat(parts, ",")
    end
    return tostring(val)
end

-- ============================================================
-- CAPTURE: Stains (StatusEffectDataComponent gameplay effects)
-- Visual pixel stains on the player sprite cannot be restored
-- from Lua, but the gameplay effects (fire extinguish, etc.) can.
-- Format: "stain_effects;;;ingestion_effects;;;extinguish_prob;;;stain_team"
-- ============================================================
local function capture_stains(player_entity)
    local comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if not comps or #comps == 0 then return "" end
    local comp = comps[1]
    local stain_effects = value_to_string(ComponentGetValue2(comp, "stain_effects"))
    local ingestion_effects = value_to_string(ComponentGetValue2(comp, "ingestion_effects"))
    local extinguish_prob = ComponentGetValue2(comp, "stain_effects_extinguish_fire_probability") or 0
    local stain_team = ComponentGetValue2(comp, "stain_team_id") or 0
    return stain_effects .. EFFECT_SEP .. ingestion_effects .. EFFECT_SEP
        .. tostring(extinguish_prob) .. EFFECT_SEP .. tostring(stain_team)
end

-- ============================================================
-- CAPTURE: Ingestion (materials eaten/drunk by the player)
-- Eating/drinking materials gives temporary effects (e.g.
-- worm blood gives worm perk). Tracked on IngestionComponent.
-- ============================================================
local function capture_ingestion(player_entity)
    local comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if not comps or #comps == 0 then return "" end
    local comp = comps[1]
    return value_to_string(ComponentGetValue2(comp, "count_per_material_type"))
end

-- ============================================================
-- CAPTURE: Player position
-- ============================================================
local function capture_position(player_entity)
    local x, y = EntityGetTransform(player_entity)
    if x and y then
        return tostring(x) .. ";" .. tostring(y)
    end
    return ""
end

-- ============================================================
-- CAPTURE SNAPSHOT: Main function
-- ============================================================
function godsaved_capture_snapshot()
    local players = EntityGetWithTag("player_unit")
    if #players == 0 then
        GamePrint("Godsaved: No player found!")
        return false
    end
    local player = players[1]

    -- Kill any duplicate player entities (keep only the first one)
    for i = 2, #players do
        EntityKill(players[i])
    end

    -- Capture all data
    local hp_data = capture_hp(player)
    local gold_data = capture_gold(player)
    local effects_data = capture_effects(player)
    local wand_data = capture_wands(player)
    local item_data = capture_items(player)
    local spell_data = capture_spells(player)
    local perk_data = godsaved_capture_perks()
    local pos_data = capture_position(player)
    local stain_data = capture_stains(player)
    local ingestion_data = capture_ingestion(player)

    -- Store via GlobalsSetValue
    GlobalsSetValue("godsaved_snapshot_exists", "1")
    GlobalsSetValue("godsaved_hp", hp_data)
    GlobalsSetValue("godsaved_gold", gold_data)
    GlobalsSetValue("godsaved_effects", effects_data)
    GlobalsSetValue("godsaved_wands", wand_data)
    GlobalsSetValue("godsaved_items", item_data)
    GlobalsSetValue("godsaved_spells", spell_data)
    GlobalsSetValue("godsaved_perks", perk_data)
    GlobalsSetValue("godsaved_position", pos_data)
    GlobalsSetValue("godsaved_stains", stain_data)
    GlobalsSetValue("godsaved_ingestion", ingestion_data)

    GamePrint("Godsaved: Snapshot saved!")
    return true
end

-- ============================================================
-- RESTORE: HP
-- ============================================================
local function restore_hp(player_entity, hp_string)
    if hp_string == "" then return end
    local parts = {}
    for part in hp_string:gmatch("[^;]+") do
        table.insert(parts, tonumber(part))
    end
    if #parts < 2 then return end

    local dmg = EntityGetFirstComponentIncludingDisabled(player_entity, "DamageModelComponent")
    if dmg then
        ComponentSetValue2(dmg, "max_hp", parts[2])
        ComponentSetValue2(dmg, "hp", parts[1])
        if parts[3] then
            ComponentSetValue2(dmg, "max_hp_cap", parts[3])
        end
    end
end

-- ============================================================
-- RESTORE: Gold
-- ============================================================
local function restore_gold(player_entity, gold_string)
    if gold_string == "" then return end
    local money = tonumber(gold_string)
    if not money then return end
    local wallet = EntityGetFirstComponentIncludingDisabled(player_entity, "WalletComponent")
    if wallet then
        ComponentSetValue2(wallet, "money", money)
    end
end

-- ============================================================
-- RESTORE: Status Effects
-- Removes all current effects, then applies saved ones
-- ============================================================
-- Names of child entities that must never be killed during effect cleanup
local PROTECTED_CHILDREN = {
    inventory_quick = true, inventory_full = true,
    arm_r = true, arm_l = true, cape = true,
}

local function clear_effects(player_entity)
    -- 1. Remove GameEffectComponents on the player entity itself
    local comps = EntityGetAllComponents(player_entity) or {}
    for _, comp in ipairs(comps) do
        if ComponentGetTypeName(comp) == "GameEffectComponent" then
            EntityRemoveComponent(player_entity, comp)
        end
    end

    -- 2. Kill child entities that carry GameEffectComponents
    --    (effects loaded via LoadGameEffectEntityTo are separate child entities)
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

    -- 3. Clear ingestion/stain material data so the game doesn't re-apply
    --    stain-based effects (bloody, oiled, wet, etc.)
    --    Note: count_per_material_type may be a table or string type depending
    --    on the Noita version. We try both approaches to ensure clearing works.
    local ingestion_comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if ingestion_comps then
        for _, comp in ipairs(ingestion_comps) do
            -- Try setting as empty string first, then as empty table
            pcall(ComponentSetValue2, comp, "count_per_material_type", "")
            pcall(ComponentSetValue2, comp, "count_per_material_type", {})
        end
    end

    -- 4. Clear StatusEffectDataComponent if present (tracks stain effect state)
    --    stain_effects and ingestion_effects may be table-typed fields.
    local status_data_comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if status_data_comps then
        for _, comp in ipairs(status_data_comps) do
            ComponentSetValue2(comp, "stain_effects_extinguish_fire_probability", 0)
            ComponentSetValue2(comp, "stain_team_id", 0)
            pcall(ComponentSetValue2, comp, "stain_effects", "")
            pcall(ComponentSetValue2, comp, "stain_effects", {})
            pcall(ComponentSetValue2, comp, "ingestion_effects", "")
            pcall(ComponentSetValue2, comp, "ingestion_effects", {})
        end
    end
end

local function restore_effects(player_entity, effects_string)
    -- Always clear current effects first
    clear_effects(player_entity)

    -- If snapshot had no effects, we're done (player is clean)
    if effects_string == "" then return end

    -- Parse and apply saved effects
    local pos = 1
    while true do
        local sep_start, sep_end = effects_string:find(EFFECT_SEP, pos, true)
        local entry
        if sep_start then
            entry = effects_string:sub(pos, sep_start - 1)
            pos = sep_end + 1
        else
            entry = effects_string:sub(pos)
        end

        if entry ~= "" then
            local colon = entry:find(":", 1, true)
            if colon then
                local effect_name = entry:sub(1, colon - 1)
                local frames = tonumber(entry:sub(colon + 1))
                if effect_name ~= "" and frames then
                    local effect_comp = GetGameEffectLoadTo(player_entity, effect_name, true)
                    if effect_comp then
                        ComponentSetValue2(effect_comp, "frames", frames)
                    end
                end
            end
        end

        if not sep_start then break end
    end
end

-- ============================================================
-- RESTORE: Stains (StatusEffectDataComponent)
-- Only restores if the restore_stains setting is enabled.
-- ============================================================
local function restore_stains(player_entity, stain_string)
    if stain_string == "" then return end

    -- Parse: stain_effects;;;ingestion_effects;;;extinguish_prob;;;stain_team
    local parts = {}
    local pos = 1
    while true do
        local sep_start, sep_end = stain_string:find(EFFECT_SEP, pos, true)
        if sep_start then
            table.insert(parts, stain_string:sub(pos, sep_start - 1))
            pos = sep_end + 1
        else
            table.insert(parts, stain_string:sub(pos))
            break
        end
    end

    if #parts < 4 then return end

    local comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if not comps or #comps == 0 then return end
    local comp = comps[1]
    -- stain_effects and ingestion_effects may be table-typed fields;
    -- try setting as string first, fall back to table of numbers
    pcall(ComponentSetValue2, comp, "stain_effects", parts[1])
    pcall(ComponentSetValue2, comp, "ingestion_effects", parts[2])
    ComponentSetValue2(comp, "stain_effects_extinguish_fire_probability", tonumber(parts[3]) or 0)
    ComponentSetValue2(comp, "stain_team_id", tonumber(parts[4]) or 0)
end

-- ============================================================
-- RESTORE: Ingestion (IngestionComponent material counts)
-- ============================================================
local function restore_ingestion(player_entity, ingestion_string)
    if ingestion_string == "" then return end

    local comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if not comps or #comps == 0 then return end
    local comp = comps[1]
    -- count_per_material_type may be a table-typed field;
    -- try setting as string first, fall back to table
    pcall(ComponentSetValue2, comp, "count_per_material_type", ingestion_string)
end

-- ============================================================
-- RESTORE: Spell charges on a wand after it has been created
-- ============================================================
local function restore_spell_charges(wand_entity, charges_string)
    if charges_string == "" then return end

    -- Parse charges into array
    local charges = {}
    for val in charges_string:gmatch("[^,]+") do
        table.insert(charges, tonumber(val))
    end

    -- Apply to wand's spell children in order
    local children = EntityGetAllChildren(wand_entity) or {}
    for i, spell in ipairs(children) do
        if charges[i] then
            local item_comp = EntityGetFirstComponentIncludingDisabled(spell, "ItemComponent")
            if item_comp then
                ComponentSetValue2(item_comp, "uses_remaining", charges[i])
            end
        end
    end
end

-- ============================================================
-- RESTORE: Clear current inventory (both quick and full)
-- ============================================================
local function clear_inventory(player_entity)
    -- Clear inventory_quick (wands + items)
    local inv_quick = get_inventory_quick(player_entity)
    if inv_quick then
        local children = EntityGetAllChildren(inv_quick) or {}
        for _, child in ipairs(children) do
            EntityKill(child)
        end
    end

    -- Clear inventory_full (spell actions not on wands)
    local inv_full = get_child_by_name(player_entity, "inventory_full")
    if inv_full then
        local children = EntityGetAllChildren(inv_full) or {}
        for _, child in ipairs(children) do
            EntityKill(child)
        end
    end
end

-- ============================================================
-- HELPER: Check if an entity is a child of the player's inventory
-- ============================================================
local function is_in_inventory(player_entity, entity_id)
    if not EntityGetIsAlive(entity_id) then return false end
    local parent = EntityGetParent(entity_id)
    if not parent or parent == 0 then return false end
    -- Check if parent is one of the player's inventory containers
    local inv_quick = get_inventory_quick(player_entity)
    local inv_full = get_child_by_name(player_entity, "inventory_full")
    return parent == inv_quick or parent == inv_full or parent == player_entity
end

-- ============================================================
-- RESTORE: Wands
-- ============================================================
local function restore_wands(player_entity, wand_string)
    if wand_string == "" then return end

    -- Spawn off-screen to avoid brief visual duplicates
    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    -- Split by WAND_SEP
    local wand_strs = {}
    local pos = 1
    while true do
        local sep_start, sep_end = wand_string:find(WAND_SEP, pos, true)
        if sep_start then
            table.insert(wand_strs, wand_string:sub(pos, sep_start - 1))
            pos = sep_end + 1
        else
            table.insert(wand_strs, wand_string:sub(pos))
            break
        end
    end

    for _, entry in ipairs(wand_strs) do
        if entry ~= "" then
            -- Split wand serialization from charge data and slot index
            -- Format: serialized|||charges###slot
            local charge_sep_pos = entry:find(CHARGE_SEP, 1, true)
            local serialized = entry
            local charges_string = ""
            local saved_slot = nil
            if charge_sep_pos then
                serialized = entry:sub(1, charge_sep_pos - 1)
                local rest = entry:sub(charge_sep_pos + #CHARGE_SEP)
                -- Split charges from slot index
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
                -- Restore spell charges before pickup
                if charges_string ~= "" then
                    restore_spell_charges(wand_entity, charges_string)
                end
                -- Use GamePickUpInventoryItem directly instead of EZWand's
                -- PutInPlayersInventory, which has a stale child count check
                -- that fails after clearing inventory in the same frame
                local item_comp = EntityGetFirstComponentIncludingDisabled(wand_entity, "ItemComponent")
                if item_comp then
                    ComponentSetValue2(item_comp, "has_been_picked_by_player", true)
                    -- Set saved inventory slot position to preserve wand order
                    if saved_slot then
                        ComponentSetValue2(item_comp, "inventory_slot", saved_slot)
                    end
                end
                GamePickUpInventoryItem(player_entity, wand_entity, false)
            end)
            -- Kill orphaned entity if pickup failed
            if not success then
                GamePrint("Godsaved: Failed to restore a wand: " .. tostring(err))
                if wand_entity and EntityGetIsAlive(wand_entity) then
                    EntityKill(wand_entity)
                end
            elseif wand_entity and not is_in_inventory(player_entity, wand_entity) then
                -- Pickup succeeded but entity didn't end up in inventory
                EntityKill(wand_entity)
                GamePrint("Godsaved: Wand cleanup - removed orphaned entity")
            end
        end
    end
end

-- ============================================================
-- RESTORE: Items
-- ============================================================
local function restore_items(player_entity, item_string)
    if item_string == "" then return end

    -- Spawn off-screen to avoid brief visual duplicates
    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    -- Split by ITEM_SEP
    local item_strs = {}
    local pos = 1
    while true do
        local sep_start, sep_end = item_string:find(ITEM_SEP, pos, true)
        if sep_start then
            table.insert(item_strs, item_string:sub(pos, sep_start - 1))
            pos = sep_end + 1
        else
            table.insert(item_strs, item_string:sub(pos))
            break
        end
    end

    -- Path to our custom flask XML (generated at mod init time in init.lua)
    local CUSTOM_FLASK_XML = "mods/noita-mod-godsaved/files/entities/godsaved_flask.xml"

    for _, entry in ipairs(item_strs) do
        if entry ~= "" then
            -- Parse: xml_path@@material_data
            local sep_pos = entry:find(MAT_SEP, 1, true)
            local xml_path = entry
            local mat_data = ""
            if sep_pos then
                xml_path = entry:sub(1, sep_pos - 1)
                mat_data = entry:sub(sep_pos + #MAT_SEP)
            end

            -- Determine which XML to load.
            -- For flasks (items with saved material data), use our custom flask XML
            -- whose init script reads from a global instead of randomizing.
            -- For non-flask items, use the original XML directly.
            local load_xml = xml_path
            if mat_data ~= "" then
                -- Signal to flask_init.lua what materials to fill with
                GlobalsSetValue("godsaved_flask_restore_materials", mat_data)
                load_xml = CUSTOM_FLASK_XML
            end

            local item_entity = nil
            local load_ok, load_err = pcall(function()
                item_entity = EntityLoad(load_xml, spawn_x, spawn_y)
            end)

            if not load_ok or not item_entity then
                -- Clear the global if load failed so it doesn't bleed into the next flask
                if mat_data ~= "" then
                    GlobalsSetValue("godsaved_flask_restore_materials", "")
                end
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

-- ============================================================
-- RESTORE: Loose spells (inventory_full)
-- Uses CreateItemActionEntity to recreate spells from action_id
-- ============================================================
local function restore_spells(player_entity, spell_string)
    if spell_string == "" then return end

    local px, py = EntityGetTransform(player_entity)
    local spawn_x, spawn_y = px, py - 1000

    -- Split by SPELL_SEP
    local spell_strs = {}
    local pos = 1
    while true do
        local sep_start, sep_end = spell_string:find(SPELL_SEP, pos, true)
        if sep_start then
            table.insert(spell_strs, spell_string:sub(pos, sep_start - 1))
            pos = sep_end + 1
        else
            table.insert(spell_strs, spell_string:sub(pos))
            break
        end
    end

    for _, entry in ipairs(spell_strs) do
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
                    -- Restore uses_remaining
                    if uses ~= -1 then
                        local item_comp = EntityGetFirstComponentIncludingDisabled(spell_entity, "ItemComponent")
                        if item_comp then
                            ComponentSetValue2(item_comp, "uses_remaining", uses)
                        end
                    end
                    GamePickUpInventoryItem(player_entity, spell_entity, false)
                end
            end)
            if not success then
                GamePrint("Godsaved: Failed to restore spell " .. action_id .. ": " .. tostring(err))
                if spell_entity and EntityGetIsAlive(spell_entity) then
                    EntityKill(spell_entity)
                end
            elseif spell_entity and not is_in_inventory(player_entity, spell_entity) then
                EntityKill(spell_entity)
                GamePrint("Godsaved: Spell cleanup - removed orphaned entity")
            end
        end
    end
end

-- ============================================================
-- RESTORE: Player position
-- ============================================================
local function restore_position(player_entity, pos_string)
    if pos_string == "" then return end
    local parts = {}
    for part in pos_string:gmatch("[^;]+") do
        table.insert(parts, tonumber(part))
    end
    if #parts >= 2 and parts[1] and parts[2] then
        EntitySetTransform(player_entity, parts[1], parts[2])
    end
end

-- ============================================================
-- RESTORE SNAPSHOT: Main function
-- ============================================================
function godsaved_restore_snapshot()
    if GlobalsGetValue("godsaved_snapshot_exists", "0") ~= "1" then
        GamePrint("Godsaved: No snapshot available!")
        return false
    end

    local players = EntityGetWithTag("player_unit")
    if #players == 0 then
        GamePrint("Godsaved: No player found!")
        return false
    end
    local player = players[1]

    -- Kill any duplicate player entities (keep only the first one)
    for i = 2, #players do
        EntityKill(players[i])
    end

    -- Read stored data
    local hp_data = GlobalsGetValue("godsaved_hp", "")
    local gold_data = GlobalsGetValue("godsaved_gold", "")
    local effects_data = GlobalsGetValue("godsaved_effects", "")
    local wand_data = GlobalsGetValue("godsaved_wands", "")
    local item_data = GlobalsGetValue("godsaved_items", "")
    local spell_data = GlobalsGetValue("godsaved_spells", "")
    local perk_data = GlobalsGetValue("godsaved_perks", "")
    local pos_data = GlobalsGetValue("godsaved_position", "")
    local stain_data = GlobalsGetValue("godsaved_stains", "")
    local ingestion_data = GlobalsGetValue("godsaved_ingestion", "")

    -- Step 1: Clear current inventory
    clear_inventory(player)

    -- Step 2: Restore HP
    restore_hp(player, hp_data)

    -- Step 3: Restore gold
    restore_gold(player, gold_data)

    -- Step 4: Restore wands (with spell charges and slot positions)
    restore_wands(player, wand_data)

    -- Step 5: Restore items
    restore_items(player, item_data)

    -- Step 6: Restore loose spells
    restore_spells(player, spell_data)

    -- Step 7: Restore player position
    restore_position(player, pos_data)

    -- Step 8: Clear all current perks (unconditional - always revert to snapshot state)
    godsaved_clear_perks(player)

    -- Step 9: Restore status effects (clears current + stains, applies saved)
    -- Done after inventory restore but before perk restore, so stain effects
    -- from spawning are cleared but perk effects won't be wiped
    restore_effects(player, effects_data)

    -- Step 10: Restore stains and ingestion (if enabled in settings)
    -- Done after effect clearing so we can write back the saved stain/ingestion
    -- state without it being immediately wiped
    if ModSettingGet("noita-mod-godsaved.restore_stains") then
        restore_stains(player, stain_data)
        restore_ingestion(player, ingestion_data)
    end

    -- Step 11: Restore perks LAST (if enabled in settings)
    -- Done after effect clearing so perk effects aren't wiped
    if ModSettingGet("noita-mod-godsaved.restore_perks") then
        local restored_count, failed = godsaved_restore_perks(player, perk_data)
        if #failed > 0 then
            GamePrint("Godsaved: Some perks failed to restore")
        else
            GamePrint("Godsaved: Restored " .. tostring(restored_count) .. " perks")
        end
    end

    -- Final cleanup: kill any duplicate player entities that may have been
    -- created during restore (e.g. from EntityLoad spawning tagged entities)
    local final_players = EntityGetWithTag("player_unit")
    for i = 2, #final_players do
        EntityKill(final_players[i])
    end

    GamePrint("Godsaved: Snapshot restored!")
    return true
end

-- ============================================================
-- CHECK: Does a snapshot exist?
-- ============================================================
function godsaved_has_snapshot()
    return GlobalsGetValue("godsaved_snapshot_exists", "0") == "1"
end
