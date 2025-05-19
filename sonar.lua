_G.sonar_loader_flag_v1_11 = (_G.sonar_loader_flag_v1_11 or 0) + 1
_G.sonar_tick_counter = 0

local ui_sonar_panel, ui_enable_sonar_checkbox, 
      ui_sensitivity_slider, ui_dynamic_cooldown_checkbox, 
      ui_only_through_walls_checkbox

local data_reader_initialized = false
local last_beep_time = 0

local OFFSETS = {
    CCSPlayerController = { m_hPlayerPawn = nil },
    C_CSPlayerPawn = {
        m_vOldOrigin = nil, m_iTeamNum = nil, m_iHealth = nil,
        m_angEyeAngles = nil, m_pGameSceneNode = nil, m_entitySpottedState = nil
    },
    EntitySpottedState_t = { m_bSpotted = 0x8 },
    CGameSceneNode = { m_vecAbsOrigin = nil }
}

local SONAR_CONFIG = {
    enabled = true,
    sensitivity_threshold = 0.995,
    sound_file_path = "beep.mp3",
    static_beep_cooldown_ms = 250,
    dynamic_cooldown_enabled = true,
    min_cooldown_ms = 200,
    max_cooldown_ms = 1000,
    max_distance_for_min_cooldown = 500,
    min_distance_for_max_cooldown = 2000,
    only_through_walls = true
}

