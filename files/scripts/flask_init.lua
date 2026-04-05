-- flask_init.lua: Custom init script for godsaved restored flasks.
-- Called instead of the vanilla randomizing potion init script.
-- Reads saved material data from a global set by restore_items()
-- and fills the flask with exact saved contents via AddMaterialInventoryMaterial.

function init(entity_id)
    local mat_data = GlobalsGetValue("godsaved_flask_restore_materials", "")
    if mat_data == "" then return end

    -- Clear the global immediately so it doesn't bleed into other flask loads
    GlobalsSetValue("godsaved_flask_restore_materials", "")

    -- Parse "material_name:count,material_name:count" and add each material
    for mat_entry in mat_data:gmatch("[^,]+") do
        local colon = mat_entry:find(":", 1, true)
        if colon then
            local mat_name = mat_entry:sub(1, colon - 1)
            local mat_count = tonumber(mat_entry:sub(colon + 1)) or 0
            if mat_name ~= "" and mat_count > 0 then
                AddMaterialInventoryMaterial(entity_id, mat_name, mat_count)
            end
        end
    end
end
