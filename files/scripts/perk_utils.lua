-- perk_utils.lua: Perk capture and load helpers for godsaved mod

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

-- Load perks onto the player entity
-- This calls each perk's func() which may have side effects
function godsaved_load_perks(player_entity, perk_string)
    local perks = godsaved_parse_perks(perk_string)
    local loaded_count = 0
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
                    loaded_count = loaded_count + 1
                else
                    table.insert(failed, perk_entry.id .. ": " .. tostring(err))
                end
            end
        else
            table.insert(failed, perk_entry.id .. ": perk not found")
        end
    end

    return loaded_count, failed
end
