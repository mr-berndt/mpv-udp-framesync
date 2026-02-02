-- mpv-sync.lua - Synchronize two mpv instances via UDP
-- Place this script in ~/.config/mpv/scripts/ or specify with --script=path/to/mpv-sync.lua
--
-- Usage:
--   Master: mpv --script-opts=sync-role=master,sync-target=192.168.10.255:12345 video.mp4
--   Slave:  mpv --script-opts=sync-role=slave,sync-target=192.168.10.255:12345 video.mp4

-- Configuration
local opts = {
    role = "master",           -- "master" or "slave"
    target = "192.168.10.255:12345", -- target address:port (e.g., 192.168.10.255:12345 or 127.0.0.1:12345)
    backend = "auto",          -- "auto", "socket", or "socat" - auto tries socket first, falls back to socat
    sync_interval = 0.5,       -- seconds between position sync updates
    seek_threshold = 5.0,      -- seconds of difference before hard seeking
    speed_adjust_threshold = 0.02, -- seconds - below this, reset to normal speed (20ms)
    max_speed_adjust = 0.5,    -- maximum speed adjustment (e.g., 0.5 = 50% faster/slower)
    initial_offset = 0.015,    -- initial offset in seconds (e.g., 0.015 = 15ms)
    show_osd = true,           -- show sync info on screen (toggle with 'i' key on slave)
}

-- Parse script options
(require 'mp.options').read_options(opts, "sync")

-- Parse target address:port
local target_ip, target_port = opts.target:match("([^:]+):(%d+)")
target_port = tonumber(target_port)

if not target_ip or not target_port then
    mp.msg.error("Invalid target format. Use ADDRESS:PORT (e.g., 192.168.1.255:12345)")
    return
end

-- Backend selection: Try lua-socket or use socat
local use_socket = false
local use_socat = false
local socket = nil
local udp = nil
local socat_path = nil

if opts.backend == "socket" or opts.backend == "auto" then
    -- Try to load lua-socket
    local socket_ok, socket_module = pcall(require, "socket")
    if socket_ok then
        local udp_ok, udp_instance = pcall(socket_module.udp)
        if udp_ok and udp_instance then
            use_socket = true
            socket = socket_module
            udp = udp_instance
            mp.msg.info("Using lua-socket backend")
        else
            mp.msg.warn("lua-socket loaded but UDP creation failed: " .. tostring(udp_instance))
        end
    else
        mp.msg.warn("lua-socket not available: " .. tostring(socket_module))
    end
end

if not use_socket and (opts.backend == "socat" or opts.backend == "auto") then
    -- Try to find socat
    for _, cmd in ipairs({"socat", "/usr/bin/socat", "/bin/socat"}) do
        local handle = io.popen("which " .. cmd .. " 2>/dev/null")
        local result = handle:read("*a")
        handle:close()
        if result and result ~= "" then
            socat_path = cmd
            use_socat = true
            mp.msg.info("Using socat backend: " .. socat_path)
            break
        end
    end

    if not use_socat then
        mp.msg.error("socat not found. Install with: sudo apt install socat")
    end
end

if not use_socket and not use_socat then
    mp.msg.error("No backend available! Install lua-socket or socat.")
    mp.msg.error("Debian/Ubuntu: sudo apt install lua-socket socat")
    mp.msg.error("Or set backend=socket/socat explicitly")
    return
end

-- Initialize backend-specific components
local success, err

if use_socket then
    -- Setup lua-socket UDP
    udp:setoption("reuseaddr", true)
    pcall(function() udp:setoption("reuseport", true) end)

    if opts.role == "slave" then
        success, err = udp:setsockname("0.0.0.0", target_port)
        if not success then
            mp.msg.error(string.format("Failed to bind to 0.0.0.0:%d: %s", target_port, tostring(err)))
            return
        end
        mp.msg.info(string.format("Slave listening on 0.0.0.0:%d", target_port))
    else
        success, err = udp:setsockname("0.0.0.0", 0)
        if not success then
            mp.msg.error(string.format("Failed to bind: %s", tostring(err)))
            return
        end
        mp.msg.info("Master bound to random port (send-only)")
    end
    udp:settimeout(0) -- non-blocking

    -- Enable broadcast if not using localhost
    if target_ip ~= "127.0.0.1" and target_ip ~= "localhost" then
        success, err = udp:setoption("broadcast", true)
        if not success then
            mp.msg.warn("Failed to enable broadcast: " .. tostring(err))
        else
            mp.msg.info("Broadcast enabled")
        end
    end
end

if opts.role == "master" then
    mp.msg.info(string.format("MASTER: broadcasting to %s:%d", target_ip, target_port))
else
    mp.msg.info(string.format("SLAVE: listening on port %d", target_port))
end

