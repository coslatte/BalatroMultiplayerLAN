--[[
  Embedded LAN server lifecycle tests.

  Usage:
    lua tests/test_server_lifecycle.lua

  Run from the repo root.
]]

local passed, failed, errors = 0, 0, {}

local function assert_eq(name, got, want)
	if got == want then
		passed = passed + 1
	else
		failed = failed + 1
		errors[#errors + 1] = string.format("%s: expected %s, got %s", name, tostring(want), tostring(got))
	end
end

local function assert_true(name, val)
	assert_eq(name, not not val, true)
end

local function assert_nil(name, val)
	assert_eq(name, val, nil)
end

local function assert_not_nil(name, val)
	if val ~= nil then
		passed = passed + 1
	else
		failed = failed + 1
		errors[#errors + 1] = string.format("%s: expected non-nil, got nil", name)
	end
end

-- ─── Minimal stubs ──────────────────────────────────────────────────────────

-- Stub love.timer and love.thread for the server
local fake_time = 1000
love = {
	timer = {
		getTime = function() return fake_time end,
	},
	thread = {
		getChannel = function(name)
			return {
				peek = function() return nil end,
				pop = function() return nil end,
				push = function() end,
				demand = function() return nil end,
			}
		end,
		newThread = function(chunk)
			return { start = function() end, isRunning = function() return false end }
		end,
	},
}

-- Fake json + socket modules exposed via require()
local fake_json = {
	encode = function(t) return tostring(t) end,
	decode = function(s) return { action = s } end,
}
local fake_master = {}
local fake_client_socks = {}
local client_idx = 0
local function make_fake_socket()
	client_idx = client_idx + 1
	local id = client_idx
	return {
		settimeout = function() end,
		setoption = function() end,
		send = function(data) return #data end,
		receive = function() return nil, "timeout" end,
		close = function() end,
		_id = id,
	}
end
local fake_socket = {
	bind = function(ip, port)
		fake_master.ip = ip
		fake_master.port = port
		fake_master.closed = false
		return {
			settimeout = function() end,
			accept = function()
				if #fake_client_socks > 0 then return table.remove(fake_client_socks, 1) end
				return nil
			end,
			close = function() fake_master.closed = true end,
		}
	end,
	sleep = function() end,
}
package.preload["json"] = function() return fake_json end
package.preload["socket"] = function() return fake_socket end
-- Keep globals for direct access too
json = fake_json
socket = fake_socket

-- Stub Game (required by networking/server/init.lua tick installer)
Game = { update = function(self, dt) end }
G = { STAGES = { MAIN_MENU = 0 }, STAGE = 0, E_MANAGER = { add_event = function() end } }

-- Stub SMODS config
SMODS = {
	Mods = {
		["Multiplayer"] = {
			config = {
				server_port = 8788,
				lan_bind_ip = "",
				lan_broadcast_port = 8789,
			},
		},
	},
}

-- Stub sendDebugMessage / sendWarnMessage
function sendDebugMessage() end
function sendWarnMessage() end

-- ─── Stub MP.INSANE_INT ─────────────────────────────────────────────────────

MP = {
	INSANE_INT = {
		empty = function() return { parts = {} } end,
		from_string = function(s)
			return { parts = { s } }
		end,
		greater_than = function(a, b)
			-- Simple comparison for test: compare string representations
			local sa = a.parts and a.parts[1] or "0"
			local sb = b.parts and b.parts[1] or "0"
			return tonumber(sa) > tonumber(sb)
		end,
		equal = function(a, b)
			local sa = a.parts and a.parts[1] or "0"
			local sb = b.parts and b.parts[1] or "0"
			return sa == sb
		end,
	},
	SERVER = {},
	GAME = { enemy = { score = { parts = { "0" } } } },
	LOBBY = { connected = false, config = {} },
	ENV = { server_url = "" },
}

-- ─── Load server modules ────────────────────────────────────────────────────

dofile("networking/server/lobby.lua")
dofile("networking/server/handlers.lua")
dofile("networking/server/init.lua")

-- ─── Test: Lobby creation ──────────────────────────────────────────────────

local function test_lobby_creation()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")

	assert_not_nil("lobby created", lobby)
	assert_not_nil("lobby code", lobby.code)
	assert_eq("lobby code length", #lobby.code, 5)
	assert_eq("game mode", lobby.game_mode, "attrition")
	assert_eq("host set", lobby.host, host)
	assert_nil("guest nil", lobby.guest)
	assert_true("lobby registered", MP.SERVER.Lobbies[lobby.code] ~= nil)
	assert_eq("host lobby", host.lobby, lobby)
end

-- ─── Test: Lobby join ───────────────────────────────────────────────────────

local function test_lobby_join()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")

	lobby:join(guest)
	assert_eq("guest set", lobby.guest, guest)
	assert_eq("guest lobby", guest.lobby, lobby)
end

-- ─── Test: Lobby join when full ─────────────────────────────────────────────

local function test_lobby_join_full()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest1 = MP.SERVER.ClientState.new(function() end, function() end)
	local guest2 = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")

	lobby:join(guest1)
	lobby:join(guest2)
	-- guest2 should not be in the lobby
	assert_nil("third player rejected", lobby.guest == guest2 and guest2 or nil)
end

-- ─── Test: Lobby leave (host leaves) ───────────────────────────────────────

local function test_lobby_leave_host()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	lobby:join(guest)

	lobby:leave(host)
	-- Guest becomes host
	assert_eq("guest promoted to host", lobby.host, guest)
	assert_nil("old host gone", lobby.guest)
end

-- ─── Test: Lobby leave (guest leaves) ──────────────────────────────────────

local function test_lobby_leave_guest()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	lobby:join(guest)

	lobby:leave(guest)
	assert_nil("guest removed", lobby.guest)
	assert_eq("host unchanged", lobby.host, host)
end

-- ─── Test: Lobby destroy when empty ─────────────────────────────────────────

local function test_lobby_destroy()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	local code = lobby.code

	lobby:leave(host)
	assert_nil("lobby destroyed", MP.SERVER.Lobbies[code])
end

-- ─── Test: Lobby code uniqueness ────────────────────────────────────────────

local function test_lobby_code_uniqueness()
	local codes = {}
	for i = 1, 50 do
		local host = MP.SERVER.ClientState.new(function() end, function() end)
		local lobby = MP.SERVER.Lobby.new(host, "attrition")
		codes[lobby.code] = true
		-- Clean up to allow code reuse
		MP.SERVER.Lobbies[lobby.code] = nil
	end
	-- All 50 codes should be unique (5 chars, 26^5 = 11M+ possibilities)
	local count = 0
	for _ in pairs(codes) do count = count + 1 end
	assert_eq("50 unique codes generated", count, 50)
end

-- ─── Test: Server start/stop ────────────────────────────────────────────────

local function test_server_start_stop()
	-- Reset state
	MP.SERVER._running = false
	MP.SERVER._master = nil
	MP.SERVER._clients = nil
	MP.SERVER.Lobbies = {}

	local ok, err = MP.SERVER.start(8788)
	assert_true("server starts", ok)
	assert_true("server is running", MP.SERVER.is_running())
	assert_not_nil("master socket", MP.SERVER._master)

	MP.SERVER.stop()
	assert_true("server stopped", not MP.SERVER.is_running())
	assert_nil("master cleared", MP.SERVER._master)
end

-- ─── Test: Server double start is idempotent ────────────────────────────────

local function test_server_double_start()
	MP.SERVER._running = false
	MP.SERVER._master = nil
	MP.SERVER._clients = nil
	MP.SERVER.Lobbies = {}

	MP.SERVER.start(8788)
	local ok2 = MP.SERVER.start(8788)
	assert_true("double start is ok", ok2)
	-- Cleanup
	MP.SERVER.stop()
end

-- ─── Test: Server request_stop (deferred) ───────────────────────────────────

local function test_server_request_stop()
	MP.SERVER._running = false
	MP.SERVER._master = nil
	MP.SERVER._clients = nil
	MP.SERVER.Lobbies = {}

	MP.SERVER.start(8788)
	MP.SERVER.request_stop()
	assert_true("_stop_requested set", MP.SERVER._stop_requested)
	-- Tick with no lobbies should honor the deferred stop
	MP.SERVER.tick()
	assert_true("server stopped after tick", not MP.SERVER.is_running())
end

-- ─── Test: get_enemy ────────────────────────────────────────────────────────

local function test_get_enemy()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	lobby:join(guest)

	local lob1, enemy1 = MP.SERVER.get_enemy(host)
	assert_eq("host enemy is guest", enemy1, guest)
	assert_eq("host lobby ref", lob1, lobby)

	local lob2, enemy2 = MP.SERVER.get_enemy(guest)
	assert_eq("guest enemy is host", enemy2, host)
	assert_eq("guest lobby ref", lob2, lobby)
end

-- ─── Test: get_enemy with no lobby ──────────────────────────────────────────

local function test_get_enemy_no_lobby()
	local orphan = MP.SERVER.ClientState.new(function() end, function() end)
	local lob, enemy = MP.SERVER.get_enemy(orphan)
	assert_nil("no lobby for orphan", lob)
	assert_nil("no enemy for orphan", enemy)
end

-- ─── Test: disconnect_from_lobby ────────────────────────────────────────────

local function test_disconnect_from_lobby()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local guest = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	lobby:join(guest)

	-- Disconnect the guest (not in-game → regular leave)
	MP.SERVER.disconnect_from_lobby(guest)
	assert_nil("guest disconnected", lobby.guest)
end

-- ─── Test: Lobby get by code ────────────────────────────────────────────────

local function test_lobby_get_by_code()
	local host = MP.SERVER.ClientState.new(function() end, function() end)
	local lobby = MP.SERVER.Lobby.new(host, "attrition")
	local code = lobby.code

	local found = MP.SERVER.Lobby.get(code)
	assert_eq("lobby found by code", found, lobby)

	local missing = MP.SERVER.Lobby.get("ZZZZZ")
	assert_nil("missing code returns nil", missing)
end

-- ─── Test: ClientState score ────────────────────────────────────────────────

local function test_client_score()
	local client = MP.SERVER.ClientState.new(function() end, function() end)
	client:set_score("12345")
	assert_eq("score_raw set", client.score_raw, "12345")
end

-- ─── Test: ClientState lose_life ────────────────────────────────────────────

local function test_client_lose_life()
	local messages = {}
	local client = MP.SERVER.ClientState.new(
		function(msg) messages[#messages + 1] = msg end,
		function() end
	)
	client.lives = 4
	client:lose_life("round")
	assert_eq("lives decremented", client.lives, 3)
	-- Duplicate cause should be blocked
	client:lose_life("round")
	assert_eq("duplicate round blocked", client.lives, 3)
	-- Timer cause is separate
	client:lose_life("timer")
	assert_eq("timer cause allowed", client.lives, 2)
end

-- ─── Test: Thread generation sentinel ───────────────────────────────────────
-- Extract the quit_sentinel_for_me logic and test it in isolation

local QUIT_PREFIX = "__MP_THREAD_QUIT__"

local function quit_sentinel_for_me(msg, my_gen)
	if type(msg) ~= "string" then return false end
	if msg:sub(1, #QUIT_PREFIX) ~= QUIT_PREFIX then return false end
	local gen = tonumber(msg:sub(#QUIT_PREFIX + 1))
	return gen == nil or gen > my_gen
end

local function test_sentinel_not_quit_message()
	assert_true("normal msg not sentinel", not quit_sentinel_for_me("{\"action\":\"connect\"}", 1))
end

local function test_sentinel_quit_newer_gen()
	assert_true("newer gen triggers quit", quit_sentinel_for_me("__MP_THREAD_QUIT__3", 1))
end

local function test_sentinel_quit_same_gen()
	assert_true("same gen does not quit", not quit_sentinel_for_me("__MP_THREAD_QUIT__1", 1))
end

local function test_sentinel_quit_older_gen()
	assert_true("older gen does not quit", not quit_sentinel_for_me("__MP_THREAD_QUIT__1", 3))
end

local function test_sentinel_quit_no_gen()
	assert_true("no gen treated as quit", quit_sentinel_for_me("__MP_THREAD_QUIT__", 1))
end

local function test_sentinel_non_string()
	assert_true("non-string not sentinel", not quit_sentinel_for_me(nil, 1))
	assert_true("number not sentinel", not quit_sentinel_for_me(42, 1))
end

-- ─── Test: generate_seed ────────────────────────────────────────────────────

local function test_generate_seed()
	local seed = MP.SERVER.generate_seed(8)
	assert_eq("seed length", #seed, 8)
	-- All chars should be in the valid set
	assert_true("seed is alphanumeric", seed:match("^[A-Z1-9]+$") ~= nil)
end

-- ─── Run all tests ──────────────────────────────────────────────────────────

local tests = {
	test_lobby_creation,
	test_lobby_join,
	test_lobby_join_full,
	test_lobby_leave_host,
	test_lobby_leave_guest,
	test_lobby_destroy,
	test_lobby_code_uniqueness,
	test_server_start_stop,
	test_server_double_start,
	test_server_request_stop,
	test_get_enemy,
	test_get_enemy_no_lobby,
	test_disconnect_from_lobby,
	test_lobby_get_by_code,
	test_client_score,
	test_client_lose_life,
	test_sentinel_not_quit_message,
	test_sentinel_quit_newer_gen,
	test_sentinel_quit_same_gen,
	test_sentinel_quit_older_gen,
	test_sentinel_quit_no_gen,
	test_sentinel_non_string,
	test_generate_seed,
}

for idx, test_fn in ipairs(tests) do
	local info = debug.getinfo(test_fn, "n")
	local fname = (info and info.name) or ("test#" .. idx)
	local ok, err = pcall(test_fn)
	if not ok then
		failed = failed + 1
		errors[#errors + 1] = string.format("ERROR in %s: %s", fname, tostring(err))
	end
end

-- ─── Report ─────────────────────────────────────────────────────────────────

print(string.format("\nServer lifecycle test: %d passed, %d failed", passed, failed))
if #errors > 0 then
	print("\nFailures:")
	for _, err in ipairs(errors) do
		print("  " .. err)
	end
	os.exit(1)
else
	print("All tests passed.")
end
