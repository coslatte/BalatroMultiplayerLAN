-- MP.LAN: minimal LAN mode (host advertises, guests discover + connect via direct IP)
-- Mirrors balatromp-local-phone's NetworkUtils + config injection, but for LÖVE/luasocket.

MP.LAN = MP.LAN or {}
MP.LAN.BROADCAST_PORT = (SMODS
		and SMODS.Mods
		and SMODS.Mods["Multiplayer"]
		and SMODS.Mods["Multiplayer"].config
		and tonumber(SMODS.Mods["Multiplayer"].config.lan_broadcast_port))
	or 8789
-- Use whatever port the mod is configured to use (8766 in user's case) instead of hard-coding
local function lan_cfg_port()
	if SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].config and SMODS.Mods["Multiplayer"].config.server_port then
		return tonumber(SMODS.Mods["Multiplayer"].config.server_port) or 8788
	end
	return 8788
end
MP.LAN.DEFAULT_GAME_PORT = lan_cfg_port()
MP.LAN.ADVERTISE_INTERVAL = 1.0 -- seconds
MP.LAN.DISCOVERY_TIMEOUT = 4.0
function MP.LAN.get_default_port() return lan_cfg_port() end

-- UI mode toggle: "online" | "lan" — controls Play menu grouping
function MP.LAN.get_ui_mode()
	local cfg = SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].config
	if cfg and (cfg.lan_ui_mode == "lan" or cfg.lan_ui_mode == "online") then
		return cfg.lan_ui_mode
	end
	return "lan"
end
function MP.LAN.set_ui_mode(mode)
	if mode ~= "lan" and mode ~= "online" then return end
	if SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].config then
		SMODS.Mods["Multiplayer"].config.lan_ui_mode = mode
		pcall(function() SMODS.save_mod_config(SMODS.Mods["Multiplayer"]) end)
	end
end

MP.LAN._mode = nil -- "host" | "join" | nil
MP.LAN._host_ip = nil
MP.LAN._advertiser = nil -- udp socket for broadcast
MP.LAN._listener = nil -- udp socket for discovery
MP.LAN._last_advertise = 0
MP.LAN._discovered = {} -- { [ip:port] = { ip, port, code, host, version, last_seen } }
MP.LAN._enabled = false

local function try_require_socket()
	local ok, s = pcall(require, "socket")
	if ok then return s end
	return nil
end

-- Best-effort local IP resolution (mirrors NetworkUtils.getLocalIpAddress fallbacks)
-- On hotspot without internet, 8.8.8.8 route may not exist, so we try multiple peers.
local _hotspot_guesses = { "192.168.43.1", "192.168.137.1", "172.20.10.1", "192.168.1.1", "192.168.0.1" }

function MP.LAN.get_local_ip_candidates()
	local candidates = {}
	local socket = try_require_socket()
	if socket then
		local peers = { "8.8.8.8", "1.1.1.1", "192.168.43.1", "192.168.1.1", "192.168.0.1", "172.20.10.1" }
		for _, peer in ipairs(peers) do
			local ok, ip = pcall(function()
				local udp = socket.udp()
				udp:setpeername(peer, 80)
				local local_ip = udp:getsockname()
				udp:close()
				return local_ip
			end)
			if ok and ip and ip ~= "127.0.0.1" and ip ~= "0.0.0.0" and ip ~= nil then
				local seen = false
				for _, c in ipairs(candidates) do if c == ip then seen = true break end end
				if not seen then table.insert(candidates, ip) end
			end
		end
		-- also try hostname
		pcall(function()
			local hn = socket.dns and socket.dns.gethostname()
			if hn then
				local hip = socket.dns.toip(hn)
				if hip and hip ~= "127.0.0.1" and hip ~= "0.0.0.0" then
					local seen = false
					for _, c in ipairs(candidates) do if c == hip then seen = true break end end
					if not seen then table.insert(candidates, hip) end
				end
			end
		end)
	end
	return candidates
end

function MP.LAN.get_local_ip()
	local candidates = MP.LAN.get_local_ip_candidates()
	if #candidates > 0 then return candidates[1] end
	return nil
end

-- Hotspot defaults when detection fails (Android AP usually 192.168.43.1)
function MP.LAN.get_hotspot_hint()
	return "192.168.43.1"
end