local syncing = false -- flag to prevent sync loops
local master_position = nil
local master_paused = nil
local base_speed = 1.0 -- the original playback speed set by master
local slave_offset = opts.initial_offset -- manual offset in seconds (adjustable with Ö/Ä keys)

-- Backend-specific send function
local function send_command(cmd, data)
    local message = cmd
    if data then
        message = message .. "|" .. data
    end

    if use_socket then
        local success, err = udp:sendto(message, target_ip, target_port)
        if not success then
            mp.msg.error(string.format("Failed to send: %s (error: %s)", message, tostring(err)))
        else
            mp.msg.info(string.format("Sent: %s to %s:%d", message, target_ip, target_port))
        end
    elseif use_socat then
        local socat_cmd = string.format("echo '%s' | %s - UDP4-DATAGRAM:%s:%d,broadcast 2>/dev/null &",
            message, socat_path, target_ip, target_port)
        os.execute(socat_cmd)
        mp.msg.info(string.format("Sent: %s to %s:%d", message, target_ip, target_port))
    end
end

-- Slave: Adjust playback speed based on position difference
local function adjust_speed(time_diff, master_pos, slave_pos)
    -- time_diff: positive means slave is behind, negative means ahead

    local offset_str = ""
    if math.abs(slave_offset) > 0.001 then
        offset_str = string.format(" | Offset: %+dms", math.floor(slave_offset * 1000 + 0.5))
    end

    if math.abs(time_diff) < opts.speed_adjust_threshold then
        -- Close enough, return to base speed
        mp.set_property("speed", base_speed)
        local msg = string.format("Master: %.2fs | Slave: %.2fs | Diff: %.3fs | Speed: %.3f (IN SYNC)%s",
            master_pos, slave_pos, time_diff, base_speed, offset_str)
        mp.msg.info(msg)
        if opts.show_osd then
            mp.osd_message(msg, 2)
        end
        return
    end

    -- Calculate speed adjustment with progressive scaling
    -- Near sync point: very fine adjustment
    -- Far from sync point: larger adjustment
    local abs_diff = math.abs(time_diff)
    local speed_factor

    if abs_diff < 0.05 then
        -- Very close (< 50ms): ultra-fine adjustment (max 5%)
        speed_factor = abs_diff * 1.0
    elseif abs_diff < 0.2 then
        -- Close (50-200ms): fine adjustment (max 10%)
        speed_factor = 0.05 + (abs_diff - 0.05) * 0.5
    elseif abs_diff < 1.0 then
        -- Medium (200ms-1s): moderate adjustment
        speed_factor = 0.125 + (abs_diff - 0.2) * 0.25
    else
        -- Far (>1s): larger adjustment
        speed_factor = math.min(abs_diff / 3.0, opts.max_speed_adjust)
    end

    -- Ensure we don't exceed max adjustment
    speed_factor = math.min(speed_factor, opts.max_speed_adjust)

    local new_speed
    local direction
    if time_diff > 0 then
        -- Slave is behind, speed up
        new_speed = base_speed + speed_factor
        direction = "BEHIND (speeding up)"
    else
        -- Slave is ahead, slow down
        new_speed = base_speed - speed_factor
        direction = "AHEAD (slowing down)"
    end

    -- Clamp speed to reasonable values
    new_speed = math.max(0.5, math.min(2.0, new_speed))

    local correction = ((new_speed / base_speed) - 1) * 100
    mp.set_property("speed", new_speed)

    local msg = string.format("Master: %.2fs | Slave: %.2fs | Diff: %.3fs | Speed: %.3f (%+.1f%%) %s%s",
        master_pos, slave_pos, time_diff, new_speed, correction, direction, offset_str)
    mp.msg.info(msg)
    if opts.show_osd then
        mp.osd_message(msg, 2)
    end
end

-- Handle received commands
local function handle_command(message)
    mp.msg.debug("Received: " .. message)

    -- Master ignores incoming messages (only slaves should react)
    if opts.role == "master" then
        return
    end

    local cmd, data = message:match("([^|]+)|?(.*)")
    if not cmd then return end

    syncing = true -- prevent sync loops

    if cmd == "play" then
        master_paused = false
        mp.set_property_bool("pause", false)
    elseif cmd == "pause" then
        master_paused = true
        mp.set_property_bool("pause", true)
    elseif cmd == "seek" then
        local time = tonumber(data)
        if time then
            master_position = time
            mp.commandv("seek", time, "absolute")
        end
    elseif cmd == "position" then
        local time = tonumber(data)
        if time then
            master_position = time

            if opts.role == "slave" then
                local current = mp.get_property_number("time-pos")
                if current then
                    -- Apply the manual offset: target position = master position + offset
                    local target_pos = time + slave_offset
                    local diff = target_pos - current

                    if math.abs(diff) > opts.seek_threshold then
                        -- Large difference, do a hard seek
                        local offset_str = ""
                        if math.abs(slave_offset) > 0.001 then
                            offset_str = string.format(" | Offset: %+dms", math.floor(slave_offset * 1000 + 0.5))
                        end
                        local msg = string.format("HARD SEEK: Master: %.2fs | Slave: %.2fs | Diff: %.2fs (> %.1fs threshold)%s",
                            time, current, diff, opts.seek_threshold, offset_str)
                        mp.msg.info(msg)
                        if opts.show_osd then
                            mp.osd_message(msg, 3)
                        end
                        mp.commandv("seek", target_pos, "absolute")
                    else
                        -- Small difference, use speed adjustment
                        adjust_speed(diff, time, current)
                    end
                end
            end
        end
    elseif cmd == "speed" then
        local speed = tonumber(data)
        if speed then
            base_speed = speed
            mp.set_property("speed", speed)
        end
    end

    syncing = false
