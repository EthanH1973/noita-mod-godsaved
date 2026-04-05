-- perk_utils.lua: Perk capture and restore helpers for godsaved mod

dofile_once("data/scripts/perks/perk_list.lua")
dofile_once("data/scripts/perks/perk.lua")

-- Capture all picked perks and their counts
-- Returns a string like "PERK_ID:count,PERK_ID2:count,..."
function godsaved_capture_perks()
    local captured = {}
    for _, perk in ipairs(perk_list) do
        local perk_id = perk.id
        if GameHasFlagRun("PERK_PICKED_" .. perk_id) then
            -- Count how many times this perk was picked (for stackable perks)
            local count = 1
            if perk.stackable == STACKABLE_YES then
                -- Check for additional picks via numbered flags
                for n = 2, (perk.stackable_maximum or 128) do
                    if GameHasFlagRun("PERK_PICKED_" .. perk_id .. "_" .. tostring(n)) then
                        count = n
                    else
                        break
                    end
                end
            end
            table.insert(captured, perk_id .. ":" .. tostring(count))
        end
    end
    return table.concat(captured, ",")
end

-- Parse a perk string back into a table of {id, count} pairs
function godsaved_parse_perks(perk_string)
    if perk_string == nil or perk_string == "" then
        return {}
    end
    local perks = {}
    for entry in perk_string:gmatch("[^,]+") do
        local id, count_str = entry:match("^(.+):(%d+)$")
        if id then
            table.insert(perks, { id = id, count = tonumber(count_str) })
        end
    end
    return perks
end

-- Find a perk definition by ID in the global perk_list
function godsaved_find_perk(perk_id)
    for _, perk in ipairs(perk_list) do
        if perk.id == perk_id then
            return perk
        end
    end
    return nil
end

-- Names of child entities that must never be killed during perk cleanup
local PERK_PROTECTED_CHILDREN = {
    inventory_quick = true, inventory_full = true,
    arm_r = true, arm_l = true, cape = true,
}

-- Clear all perk flags and remove permanent perk effects from the player
-- Called unconditionally during restore to revert to snapshot state
function godsaved_clear_perks(player_entity)
    -- Remove all PERK_PICKED flags
    for _, perk in ipairs(perk_list) do
        local perk_id = perk.id
        GameRemoveFlagRun("PERK_PICKED_" .. perk_id)
        -- Remove numbered flags for stackable perks
        if perk.stackable == STACKABLE_YES then
            for n = 2, (perk.stackable_maximum or 128) do
                local flag = "PERK_PICKED_" .. perk_id .. "_" .. tostring(n)
                if GameHasFlagRun(flag) then
                    GameRemoveFlagRun(flag)
                else
                    break
                end
            end
        end
    end

    -- Remove permanent perk game effects (frames == -1) from the player entity
    local comps = EntityGetAllComponents(player_entity) or {}
    for _, comp in ipairs(comps) do
        if ComponentGetTypeName(comp) == "GameEffectComponent" then
            local frames = ComponentGetValue2(comp, "frames")
            if frames == -1 then
                EntityRemoveComponent(player_entity, comp)
            end
        end
    end

    -- Kill child entities that carry permanent perk effects (frames == -1)
    -- Perks loaded via LoadGameEffectEntityTo create child entities with
    -- GameEffectComponents. These must also be removed.
    local children = EntityGetAllChildren(player_entity) or {}
    for _, child in ipairs(children) do
        local name = EntityGetName(child) or ""
        if not PERK_PROTECTED_CHILDREN[name] then
            local child_comps = EntityGetAllComponents(child) or {}
            for _, comp in ipairs(child_comps) do
                if ComponentGetTypeName(comp) == "GameEffectComponent" then
                    local frames = ComponentGetValue2(comp, "frames")
                    if frames == -1 then
                        EntityKill(child)
                        break
                    end
                end
            end
        end
    end
end

-- Restore perks to the player entity
-- This calls each perk's func() which may have side effects
function godsaved_restore_perks(player_entity, perk_string)
    local perks = godsaved_parse_perks(perk_string)
    local restored_count = 0
    local failed = {}

    for _, perk_entry in ipairs(perks) do
        local perk_data = godsaved_find_perk(perk_entry.id)
        if perk_data then
            for i = 1, perk_entry.count do
                local success, err = pcall(function()
                    -- Set the pickup flag
                    if i == 1 then
                        GameAddFlagRun("PERK_PICKED_" .. perk_entry.id)
                    else
                        GameAddFlagRun("PERK_PICKED_" .. perk_entry.id .. "_" .. tostring(i))
                    end

                    -- Call the perk's func() to apply its effect
                    if perk_data.func then
                        perk_data.func(0, player_entity, perk_entry.id)
                    end

                    -- Apply game_effect if specified
                    if perk_data.game_effect and perk_data.game_effect ~= "" then
                        local effect = GetGameEffectLoadTo(player_entity, perk_data.game_effect, true)
                        if effect then
                            ComponentSetValue2(effect, "frames", -1)
                        end
                    end
                end)

                if success then
                    restored_count = restored_count + 1
                else
                    table.insert(failed, perk_entry.id .. ": " .. tostring(err))
                end
            end
        else
            table.insert(failed, perk_entry.id .. ": perk not found")
        end
    end

    return restored_count, failed
end