function MP.LAN.get_broadcast_ip()
	return "255.255.255.255"
end

-- Lista de broadcasts para que funcione sin importar quién creó el hotspot
-- (cliente 192.168.43.x -> host 192.168.43.1 y viceversa)
function MP.LAN.get_broadcast_targets()
	return {
		"255.255.255.255",
		"192.168.43.255",   -- Android hotspot default
		"192.168.137.255",  -- Windows hotspot
		"192.168.1.255",
		"192.168.0.255",
		"192.168.43.1",     -- unicast directo al gateway hotspot
		"192.168.137.1",
	}
end

local function lan_broadcast_send(udp, msg)
	for _, bcast in ipairs(MP.LAN.get_broadcast_targets()) do
		pcall(function() udp:sendto(msg, bcast, MP.LAN.BROADCAST_PORT) end)
	end
end

function MP.LAN.is_active()
	return MP.LAN._mode ~= nil
end

function MP.LAN.get_mode()
	return MP.LAN._mode
end

function MP.LAN.get_host_ip()
	return MP.LAN._host_ip
end

function MP.LAN.get_discovered()
	-- prune stale
	local now = love.timer and love.timer.getTime() or os.time()
	local out = {}
	for k, v in pairs(MP.LAN._discovered) do
		if now - (v.last_seen or 0) < MP.LAN.DISCOVERY_TIMEOUT then
			out[#out + 1] = v
		else
			MP.LAN._discovered[k] = nil
		end
	end
	table.sort(out, function(a, b) return (a.last_seen or 0) > (b.last_seen or 0) end)
	return out
end

function MP.LAN.start_host_advertise()
	local socket = try_require_socket()
	if not socket then return false, "luasocket not available" end
	MP.LAN.stop()
	MP.LAN._mode = "host"
	MP.LAN._enabled = true
	-- advertiser: send-only broadcast socket
	local udp_send = socket.udp()
	pcall(function() udp_send:setoption("broadcast", true) end)
	udp_send:settimeout(0)
	MP.LAN._advertiser = udp_send
	-- listener: also listen on BROADCAST_PORT for probe requests from guests
	local udp_recv = socket.udp()
	udp_recv:settimeout(0)
	pcall(function() udp_recv:setoption("reuseaddr", true) end)
	local ok = udp_recv:setsockname("*", MP.LAN.BROADCAST_PORT)
	if not ok then pcall(function() udp_recv:setsockname("0.0.0.0", MP.LAN.BROADCAST_PORT) end) end
	MP.LAN._host_listener = udp_recv
	MP.LAN._host_ip = MP.LAN.get_local_ip()
	MP.LAN._last_advertise = 0
	MP.LAN._last_probe = 0
	return true
end

function MP.LAN.start_discovery()
	local socket = try_require_socket()
	if not socket then return false, "luasocket not available" end
	MP.LAN.stop()
	MP.LAN._mode = "join"
	MP.LAN._enabled = true
	MP.LAN._discovered = {}
	MP.LAN._last_probe = 0
	local udp = socket.udp()
	udp:settimeout(0)
	pcall(function() udp:setoption("broadcast", true) end)
	pcall(function() udp:setoption("reuseaddr", true) end)
	local ok = udp:setsockname("*", MP.LAN.BROADCAST_PORT)
	if not ok then pcall(function() udp:setsockname("0.0.0.0", MP.LAN.BROADCAST_PORT) end) end
	MP.LAN._listener = udp
	-- probe inmediato a todos los targets
	pcall(function() lan_broadcast_send(udp, '{"type":"mp_lan_probe"}') end)
	return true
end

function MP.LAN.stop()
	if MP.LAN._advertiser then pcall(function() MP.LAN._advertiser:close() end) end
	if MP.LAN._host_listener then pcall(function() MP.LAN._host_listener:close() end) end
	if MP.LAN._listener then pcall(function() MP.LAN._listener:close() end) end
	MP.LAN._advertiser = nil
	MP.LAN._host_listener = nil
	MP.LAN._listener = nil
	MP.LAN._mode = nil
	MP.LAN._enabled = false
	MP.LAN._on_discover = nil
end

local json = nil
local function get_json()
	if json then return json end
	local ok, j = pcall(require, "json")
	if ok then json = j end
	return json
end

function MP.LAN.build_advertise_payload()
	local j = get_json()
	local payload = {
		type = "mp_lan_advertise",
		code = MP.LOBBY and MP.LOBBY.code or nil,
		host = MP.LOBBY and MP.LOBBY.username or "Host",
		port = MP.LAN.DEFAULT_GAME_PORT,
		version = SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].version or "0.0.0",
		ip = MP.LAN._host_ip or MP.LAN.get_local_ip(),
	}
	if j then return j.encode(payload) end
	-- minimal manual json fallback
	return string.format('{"type":"mp_lan_advertise","code":"%s","host":"%s","port":%d,"version":"%s","ip":"%s"}',
		payload.code or "", payload.host or "Host", payload.port, payload.version or "", payload.ip or "")
