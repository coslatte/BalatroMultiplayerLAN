-- Embedded LAN game server: TCP transport (main.ts port).
-- github.com/Balatro-Multiplayer/BalatroMultiplayerAPI-Server parity:
--   - raw TCP on the game port, newline-delimited JSON per message
--   - "connected" + "version" sent immediately on accept
--   - keepAlive after 15s of inactivity, then 5s retries x4 before closing
--
-- Runs in the MAIN thread as a non-blocking tick chained onto Game:update —
-- the same pattern MP.LAN already uses for UDP discovery. Two clients on a LAN
-- produce trivial per-frame work: one accept() poll plus line drains, all with
-- settimeout(0). luasocket keeps partially-received lines in its internal
-- buffer on timeout, so a plain receive("*l") drain loop never loses data
-- (this is exactly how the game's own client thread reads the online server).
--
-- No per-connection byte cap is enforced (upstream caps at 4MB against
-- internet strangers): a LAN relay runs between friends on a private network.

local json_ok, json = pcall(require, "json")
local socket_ok, socket_lib = pcall(require, "socket")

-- All values in seconds (mirrors main.ts)
local KEEP_ALIVE_INITIAL_TIMEOUT = 15
local KEEP_ALIVE_RETRY_TIMEOUT = 5
local KEEP_ALIVE_RETRY_COUNT = 4

MP.SERVER._running = false
MP.SERVER._master = nil
MP.SERVER._clients = nil
MP.SERVER._lan_started = false
MP.SERVER._stop_requested = false

local function server_config()
	if SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].config then
		return SMODS.Mods["Multiplayer"].config
	end
	return {}
end

-- ─── Client socket entries ──────────────────────────────────────────────────

local function make_entry(sock)
	sock:settimeout(0)
	pcall(function() sock:setoption("tcp-nodelay", true) end)

	local entry = {
		socket = sock,
		closed = false,
		last_data = MP.SERVER.now(),
		ka_sent = false,
		ka_at = 0,
		ka_retries = 0,
	}

	local function close_fn()
		if entry.closed then return end
		entry.closed = true
		pcall(function() sock:close() end)
	end

	local function send_fn(action)
		if entry.closed or not json_ok then return end
		local ok, data = pcall(json.encode, action)
		if not ok or not data then return end
		local sent, err = sock:send(data .. "\n")
		if not sent then
			-- Peer went away mid-relay: treat as a dropped connection
			close_fn()
			MP.SERVER.disconnect_from_lobby(entry.client)
		end
	end

	entry.client = MP.SERVER.ClientState.new(send_fn, close_fn)
	return entry
end

local function mark_dead(entry)
	if entry.closed then return end
	entry.closed = true
	pcall(function() entry.socket:close() end)
	MP.SERVER.disconnect_from_lobby(entry.client)
end

-- ─── Message dispatch ───────────────────────────────────────────────────────

local function handle_message(entry, line)
	-- Data received, reset keepAlive
	entry.last_data = MP.SERVER.now()
	entry.ka_sent = false
	entry.ka_retries = 0

	local ok, parsed = pcall(json.decode, line)
	if not ok or type(parsed) ~= "table" then
		entry.client:send_action({ action = "error", message = "Failed to parse message" })
		return
	end

	local action = parsed.action
	parsed.action = nil
	local handler = MP.SERVER.handlers and MP.SERVER.handlers[action]
	if handler then
		local ok_handler, err = pcall(handler, parsed, entry.client)
		if not ok_handler then
			sendWarnMessage(
				"LAN server handler error (" .. tostring(action) .. "): " .. tostring(err),
				"MULTIPLAYER"
			)
			-- Upstream wraps dispatch in a try/catch that answers with the
			-- same parse error message; mirror that
			entry.client:send_action({ action = "error", message = "Failed to parse message" })
		end
	end
	-- Unknown actions are silently ignored, like the upstream switch
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

-- Bind and listen. Returns true, or false + reason (caller falls back to the
-- offline lobby path). Defaults mirror upstream: all interfaces ("0.0.0.0"),
-- game port from mod config. config.lan_bind_ip pins a specific interface.
function MP.SERVER.start(port, bind_ip)
	if not socket_ok then
		return false, "luasocket not available"
	end
	if MP.SERVER._running then
		return true
	end

	local cfg = server_config()
	port = tonumber(port) or tonumber(cfg.server_port) or 8788
	bind_ip = bind_ip or cfg.lan_bind_ip
	if not bind_ip or bind_ip == "" then
		bind_ip = "0.0.0.0"
	end

	local master, err = socket_lib.bind(bind_ip, port)
	if not master then
		return false, "bind failed on " .. tostring(bind_ip) .. ":" .. tostring(port) .. " (" .. tostring(err) .. ")"
	end
	master:settimeout(0)

	MP.SERVER._master = master
	MP.SERVER._clients = {}
	MP.SERVER._running = true
	MP.SERVER._lan_started = true
	MP.SERVER._stop_requested = false
	sendDebugMessage(
		"LAN server listening on " .. tostring(bind_ip) .. ":" .. tostring(port),
		"MULTIPLAYER"
	)
	return true
