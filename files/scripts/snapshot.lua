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
local function capture_items(player_entity)
    local inv = get_inventory_quick(player_entity)
    if not inv then return "" end

    local children = EntityGetAllChildren(inv) or {}
    local item_strings = {}

    for _, child in ipairs(children) do
        if not is_wand(child) then
            local xml_path = EntityGetFilename(child) or ""
            if xml_path ~= "" then
                -- Check for material inventory (flasks/potions)
                local mat_inv = EntityGetFirstComponentIncludingDisabled(child, "MaterialInventoryComponent")
                local mat_data = ""
                if mat_inv then
                    -- Get material counts - this returns a table of counts indexed by material ID
                    local counts = ComponentGetValue2(mat_inv, "count_per_material_type")
                    if counts and type(counts) == "string" and counts ~= "" then
                        mat_data = counts
                    end
                end
                -- Format: xml_path|material_data
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
    local ingestion_comps = EntityGetComponentIncludingDisabled(player_entity, "IngestionComponent")
    if ingestion_comps then
        for _, comp in ipairs(ingestion_comps) do
            ComponentSetValue2(comp, "count_per_material_type", "")
        end
    end

    -- 4. Clear StatusEffectDataComponent if present (tracks stain effect state)
    local status_data_comps = EntityGetComponentIncludingDisabled(player_entity, "StatusEffectDataComponent")
    if status_data_comps then
        for _, comp in ipairs(status_data_comps) do
            ComponentSetValue2(comp, "stain_effects_extinguish_fire_probability", 0)
            ComponentSetValue2(comp, "stain_team_id", 0)
            ComponentSetValue2(comp, "stain_effects", "")
            ComponentSetValue2(comp, "ingestion_effects", "")
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

            local item_entity = nil
            local success, err = pcall(function()
                item_entity = EntityLoad(xml_path, spawn_x, spawn_y)
                if item_entity then
                    -- Restore material contents if present
                    if mat_data ~= "" then
                        local mat_inv = EntityGetFirstComponentIncludingDisabled(item_entity, "MaterialInventoryComponent")
                        if mat_inv then
                            ComponentSetValue2(mat_inv, "count_per_material_type", mat_data)
                        end
                    end
                    GamePickUpInventoryItem(player_entity, item_entity, false)
                end
            end)
            -- Kill orphaned entity if pickup failed
            if not success then
                GamePrint("Godsaved: Failed to restore an item: " .. tostring(err))
                if item_entity and EntityGetIsAlive(item_entity) then
                    EntityKill(item_entity)
                end
            elseif item_entity and not is_in_inventory(player_entity, item_entity) then
                EntityKill(item_entity)
                GamePrint("Godsaved: Item cleanup - removed orphaned entity")
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

    -- Step 10: Restore perks LAST (if enabled in settings)
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