end

function MP.LAN.tick(dt)
	if not MP.LAN._enabled then return end
	local now = love.timer and love.timer.getTime() or os.time()
	if MP.LAN._mode == "host" then
		-- broadcast periódico a todos los segmentos (no importa quién hizo hotspot)
		if MP.LAN._advertiser and now - (MP.LAN._last_advertise or 0) >= MP.LAN.ADVERTISE_INTERVAL then
			MP.LAN._last_advertise = now
			local msg = MP.LAN.build_advertise_payload()
			lan_broadcast_send(MP.LAN._advertiser, msg)
		end
		if MP.LAN._host_listener then
			while true do
				local data, ip, port = MP.LAN._host_listener:receivefrom()
				if not data then break end
				if data:find("mp_lan_probe") then
					local msg = MP.LAN.build_advertise_payload()
					pcall(function() MP.LAN._advertiser:sendto(msg, ip, port) end)
					lan_broadcast_send(MP.LAN._advertiser, msg)
				end
			end
		end
	elseif MP.LAN._mode == "join" and MP.LAN._listener then
		if now - (MP.LAN._last_probe or 0) >= 1.5 then
			MP.LAN._last_probe = now
			pcall(function() lan_broadcast_send(MP.LAN._listener, '{"type":"mp_lan_probe"}') end)
		end
		-- drain all pending datagrams
		local changed = false
		while true do
			local data, ip, port = MP.LAN._listener:receivefrom()
			if not data then break end
			-- ignore our own probes
			if data:find("mp_lan_probe") then goto continue end
			local ok, parsed
			local j = get_json()
			if j then ok, parsed = pcall(j.decode, data) else ok = false end
			if not ok then
				if data:find("mp_lan_advertise") then
					parsed = { type = "mp_lan_advertise" }
					parsed.ip = data:match('"ip"%s*:%s*"([^"]+)"') or ip
					parsed.code = data:match('"code"%s*:%s*"([^"]+)"')
					parsed.host = data:match('"host"%s*:%s*"([^"]+)"')
					parsed.port = tonumber(data:match('"port"%s*:%s*(%d+)')) or MP.LAN.DEFAULT_GAME_PORT
					parsed.version = data:match('"version"%s*:%s*"([^"]+)"')
					ok = true
				end
			end
			if ok and parsed and parsed.type == "mp_lan_advertise" then
				local key = (parsed.ip or ip) .. ":" .. tostring(parsed.port or MP.LAN.DEFAULT_GAME_PORT)
				local prev = MP.LAN._discovered[key]
				MP.LAN._discovered[key] = {
					ip = parsed.ip or ip,
					port = parsed.port or MP.LAN.DEFAULT_GAME_PORT,
					code = parsed.code,
					host = parsed.host or "Host",
					version = parsed.version,
					last_seen = now,
					key = key,
				}
				if not prev or prev.code ~= parsed.code then changed = true end
			end
			::continue::
		end
		if changed and MP.LAN._on_discover then
			pcall(MP.LAN._on_discover, MP.LAN.get_discovered())
		end
	end
end

-- UI hook for live refresh of Join screen
function MP.LAN.set_discover_callback(cb) MP.LAN._on_discover = cb end