end

-- Backend-specific message checking
local msg_file = nil
local last_size = 0

if use_socat and opts.role == "slave" then
    -- Create a temporary file for socat output
    msg_file = os.tmpname()

    -- Start socat in background to receive UDP broadcast
    local socat_listen_cmd = string.format("%s UDP4-RECVFROM:%d,broadcast,fork STDOUT >> %s 2>&1 &",
        socat_path, target_port, msg_file)

    os.execute(socat_listen_cmd)
    mp.msg.info("Started socat listener on port " .. target_port)
end

local function check_messages()
    if use_socket then
        -- lua-socket: poll UDP socket
        while true do
            local message, peer_ip, peer_port = udp:receivefrom()
            if not message then break end
            handle_command(message)
        end
    elseif use_socat and opts.role == "slave" then
        -- socat: read from temporary file
        if not msg_file then return end

        local f = io.open(msg_file, "r")
        if not f then return end

        -- Seek to last read position
        f:seek("set", last_size)

        -- Read new lines
        for line in f:lines() do
            if line and line ~= "" then
                handle_command(line)
            end
        end

        -- Remember current position
        last_size = f:seek("end")
        f:close()
    end
end

-- Master mode: send commands to slave
if opts.role == "master" then

    -- Sync play/pause state
    mp.observe_property("pause", "bool", function(name, value)
        if not syncing then
            if value then
                send_command("pause")
            else
                send_command("play")
            end
        end
    end)

    -- Sync seeking
    mp.register_event("seek", function()
        if not syncing then
            local time = mp.get_property_number("time-pos")
            if time then
                send_command("seek", tostring(time))
            end
        end
    end)

    -- Sync playback speed
    mp.observe_property("speed", "number", function(name, value)
        if not syncing and value then
            send_command("speed", tostring(value))
        end
    end)

    -- Periodic position sync (for drift correction)
    local sync_timer = mp.add_periodic_timer(opts.sync_interval, function()
        if not syncing then
            local time = mp.get_property_number("time-pos")
            if time then
                send_command("position", tostring(time))
            end
        end
    end)

    mp.msg.info("Running in MASTER mode")
end

-- Slave mode: receive commands from master
if opts.role == "slave" then
    mp.msg.info("Running in SLAVE mode - will adjust speed to stay in sync")

    if math.abs(slave_offset) > 0.001 then
        mp.msg.info(string.format("Initial offset: %+dms", math.floor(slave_offset * 1000 + 0.5)))
    end

    -- Key bindings for fine-tuning offset
    mp.add_key_binding("Ö", "sync-offset-increase", function()
        slave_offset = slave_offset + 0.005  -- +5ms
        local msg = string.format("Slave offset: %+dms", math.floor(slave_offset * 1000 + 0.5))
        mp.msg.info(msg)
        if opts.show_osd then
            mp.osd_message(msg, 2)
        end
    end)

    mp.add_key_binding("Ä", "sync-offset-decrease", function()
        slave_offset = slave_offset - 0.005  -- -5ms
        local msg = string.format("Slave offset: %+dms", math.floor(slave_offset * 1000 + 0.5))
        mp.msg.info(msg)
        if opts.show_osd then
            mp.osd_message(msg, 2)
        end
    end)

    mp.msg.info("Key bindings: Ö (Shift+ö) = +5ms offset, Ä (Shift+ä) = -5ms offset")
    mp.msg.info(string.format("Sync OSD display: %s (use sync-show_osd=yes/no to change)", opts.show_osd and "ON" or "OFF"))
end

-- Both modes need to listen for messages (master listens too for potential future features)
mp.add_periodic_timer(0.05, check_messages)

-- Cleanup on shutdown
mp.register_event("shutdown", function()
    if use_socket and udp then
        udp:close()
    end
    -- socat processes will terminate when mpv exits
end)

mp.msg.info(string.format("MPV Sync script loaded successfully (%s backend)", use_socket and "lua-socket" or "socat"))