end

local function do_stop()
	for _, entry in ipairs(MP.SERVER._clients or {}) do
		entry.closed = true
		pcall(function() entry.socket:close() end)
	end
	if MP.SERVER._master then
		pcall(function() MP.SERVER._master:close() end)
	end
	MP.SERVER._master = nil
	MP.SERVER._clients = {}
	MP.SERVER.Lobbies = {}
	MP.SERVER._running = false
	MP.SERVER._lan_started = false
	MP.SERVER._stop_requested = false
	sendDebugMessage("LAN server stopped", "MULTIPLAYER")
end

-- Immediate stop. Safe from UI callbacks (runs outside the tick loop); never
-- call from inside a handler — use request_stop() there.
function MP.SERVER.stop()
	if MP.SERVER._running or MP.SERVER._stop_requested then
		do_stop()
	end
end

-- Deferred stop: honored by tick once the last lobby is gone, so it can be
-- requested from inside a handler (e.g. lobby destruction) without mutating
-- the client list mid-iteration.
function MP.SERVER.request_stop()
	MP.SERVER._stop_requested = true
end

function MP.SERVER.is_running()
	return MP.SERVER._running
end

-- Auto-stop when the last lobby dies: the LAN session is over
MP.SERVER.on_lobby_destroyed = function()
	MP.SERVER._stop_requested = true
end

-- ─── The tick (accept / drain / keepalive / grace expiry) ───────────────────

function MP.SERVER.tick()
	if not MP.SERVER._running then
		return
	end
	local now_t = MP.SERVER.now()

	-- Accept pending connections
	while true do
		local sock = MP.SERVER._master:accept()
		if not sock then break end
		local entry = make_entry(sock)
		MP.SERVER._clients[#MP.SERVER._clients + 1] = entry
		entry.client:send_action({ action = "connected" })
		entry.client:send_action({ action = "version" })
	end

	-- Drain each client and run its keepAlive state machine
	for _, entry in ipairs(MP.SERVER._clients) do
		if not entry.closed then
			while true do
				local line, err = entry.socket:receive("*l")
				if line then
					handle_message(entry, line)
					if entry.closed then break end
				elseif err == "closed" then
					mark_dead(entry)
					break
				else
					-- "timeout": nothing more to read this frame
					break
				end
			end

			if not entry.closed then
				if not entry.ka_sent then
					if now_t - entry.last_data >= KEEP_ALIVE_INITIAL_TIMEOUT then
						entry.client:send_action({ action = "keepAlive" })
						entry.ka_sent = true
						entry.ka_at = now_t
						entry.ka_retries = 0
					end
				elseif now_t - entry.ka_at >= KEEP_ALIVE_RETRY_TIMEOUT then
					entry.client:send_action({ action = "keepAlive" })
					entry.ka_retries = entry.ka_retries + 1
					entry.ka_at = now_t
					if entry.ka_retries >= KEEP_ALIVE_RETRY_COUNT then
						mark_dead(entry)
					end
				end
			end
		end
	end

	-- Reconnect grace-period expiry
	for _, lobby in pairs(MP.SERVER.Lobbies) do
		local slot = lobby.disconnected_slot
		if slot and now_t >= slot.expires_at then
			lobby:expire_disconnected_slot()
		end
	end

	-- Deferred stop once the last lobby is gone
	if MP.SERVER._stop_requested and next(MP.SERVER.Lobbies) == nil then
		do_stop()
		return
	end

	-- Sweep dead entries
	local alive = {}
	for _, entry in ipairs(MP.SERVER._clients) do
		if not entry.closed then
			alive[#alive + 1] = entry
		end
	end
	MP.SERVER._clients = alive
end

-- ─── Game:update wiring ─────────────────────────────────────────────────────

-- The server must tick in every stage (gameplay happens outside MAIN_MENU),
-- unlike MP.LAN's discovery tick which is menu-only.
local function install_tick()
	if MP.SERVER._tick_installed then return end
	MP.SERVER._tick_installed = true
	local orig = Game.update
	function Game:update(dt)
		orig(self, dt)
		if MP.SERVER._running or MP.SERVER._stop_requested then
			pcall(MP.SERVER.tick)
		end
	end
end

-- action_handlers.lua already wraps Game:update unconditionally at this point
-- in the load order, so Game.update is available; the guard is just belt and
-- suspenders for exotic load orders.
if Game and Game.update then
	install_tick()
end