-- Connect to a LAN host: reconfigure networking thread to use that IP.
-- This mirrors ConfigManager.injectServerUrl("http://IP:8788") on Android.
function MP.LAN.connect_to_host(ip, port)
	-- guard: if we were offline, leave offline first to avoid stale code -> crash on re-enter
	if MP.LAN._offline and MP.LOBBY.code then
		pcall(function() MP.LAN.leave_offline_lobby() end)
	end
	MP.LAN._creating = true
	MP.LAN._suppress_error = true
	port = port or MP.LAN.get_default_port()
	if not ip or ip == "" then return false, "missing ip" end
	-- normalize: strip http:// and :port if present
	ip = tostring(ip):gsub("^https?://", ""):gsub(":%d+$", ""):gsub("/.*$", "")
	ip = ip:match("^%s*(.-)%s*$")

	local server_url = ip
	local server_port = port

	-- Persist for next boot (like Multiplayer.jkr server_url)
	if SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] then
		SMODS.Mods["Multiplayer"].config.server_url = server_url
		SMODS.Mods["Multiplayer"].config.server_port = server_port
		pcall(function() SMODS.save_mod_config(SMODS.Mods["Multiplayer"]) end)
	end
	MP.ENV = MP.ENV or {}
	MP.ENV.server_url = server_url
	MP.ENV.server_port = tostring(server_port)

	-- Restart networking thread with new endpoint
	local ok, err = MP.LAN.restart_networking(server_url, server_port)
	if not ok then
		return false, err or "failed to restart networking"
	end
	return true
end

function MP.LAN.restore_online_server()
	local default_url = "balatro.virtualized.dev"
	local default_port = 8788
	if SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] then
		-- keep whatever is in config unless it looks like a LAN IP
		local cur = SMODS.Mods["Multiplayer"].config.server_url
		if cur and cur:match("^%d+%.%d+%.%d+%.%d+$") then
			SMODS.Mods["Multiplayer"].config.server_url = default_url
			SMODS.Mods["Multiplayer"].config.server_port = default_port
			pcall(function() SMODS.save_mod_config(SMODS.Mods["Multiplayer"]) end)
		end
	end
	MP.LAN.stop()
end

function MP.LAN.restart_networking(server_url, server_port)
	-- Replace the client thread. LÖVE threads can't be killed, so ask the old
	-- one to go inert via a quit sentinel (see networking/socket.lua): two live
	-- threads would both pop the uiToNetwork channel and split outgoing
	-- messages between a dead socket and the new one. Generation matching in
	-- the sentinel makes this safe even when the old thread is blocked inside
	-- a connect/sleep and cannot ack in time — it will honor the sentinel
	-- before touching any message queued after it.
	MP.LAN._thread_gen = (MP.LAN._thread_gen or 1) + 1
	if MP.NETWORKING_THREAD then
		local quit_ack = love.thread.getChannel("mpThreadQuitAck")
		while quit_ack:pop() ~= nil do end -- clear stale acks
		love.thread
			.getChannel("uiToNetwork")
			:push("__MP_THREAD_QUIT__" .. tostring(MP.LAN._thread_gen))
		-- Best-effort confirmation: the old thread normally pops within ~50ms
		quit_ack:demand(0.5)
	end
	-- Need SOCKET chunk from networking/socket.lua
	local SOCKET = MP.load_mp_file and MP.load_mp_file("networking/socket.lua")
	if not SOCKET then
		-- fallback: use already loaded chunk path
		SOCKET = SMODS.load_file and SMODS.load_file("networking/socket.lua", "Multiplayer")
		if SOCKET then SOCKET = SOCKET() end
	end
	if not SOCKET then return false, "socket chunk not found" end
	local ok, thread_or_err = pcall(function()
		MP.NETWORKING_THREAD = love.thread.newThread(SOCKET)
		MP.NETWORKING_THREAD:start(server_url, server_port, MP.LAN._thread_gen)
		if MP.ACTIONS and MP.ACTIONS.connect then MP.ACTIONS.connect() end
	end)
	if not ok then return false, tostring(thread_or_err) end
	return true
end

