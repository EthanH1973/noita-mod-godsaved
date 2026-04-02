-- snapshot.lua: Core snapshot capture and restore logic for godsaved mod

local EZWand = dofile_once("mods/godsaved/files/scripts/lib/ezwand.lua")
dofile_once("mods/godsaved/files/scripts/perk_utils.lua")

-- Separator constants (chosen to avoid conflicts with EZWand's ";" separator)
local WAND_SEP = "<<<>>>"  -- between wands
local ITEM_SEP = "<<<>>>"  -- between items
local MAT_SEP = "@@"       -- between xml_path and material data within an item

-- ============================================================
-- HELPER: Get the inventory_quick entity
-- ============================================================
local function get_inventory_quick(player_entity)
    local children = EntityGetAllChildren(player_entity) or {}
    for _, child in ipairs(children) do
        if EntityGetName(child) == "inventory_quick" then
            return child
        end
    end
    return nil
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
                return w:Serialize()
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
-- CAPTURE SNAPSHOT: Main function
-- ============================================================
function godsaved_capture_snapshot()
    local players = EntityGetWithTag("player_unit")
    if #players == 0 then
        GamePrint("Godsaved: No player found!")
        return false
    end
    local player = players[1]

    -- Capture all data
    local hp_data = capture_hp(player)
    local wand_data = capture_wands(player)
    local item_data = capture_items(player)
    local perk_data = godsaved_capture_perks()

    -- Store via GlobalsSetValue
    GlobalsSetValue("godsaved_snapshot_exists", "1")
    GlobalsSetValue("godsaved_hp", hp_data)
    GlobalsSetValue("godsaved_wands", wand_data)
    GlobalsSetValue("godsaved_items", item_data)
    GlobalsSetValue("godsaved_perks", perk_data)

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
-- RESTORE: Clear current inventory
-- ============================================================
local function clear_inventory(player_entity)
    local inv = get_inventory_quick(player_entity)
    if not inv then return end

    local children = EntityGetAllChildren(inv) or {}
    for _, child in ipairs(children) do
        EntityKill(child)
    end
end

-- ============================================================
-- RESTORE: Wands
-- ============================================================
local function restore_wands(player_entity, wand_string)
    if wand_string == "" then return end

    local px, py = EntityGetTransform(player_entity)

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

    for _, serialized in ipairs(wand_strs) do
        if serialized ~= "" then
            local success, err = pcall(function()
                -- EZWand(serialized_string) creates a wand entity from the string
                local w = EZWand(serialized, px, py)
                w:PutInPlayersInventory()
            end)
            if not success then
                GamePrint("Godsaved: Failed to restore a wand: " .. tostring(err))
            end
        end
    end
end

-- ============================================================
-- RESTORE: Items
-- ============================================================
local function restore_items(player_entity, item_string)
    if item_string == "" then return end

    local px, py = EntityGetTransform(player_entity)

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

            local success, err = pcall(function()
                local item_entity = EntityLoad(xml_path, px, py)
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
            if not success then
                GamePrint("Godsaved: Failed to restore an item: " .. tostring(err))
            end
        end
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

    -- Read stored data
    local hp_data = GlobalsGetValue("godsaved_hp", "")
    local wand_data = GlobalsGetValue("godsaved_wands", "")
    local item_data = GlobalsGetValue("godsaved_items", "")
    local perk_data = GlobalsGetValue("godsaved_perks", "")

    -- Step 1: Clear current inventory
    clear_inventory(player)

    -- Step 2: Restore HP
    restore_hp(player, hp_data)

    -- Step 3: Restore wands
    restore_wands(player, wand_data)

    -- Step 4: Restore items
    restore_items(player, item_data)

    -- Step 5: Restore perks (if enabled in settings)
    if ModSettingGet("godsaved.restore_perks") then
        local restored_count, failed = godsaved_restore_perks(player, perk_data)
        if #failed > 0 then
            GamePrint("Godsaved: Some perks failed to restore")
        else
            GamePrint("Godsaved: Restored " .. tostring(restored_count) .. " perks")
        end
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