local function mem_read_int(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    return proc.read_int32(base + offset)
end

local function mem_read_qword(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    if proc.read_address then return proc.read_address(base + offset)
    elseif proc.read_int64 then return proc.read_int64(base + offset) end
    return proc.read_int32(base + offset) -- Fallback
end

local function mem_read_byte(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    return proc.read_int8(base + offset)
end

local function mem_read_bool(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    local val = proc.read_int8(base + offset) -- Assuming bool is stored as byte 0 or 1
    if val == nil then return nil end
    return val ~= 0
end

local function mem_read_float(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    return proc.read_float(base + offset)
end

local function mem_read_vector(base, offset)
    if not proc.is_attached() or not base or base == 0 or offset == nil then return nil end
    local x = proc.read_float(base + offset)
    local y = proc.read_float(base + offset + 4)
    local z = proc.read_float(base + offset + 8)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function initialize_offsets()
    if data_reader_initialized then return true end
    if not (cs2 and cs2.get_schema_dump and proc and proc.is_attached and proc.is_attached()) then return false end

    local dump = cs2.get_schema_dump()
    if not dump then return false end

    local parsed_schema = {}
    for _, entry in ipairs(dump) do
        local class_name, field_name = entry.name:match("(.*)::(.*)")
        if class_name and field_name then
            if not parsed_schema[class_name] then parsed_schema[class_name] = {} end
            parsed_schema[class_name][field_name] = entry.offset
        end
    end

    local all_found_crit = true
    OFFSETS.CCSPlayerController.m_hPlayerPawn = parsed_schema["CCSPlayerController"] and parsed_schema["CCSPlayerController"]["m_hPlayerPawn"] or nil
    if not OFFSETS.CCSPlayerController.m_hPlayerPawn then all_found_crit = false end

    local pawn_classes = {"C_CSPlayerPawn", "C_CSPlayerPawnBase", "C_BasePlayerPawn", "C_BaseEntity"}
    local function find_schema_offset(field, is_critical)
        is_critical = is_critical == nil and true or is_critical
        for _, class_name in ipairs(pawn_classes) do
            if parsed_schema[class_name] and parsed_schema[class_name][field] then
                return parsed_schema[class_name][field]
            end
        end
        if is_critical then all_found_crit = false end
        return nil
    end

    OFFSETS.C_CSPlayerPawn.m_vOldOrigin = find_schema_offset("m_vOldOrigin", false)
    OFFSETS.C_CSPlayerPawn.m_iTeamNum = find_schema_offset("m_iTeamNum")
    OFFSETS.C_CSPlayerPawn.m_iHealth = find_schema_offset("m_iHealth")
    OFFSETS.C_CSPlayerPawn.m_angEyeAngles = find_schema_offset("m_angEyeAngles")
    OFFSETS.C_CSPlayerPawn.m_pGameSceneNode = find_schema_offset("m_pGameSceneNode", false)
    OFFSETS.C_CSPlayerPawn.m_entitySpottedState = find_schema_offset("m_entitySpottedState", false)

    if not OFFSETS.C_CSPlayerPawn.m_vOldOrigin and not OFFSETS.C_CSPlayerPawn.m_pGameSceneNode then all_found_crit = false end

    if OFFSETS.C_CSPlayerPawn.m_pGameSceneNode and parsed_schema["CGameSceneNode"] then
        OFFSETS.CGameSceneNode.m_vecAbsOrigin = parsed_schema["CGameSceneNode"]["m_vecAbsOrigin"]
        if not OFFSETS.CGameSceneNode.m_vecAbsOrigin and not OFFSETS.C_CSPlayerPawn.m_vOldOrigin then all_found_crit = false end
    elseif OFFSETS.C_CSPlayerPawn.m_pGameSceneNode and not OFFSETS.C_CSPlayerPawn.m_vOldOrigin then
        all_found_crit = false
    end

    local can_use_spotted_feature = OFFSETS.C_CSPlayerPawn.m_entitySpottedState ~= nil and OFFSETS.EntitySpottedState_t.m_bSpotted ~= nil
    if not can_use_spotted_feature and SONAR_CONFIG.only_through_walls then
        SONAR_CONFIG.only_through_walls = false
        if ui_only_through_walls_checkbox then ui_only_through_walls_checkbox:set(false) end
    end
    
    if ui_only_through_walls_checkbox and ui_only_through_walls_checkbox.set_enabled and not can_use_spotted_feature then
        ui_only_through_walls_checkbox:set_enabled(false)
    end

    data_reader_initialized = all_found_crit
    return all_found_crit
end

local function angle_to_direction(angles)
    if not angles or angles.x == nil or angles.y == nil then return { x = 0, y = 1, z = 0 } end
    local pitch_rad, yaw_rad = math.rad(angles.x), math.rad(angles.y)
    local cos_pitch, sin_pitch = math.cos(pitch_rad), math.sin(pitch_rad)
    local cos_yaw, sin_yaw = math.cos(yaw_rad), math.sin(yaw_rad)
    return { x = cos_pitch * cos_yaw, y = cos_pitch * sin_yaw, z = -sin_pitch }
end

local function get_pawn_from_handle(handle)
    if not handle or handle == 0 then return 0 end
    local entity_list = cs2.get_entity_list()
    if entity_list == 0 then return 0 end
    local entry_idx = handle & 0x7FFF
    if entry_idx == 0x7FFF then return 0 end
    local chunk_idx, offset_in_chunk = entry_idx >> 9, entry_idx & 0x1FF
    local chunk_ptr = mem_read_qword(entity_list + (8 * chunk_idx) + 16, 0)
    if not chunk_ptr or chunk_ptr == 0 then return 0 end
    return mem_read_qword(chunk_ptr + (120 * offset_in_chunk), 0)
end

local function update_settings_from_ui()
    if ui_enable_sonar_checkbox then SONAR_CONFIG.enabled = ui_enable_sonar_checkbox:get() end
    if ui_sensitivity_slider then SONAR_CONFIG.sensitivity_threshold = ui_sensitivity_slider:get() / 1000.0 end
    if ui_dynamic_cooldown_checkbox then SONAR_CONFIG.dynamic_cooldown_enabled = ui_dynamic_cooldown_checkbox:get() end
    if ui_only_through_walls_checkbox then
        local can_use = OFFSETS.C_CSPlayerPawn.m_entitySpottedState ~= nil and OFFSETS.EntitySpottedState_t.m_bSpotted ~= nil
        if can_use then
            SONAR_CONFIG.only_through_walls = ui_only_through_walls_checkbox:get()
        else
            SONAR_CONFIG.only_through_walls = false
            ui_only_through_walls_checkbox:set(false)
            if ui_only_through_walls_checkbox.set_enabled then ui_only_through_walls_checkbox:set_enabled(false) end
        end
    end
end

local function get_dynamic_cooldown(distance)
    if not SONAR_CONFIG.dynamic_cooldown_enabled then return SONAR_CONFIG.static_beep_cooldown_ms end
    if distance <= SONAR_CONFIG.max_distance_for_min_cooldown then return SONAR_CONFIG.min_cooldown_ms
    elseif distance >= SONAR_CONFIG.min_distance_for_max_cooldown then return SONAR_CONFIG.max_cooldown_ms
    else
        local dist_range = SONAR_CONFIG.min_distance_for_max_cooldown - SONAR_CONFIG.max_distance_for_min_cooldown
        if dist_range <= 0 then return SONAR_CONFIG.min_cooldown_ms end
        local progress = (distance - SONAR_CONFIG.max_distance_for_min_cooldown) / dist_range
        return math.floor(SONAR_CONFIG.min_cooldown_ms + ((SONAR_CONFIG.max_cooldown_ms - SONAR_CONFIG.min_cooldown_ms) * progress))
    end
end

local function main_tick()
    if _G.sonar_tick_counter == nil then _G.sonar_tick_counter = 0 end
    _G.sonar_tick_counter = _G.sonar_tick_counter + 1

    if not data_reader_initialized and not initialize_offsets() then return end

    if not ui_sonar_panel then
        if gui and gui.get_tab then
            local tab = gui.get_tab("lua")
            if tab then
                ui_sonar_panel = tab:create_panel("Sonar [UFO]", true)
                if ui_sonar_panel then
                    ui_enable_sonar_checkbox = ui_sonar_panel:add_checkbox("Enable Sonar")
                    ui_enable_sonar_checkbox:set(SONAR_CONFIG.enabled)

                    ui_sensitivity_slider = ui_sonar_panel:add_slider_int("Aim Precision (950-999)", 950, 999, math.floor(SONAR_CONFIG.sensitivity_threshold * 1000))
                    
                    ui_dynamic_cooldown_checkbox = ui_sonar_panel:add_checkbox("Dynamic Cooldown")
                    ui_dynamic_cooldown_checkbox:set(SONAR_CONFIG.dynamic_cooldown_enabled)
                    
                    ui_only_through_walls_checkbox = ui_sonar_panel:add_checkbox("Beep Only Through Walls")
                    local can_use_spotting_feature = OFFSETS.C_CSPlayerPawn.m_entitySpottedState ~= nil and OFFSETS.EntitySpottedState_t.m_bSpotted ~= nil
                    ui_only_through_walls_checkbox:set(SONAR_CONFIG.only_through_walls and can_use_spotting_feature)
                    if not can_use_spotting_feature and ui_only_through_walls_checkbox.set_enabled then
                        ui_only_through_walls_checkbox:set_enabled(false)
                    end
                end
            end
        end
    end

    update_settings_from_ui()
    if not SONAR_CONFIG.enabled then return end

    local current_time = winapi.get_tickcount64()
    if not proc.is_attached() or proc.did_exit() then return end

    local local_player = cs2.get_local_player()
    if not local_player or not local_player.pawn or local_player.pawn == 0 then return end
    
    local local_pawn, local_controller = local_player.pawn, local_player.controller

    local local_pos
    if OFFSETS.C_CSPlayerPawn.m_vOldOrigin then
        local_pos = mem_read_vector(local_pawn, OFFSETS.C_CSPlayerPawn.m_vOldOrigin)
    elseif OFFSETS.C_CSPlayerPawn.m_pGameSceneNode and OFFSETS.CGameSceneNode.m_vecAbsOrigin then
        local scene_node = mem_read_qword(local_pawn, OFFSETS.C_CSPlayerPawn.m_pGameSceneNode)
        if scene_node and scene_node ~= 0 then
            local_pos = mem_read_vector(scene_node, OFFSETS.CGameSceneNode.m_vecAbsOrigin)
        end
    end
    
    local local_view_angles = mem_read_vector(local_pawn, OFFSETS.C_CSPlayerPawn.m_angEyeAngles)
    if not local_pos or not local_view_angles then return end

    local local_view_dir = angle_to_direction(local_view_angles)
    local local_team_id = mem_read_byte(local_pawn, OFFSETS.C_CSPlayerPawn.m_iTeamNum)
    if local_team_id == nil then return end

    local entity_list_ptr = cs2.get_entity_list()
    if entity_list_ptr == 0 then return end

    local aimed_enemy_info = nil

    for i = 0, 127 do
        local controller_addr = 0
        local chunk_ptr = mem_read_qword(entity_list_ptr + ((8 * (i & 0x7FFF)) >> 9) + 16, 0)
        if chunk_ptr and chunk_ptr ~= 0 then
            controller_addr = mem_read_qword(chunk_ptr + (120 * (i & 0x1FF)), 0)
        end
        if not controller_addr or controller_addr == 0 then goto next_entity end
        if local_controller and controller_addr == local_controller then goto next_entity end

        local pawn_handle = mem_read_int(controller_addr, OFFSETS.CCSPlayerController.m_hPlayerPawn)
        if not pawn_handle or pawn_handle == 0 then goto next_entity end

        local pawn_addr = get_pawn_from_handle(pawn_handle)
        if not pawn_addr or pawn_addr == 0 or pawn_addr == local_pawn then goto next_entity end

        local health = mem_read_byte(pawn_addr, OFFSETS.C_CSPlayerPawn.m_iHealth)
        local team_id = mem_read_byte(pawn_addr, OFFSETS.C_CSPlayerPawn.m_iTeamNum)
        if not health or health <= 0 or not team_id or team_id == local_team_id then goto next_entity end

        local is_target_spotted = false
        if OFFSETS.C_CSPlayerPawn.m_entitySpottedState and OFFSETS.EntitySpottedState_t.m_bSpotted then
            local spotted_state_addr = pawn_addr + OFFSETS.C_CSPlayerPawn.m_entitySpottedState
            is_target_spotted = mem_read_bool(spotted_state_addr, OFFSETS.EntitySpottedState_t.m_bSpotted)
            if is_target_spotted == nil then is_target_spotted = false end
        end

        if SONAR_CONFIG.only_through_walls and is_target_spotted and 
           (OFFSETS.C_CSPlayerPawn.m_entitySpottedState and OFFSETS.EntitySpottedState_t.m_bSpotted) then
            goto next_entity
        end

        local target_pos
        if OFFSETS.C_CSPlayerPawn.m_vOldOrigin then
            target_pos = mem_read_vector(pawn_addr, OFFSETS.C_CSPlayerPawn.m_vOldOrigin)
        elseif OFFSETS.C_CSPlayerPawn.m_pGameSceneNode and OFFSETS.CGameSceneNode.m_vecAbsOrigin then
            local scene_node = mem_read_qword(pawn_addr, OFFSETS.C_CSPlayerPawn.m_pGameSceneNode)
            if scene_node and scene_node ~= 0 then
                target_pos = mem_read_vector(scene_node, OFFSETS.CGameSceneNode.m_vecAbsOrigin)
            end
        end
        if not target_pos then goto next_entity end

        local vec_to_target = { x = target_pos.x - local_pos.x, y = target_pos.y - local_pos.y, z = target_pos.z - local_pos.z }
        local dist_sq = vec_to_target.x^2 + vec_to_target.y^2 + vec_to_target.z^2
        if dist_sq < 0.0001 then goto next_entity end
        
        local distance = math.sqrt(dist_sq)
        local norm_vec_to_target = { x = vec_to_target.x / distance, y = vec_to_target.y / distance, z = vec_to_target.z / distance }
        
        local dot_product = local_view_dir.x * norm_vec_to_target.x + 
                              local_view_dir.y * norm_vec_to_target.y + 
                              local_view_dir.z * norm_vec_to_target.z

        if dot_product > SONAR_CONFIG.sensitivity_threshold then
            aimed_enemy_info = { pawn_addr = pawn_addr, distance = distance }
            break 
        end
        ::next_entity::
    end

    if aimed_enemy_info then
        local cooldown = get_dynamic_cooldown(aimed_enemy_info.distance)
        if (current_time - last_beep_time > cooldown) then
            if winapi and winapi.play_sound then
                winapi.play_sound(SONAR_CONFIG.sound_file_path)
            end
            last_beep_time = current_time
        end
    end
end

local function on_load()
    _G.sonar_tick_counter = 0
    last_beep_time = 0
    data_reader_initialized = false
    ui_sonar_panel = nil 
    
    if initialize_offsets() then
        if proc.is_attached() then
            if engine and engine.register_on_engine_tick then
                engine.register_on_engine_tick(main_tick)
                engine.log("[UFO] Sonar loaded.", 0, 200, 255, 255)
            end
        end
    end
end

on_load()