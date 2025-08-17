-- UFOSTRAFER (optimizer)
-- by Kava for perception.cx
local flags_offset, velocity_offset
local KEY_A = 0x41
local KEY_D = 0x44

local SMART_STRAFE_LEVELS = {
    { Speed = 500, Mod = 1.3 }, { Speed = 600, Mod = 1.2 },
    { Speed = 900, Mod = 1.1 }, { Speed = 1200, Mod = 0.8 },
    { Speed = 1500, Mod = 0.7 }
}
local DEFAULT_MODIFIER = 0.3

-- ui
ui = {}
local tab = gui.get_tab("lua")
ui.panel = tab:create_panel("UFOSTRAFER", false)
ui.enabled = ui.panel:add_checkbox("Enable UFOSTRAFER")
ui.panel:add_text("Keybind")
ui.master_toggle = ui.panel:add_keybind("Keybind", 0x79, key_mode.toggle)
ui.panel:add_text("")

ui.min_speed = ui.panel:add_slider_int("Min Speed to Strafe", 200, 400, 278)
ui.strength = ui.panel:add_slider_int("Base Strength (1-20)", 1, 20, 5)
ui.smooth_strafe = ui.panel:add_checkbox("Enable Smooth Strafe")
ui.smooth_factor = ui.panel:add_slider_int("Smooth Steps (1-50)", 1, 50, 5)
ui.angle = ui.panel:add_slider_int("Base Strafe Angle (-89 to 89)", -89, 89, 0)
ui.smart_strafe = ui.panel:add_checkbox("Enable Smart Strafes")
ui.angle_jitter = ui.panel:add_checkbox("Enable Angle Jitter")
ui.jitter_strength = ui.panel:add_slider_int("Jitter Strength (0-45 deg)", 0, 45, 3)
ui.progressive_strength = ui.panel:add_checkbox("Enable Progressive Strength")
ui.progressive_max_time = ui.panel:add_slider_int("Max Hold Time (100-2000 ms)", 100, 2000, 500)
ui.progressive_start_factor = ui.panel:add_slider_int("Start Strength (0-100%)", 0, 100, 20)

-- default values
ui.enabled:set(true)
ui.smooth_strafe:set(true)
ui.smart_strafe:set(true)
ui.angle_jitter:set(true)
ui.progressive_strength:set(true)

-- strafe state
local state = {
    current_strength = 0, target_strength = 0, norm_dx = 0, norm_dy = 0,
    last_a_down = false, last_d_down = false, direction = nil, key_hold_start_time = 0
}

local notification = { text = "", color = { 255, 255, 255 }, end_time = 0, active = false }
local was_master_toggle_active = false
local font = render.create_font("Verdana", 12, 700)

local function round(num)
    return math.floor(num + 0.5)
end

engine.register_on_engine_tick(function()
    -- one time offset grab
    if not flags_offset then
        pcall(function()
            local schema = cs2.get_schema_dump()
            for _, entry in ipairs(schema) do
                if entry.name == "C_BaseEntity::m_fFlags" then flags_offset = entry.offset end
                if entry.name == "C_BaseEntity::m_vecVelocity" then velocity_offset = entry.offset end
                if flags_offset and velocity_offset then break end
            end
            if not (flags_offset and velocity_offset) then error("could not find offsets, fuck") end
        end)
        if not flags_offset then return end
    end

    -- master toggle notifications
    local master_active = ui.master_toggle:is_active()
    if master_active ~= was_master_toggle_active then
        notification.text = master_active and "UFOSTRAFER Enabled" or "UFOSTRAFER Disabled"
        notification.color = master_active and { 0, 255, 100 } or { 255, 50, 50 }
        notification.end_time = winapi.get_tickcount64() + 2000
        notification.active = true
        was_master_toggle_active = master_active
    end

    -- guarddd
    if not master_active or not ui.enabled:get() then
        state.current_strength = 0
        state.direction = nil
    else
        --dumping localplayer
        local lp = cs2.get_local_player()
        if not lp or lp.pawn == 0 then return end
        
        local pawn = lp.pawn
        local vel_x = proc.read_float(pawn + velocity_offset + 0)
        local vel_y = proc.read_float(pawn + velocity_offset + 4)
        local speed = math.sqrt(vel_x^2 + vel_y^2)
        
        local is_a_down = input.is_key_down(KEY_A)
        local is_d_down = input.is_key_down(KEY_D)
        
        local direction_now
        if is_a_down and not is_d_down then direction_now = 'LEFT'
        elseif is_d_down and not is_a_down then direction_now = 'RIGHT'
        elseif is_a_down and is_d_down then
            if is_a_down and not state.last_a_down then direction_now = 'LEFT'
            elseif is_d_down and not state.last_d_down then direction_now = 'RIGHT'
            else direction_now = state.direction end
        end

        state.last_a_down = is_a_down
        state.last_d_down = is_d_down

        if direction_now ~= state.direction then
            state.key_hold_start_time = winapi.get_tickcount64()
            state.direction = direction_now
        end
        
        -- main shi
        if state.direction and speed > ui.min_speed:get() then
            local base_strength = ui.strength:get()
            local target_strength = base_strength
            
            if ui.smart_strafe:get() then
                local modifier = DEFAULT_MODIFIER
                for _, level in ipairs(SMART_STRAFE_LEVELS) do
                    if speed <= level.Speed then modifier = level.Mod; break end
                end
                target_strength = round(base_strength * modifier)
            end
            
            if ui.progressive_strength:get() then
                local time_held = winapi.get_tickcount64() - state.key_hold_start_time
                local progress = math.min(1.0, time_held / ui.progressive_max_time:get())
                local start_factor = ui.progressive_start_factor:get() / 100.0
                target_strength = round(target_strength * (start_factor + (1.0 - start_factor) * progress))
            end
            
            state.target_strength = math.max(1, math.min(20, target_strength))
            
            local final_angle = ui.angle:get()
            if ui.angle_jitter:get() then
                final_angle = final_angle + ((math.random() * 2 - 1) * ui.jitter_strength:get())
            end
            
            local angle_rad = math.rad(math.max(-89, math.min(89, final_angle)))
            local cos_val, sin_val = math.cos(angle_rad), math.sin(angle_rad)
            
            state.norm_dx = (state.direction == 'LEFT') and -cos_val or cos_val
            state.norm_dy = (state.direction == 'LEFT') and sin_val or -sin_val

            local strength_to_apply = state.target_strength
            if ui.smooth_strafe:get() then
                local increment = (state.target_strength - state.current_strength) / ui.smooth_factor:get()
                state.current_strength = state.current_strength + increment
                strength_to_apply = state.current_strength
            end
            
            local final_dx = round(state.norm_dx * strength_to_apply)
            local final_dy = round(state.norm_dy * strength_to_apply)
            
            if final_dx ~= 0 or final_dy ~= 0 then
                input.simulate_mouse(final_dx, final_dy, 1)
            end
        else
            state.current_strength = 0
            state.direction = nil
        end
    end

    -- draw notification if active
    if notification.active then
        if winapi.get_tickcount64() > notification.end_time then
            notification.active = false
        else
            local sw, sh = render.get_viewport_size()
            local r, g, b = table.unpack(notification.color)
            render.draw_text(font, notification.text, sw / 2 - 50, sh / 2 + 100, r, g, b, 255, 1, 0, 0, 0, 200)
        end
    end
end)



--[[

first time a clean code wawawaw!
hi LynX
made by Kava without love </3 :(

]]--