-- Offline LAN fallback: when no TCP server is reachable (hotspot without Node/Ktor),
-- still create a local lobby so "Next" doesn't hang. Discovery via UDP still advertises the code.
function MP.LAN._gen_code()
	local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ"
	local c = ""
	for i = 1, 5 do c = c .. chars:sub(math.random(1, #chars), math.random(1, #chars)) end
	-- ensure not same as temp
	c = c:sub(1,5)
	return c:upper()
end

function MP.LAN.create_offline_lobby(gamemode)
	math.randomseed(os.time() + math.random(9999))
	local code = MP.LAN._gen_code()
	MP.LOBBY.code = code
	MP.LOBBY.type = "LAN"
	MP.LOBBY.is_host = true
	MP.LOBBY.ready_to_start = false
	MP.LOBBY.host = { username = MP.LOBBY.username or "Host", blind_col = MP.LOBBY.blind_col or 1, hash_str = MP.MOD_STRING or "", hash = MP.MOD_HASH or "0000", cached = true, config = {} }
	MP.LOBBY.guest = {}
	MP.LOBBY.players = {}
	MP.LOBBY.connected = true
	-- keep advertising this code for guests via UDP
	MP.LAN._host_ip = MP.LAN._host_ip or MP.LAN.get_local_ip() or MP.LAN.get_hotspot_hint()
	MP.LAN._offline = true
	MP.LAN._suppress_error = false
	MP.LAN._creating = nil
	sendDebugMessage("LAN offline lobby created: " .. code .. " for discovery", "MULTIPLAYER")
	if G.FUNCS and G.FUNCS.display_lobby_main_menu_UI then
		G.FUNCS.exit_overlay_menu()
		G.FUNCS.display_lobby_main_menu_UI()
	end
	MP.UI.update_connection_status()
	-- start advertising if not already
	if not MP.LAN._advertiser then MP.LAN.start_host_advertise() end
	MP.ACTIONS.lobby_info()
	return true
end

function MP.LAN.join_offline_lobby(code, host_ip, host_port)
	-- guard: avoid re-entry while already in a lobby (prevents crash when leaving then re-joining quickly)
	if MP.LOBBY.code and MP.LAN._offline then
		-- clean previous offline lobby first
		pcall(function() MP.LAN.leave_offline_lobby() end)
	end
	code = (code or MP.LAN._manual_ip or ""):upper():gsub("[^A-Z]", ""):sub(1,5)
	if code == "" then
		local disc = MP.LAN.get_discovered()
		for _, d in ipairs(disc) do
			if d.ip == host_ip and d.code and d.code ~= "" then code = d.code; break end
		end
	end
	if code == "" then code = "LAN01" end
	MP.LOBBY.code = code
	MP.LOBBY.type = "LAN"
	MP.LOBBY.is_host = false
	MP.LOBBY.ready_to_start = false
	MP.LOBBY.connected = true
	MP.LAN._offline = true
	MP.LAN._suppress_error = false
	MP.LAN._creating = nil
	sendDebugMessage("LAN offline join: " .. code .. " via " .. tostring(host_ip), "MULTIPLAYER")
	if G.FUNCS and G.FUNCS.display_lobby_main_menu_UI then
		pcall(function() G.FUNCS.exit_overlay_menu() end)
		pcall(function() G.FUNCS.display_lobby_main_menu_UI() end)
	end
	pcall(function() MP.UI.update_connection_status() end)
	return true
end

function MP.LAN.leave_offline_lobby()
	MP.LAN._offline = nil
	MP.LAN._creating = nil
	MP.LAN._suppress_error = nil
	MP.LAN._host_ip = nil
	MP.LAN.stop()
	-- clear lobby state without touching server
	if MP.LOBBY then
		MP.LOBBY.code = nil
		MP.LOBBY.type = ""
		MP.LOBBY.is_host = false
		MP.LOBBY.ready_to_start = false
		MP.LOBBY.host = {}
		MP.LOBBY.guest = {}
		MP.LOBBY.players = {}
		-- keep connected = true so online reconnect still works, but clear stale code
	end
end

-- Wrap MP.ACTIONS.create_lobby / join_lobby / leave to fallback offline when not connected
local function wrap_lan_actions()
	if not MP.ACTIONS or MP.LAN._wrapped then return end
	MP.LAN._wrapped = true
	local orig_create = MP.ACTIONS.create_lobby
	local orig_join = MP.ACTIONS.join_lobby
	local orig_leave = MP.ACTIONS.leave_lobby
	function MP.ACTIONS.create_lobby(gamemode)
		if MP.LOBBY.connected and not MP.LAN._offline then
			return orig_create(gamemode)
		end
		if MP.LAN._creating or MP.LAN._offline or MP.LAN.is_active() then
			return MP.LAN.create_offline_lobby(gamemode)
		end
		return orig_create(gamemode)
	end
	function MP.ACTIONS.join_lobby(code)
		if MP.LOBBY.connected and not MP.LAN._offline then
			return orig_join(code)
		end
		if MP.LAN.is_active() or MP.LAN._offline then
			local ip = MP.LAN._manual_ip or ""
			return MP.LAN.join_offline_lobby(code, ip)
		end
		return orig_join(code)
	end
	function MP.ACTIONS.leave_lobby()
		local was_lan = MP.LAN.is_active() or MP.LAN._offline or (MP.SERVER and MP.SERVER._lan_started)
		if MP.LAN._offline then
			MP.LAN.leave_offline_lobby()
			pcall(function() MP.UI.update_connection_status() end)
			pcall(function()
				if G.MAIN_MENU_UI then G.MAIN_MENU_UI:remove() end
				if G.STAGE == G.STAGES.MAIN_MENU then set_main_menu_UI() end
			end)
			return
		end
		local ret = orig_leave()
		-- Apagar sala LAN correctamente: detener advertise/discovery para que no quede rota
		-- con usuarios fantasma y evitar que el mismo jugador se una 2 veces a la misma sala
		if was_lan then
			pcall(function() MP.LAN.stop() end)
			-- Si el server embebido quedó sin lobbies, se auto-detiene via on_lobby_destroyed;
			-- si aún está corriendo pero sin lobby local, limpiamos estado de lobby para re-entrada limpia
			if MP.LOBBY and MP.LOBBY.code == nil then
				MP.LAN._host_ip = nil
				MP.LAN._creating = nil
				MP.LAN._suppress_error = nil
			end
		end
		return ret
	end
	-- also wrap G.FUNCS.lobby_leave for the UI button path
	if G.FUNCS and G.FUNCS.lobby_leave and not MP.LAN._lobby_leave_wrapped then
		MP.LAN._lobby_leave_wrapped = true
		local orig_ui_leave = G.FUNCS.lobby_leave
		function G.FUNCS.lobby_leave(e)
			local was_lan = MP.LAN.is_active() or MP.LAN._offline or (MP.SERVER and MP.SERVER._lan_started)
			if MP.LAN._offline then
				MP.LAN.leave_offline_lobby()
				if G.STAGE ~= G.STAGES.MAIN_MENU then
					G.STATE = G.STATES.MENU
				else
					pcall(function()
						if G.MAIN_MENU_UI then G.MAIN_MENU_UI:remove() end
						if G.STAGE == G.STAGES.MAIN_MENU then set_main_menu_UI() end
					end)
				end
				MP.UI.update_connection_status()
				return
			end
			local ret = orig_ui_leave(e)
			if was_lan then
				pcall(function() MP.LAN.stop() end)
				if MP.LOBBY and MP.LOBBY.code == nil then
					MP.LAN._host_ip = nil
					MP.LAN._creating = nil
					MP.LAN._suppress_error = nil
				end
			end
			return ret
		end
	end
end

-- defer wrap until actions exist
if MP.ACTIONS and MP.ACTIONS.create_lobby then
	wrap_lan_actions()
else
	G.E_MANAGER:add_event(Event({ trigger = "immediate", blockable = false, blocking = false, func = function()
		wrap_lan_actions(); return true
	end }))
end

-- Tick is driven from a lightweight Game.update wrapper installed lazily.
-- We defer the install until after boot so G.E_MANAGER / Game.update exist.
function MP.LAN._install_tick()
	if MP.LAN._tick_installed then return end
	MP.LAN._tick_installed = true
	local orig = Game.update
	function Game:update(dt)
		orig(self, dt)
		if G.STAGE == G.STAGES.MAIN_MENU then
			pcall(function() MP.LAN.tick(dt) end)
		end
	end
end

-- Try immediately; if Game not ready yet, defer via first update.
if Game and Game.update and G and G.E_MANAGER then
	MP.LAN._install_tick()
else
	-- Defer: on next frame, G.E_MANAGER will exist
	local _attempt = 0
	local _orig_update = Game and Game.update
	if _orig_update then
		function Game:update(dt)
			_orig_update(self, dt)
			if not MP.LAN._tick_installed then
				_attempt = _attempt + 1
				if G and G.E_MANAGER and _attempt > 2 then
					MP.LAN._install_tick()
				end
			end
			if MP.LAN._tick_installed and G.STAGE == G.STAGES.MAIN_MENU then
				pcall(function() MP.LAN.tick(dt) end)
			end
		end
	end
end
