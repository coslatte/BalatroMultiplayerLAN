-- Embedded LAN game server: state model.
-- Faithful Lua port of the official server's Client.ts / Lobby.ts / GameMode.ts
-- (github.com/Balatro-Multiplayer/BalatroMultiplayerAPI-Server). The wire
-- protocol is byte-identical, so the unmodified game client works against this
-- server exactly like it does against the online one — that is the parity
-- contract: same golden logic, hosted locally for LAN, remote for online.
--
-- Score handling: each client keeps BOTH the parsed InsaneInt (for
-- authoritative comparisons) and the raw score string (for relaying), so values
-- round-trip exactly as the sending client formatted them.

MP.SERVER = MP.SERVER or {}

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function now()
	if love and love.timer and love.timer.getTime then return love.timer.getTime() end
	return os.time()
end
MP.SERVER.now = now

function MP.SERVER.less_than(a, b)
	return MP.INSANE_INT.greater_than(b, a)
end

function MP.SERVER.generate_seed(length)
	length = length or 8
	local chars = "ABCDEFGHIJKLMNPQRSTUVWXYZ123456789"
	local result = ""
	for _ = 1, length do
		local i = math.random(1, #chars)
		result = result .. chars:sub(i, i)
	end
	return result
end

local function random_hex(len)
	local result = ""
	for _ = 1, len do
		result = result .. string.format("%x", math.random(0, 15))
	end
	return result
end

-- No-op until init.lua overrides it (auto-stop when the last lobby dies)
MP.SERVER.on_lobby_destroyed = function() end

-- ─── Game modes (GameMode.ts) ───────────────────────────────────────────────

MP.SERVER.GameModes = {
	attrition = { starting_lives = 4 },
	showdown = { starting_lives = 2 },
	survival = { starting_lives = 1 },
}

-- How long to keep a disconnected player's slot reserved (seconds)
MP.SERVER.RECONNECT_GRACE_PERIOD = 60

-- ─── Client state (Client.ts) ───────────────────────────────────────────────

local ClientState = {}
ClientState.__index = ClientState
MP.SERVER.ClientState = ClientState

function ClientState.new(send_fn, close_fn)
	local self = setmetatable({}, ClientState)
	self.id = random_hex(8)
	self.send_action = send_fn
	self.close_connection = close_fn
	-- Token used to verify identity when reconnecting to a lobby
	self.reconnect_token = random_hex(16)
	self.username = "Guest"
	self.mod_hash = "NULL"
	self.lobby = nil
	self.is_ready_lobby = false
	-- Whether player is ready for next blind
	self.is_ready = false
	self.first_ready = false
	self.lives = 5
	self.score = MP.INSANE_INT.empty()
	self.score_raw = "0"
	self.hands_left = 4
	-- Whether this player has played a hand in the current blind. Used to
	-- withhold the opponent's score until the player has committed a hand.
	self.played_this_blind = false
	self.ante = 1
	self.skips = 0
	self.furthest_blind = 0
	-- Guards against a duplicate life loss from the *same* cause firing twice
	-- (e.g. two failRound call sites for one blind failure). Kept separate per
	-- cause so a timer expiry and a blind/round loss can each cost a life even
	-- when they happen within the same round.
	self.round_lives_blocker = false
	self.timer_lives_blocker = false
	self.location = "loc_selecting"
	self.is_cached = true
	return self
end

function ClientState:set_location(location)
	self.location = location
	if self.lobby then
		if self.lobby.host == self then
			if self.lobby.guest then
				self.lobby.guest:send_action({ action = "enemyLocation", location = self.location })
			end
		elseif self.lobby.host then
			self.lobby.host:send_action({ action = "enemyLocation", location = self.location })
		end
	end
end

function ClientState:set_username(username)
	self.username = username
	if self.lobby then self.lobby:broadcast_lobby_info() end
end

function ClientState:set_mod_hash(mod_hash)
	self.mod_hash = mod_hash
	if self.lobby then self.lobby:broadcast_lobby_info() end
end

function ClientState:set_lobby(lobby)
	self.lobby = lobby
end

function ClientState:reset_blocker()
	self.round_lives_blocker = false
	self.timer_lives_blocker = false
end

function ClientState:set_score(score_str)
	score_str = tostring(score_str or "0")
	self.score = MP.INSANE_INT.from_string(score_str)
	self.score_raw = score_str
end

function ClientState:set_skips(skips)
	self.skips = skips
end

-- cause: "round" for a blind/PvP-hand loss, "timer" for an ante/PvP timer
-- expiry. Each cause has its own once-per-round guard.
function ClientState:lose_life(cause)
	local already_lost
	if cause == "timer" then
		already_lost = self.timer_lives_blocker
	else
		already_lost = self.round_lives_blocker
	end
	if already_lost then return end

	self.lives = self.lives - 1
	if cause == "timer" then
		self.timer_lives_blocker = true
	else
		self.round_lives_blocker = true
	end
	self:send_action({ action = "playerInfo", lives = self.lives })
	if self.lobby and self.lobby.host and self.lobby.guest then
		local enemy = self.lobby.host == self and self.lobby.guest or self.lobby.host
		enemy:send_action({
			action = "enemyInfo",
			handsLeft = self.hands_left,
			score = self.score_raw,
			skips = self.skips,
			lives = self.lives,
		})
	end
end

-- ─── Lobby (Lobby.ts) ───────────────────────────────────────────────────────

MP.SERVER.Lobbies = {}

local function generate_unique_lobby_code()
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	while true do
		local result = ""
		for _ = 1, 5 do
			local i = math.random(1, #chars)
			result = result .. chars:sub(i, i)
		end
		if not MP.SERVER.Lobbies[result] then return result end
	end
end

-- Returns (lobby, enemy) for a client. Enemy is nil when alone in the lobby.
function MP.SERVER.get_enemy(client)
	local lobby = client.lobby
	if not lobby then return nil, nil end
	if lobby.host and lobby.host.id == client.id then
		return lobby, lobby.guest
	elseif lobby.guest and lobby.guest.id == client.id then
		return lobby, lobby.host
	end
	return lobby, nil
end

local Lobby = {}
Lobby.__index = Lobby
MP.SERVER.Lobby = Lobby

function Lobby.get(code)
	return MP.SERVER.Lobbies[code]
end

-- Attrition is the default game mode
function Lobby.new(host_client, game_mode)
	local self = setmetatable({}, Lobby)
	self.code = generate_unique_lobby_code()
	MP.SERVER.Lobbies[self.code] = self
	self.host = host_client
	self.guest = nil
	self.game_mode = game_mode or "attrition"
	self.options = {}
	self.tcg_bets = {}
	self.handy_allow_mp_extension = {}
	self.first_ready_at = nil
	-- Tracks a disconnected player awaiting reconnection
	self.disconnected_slot = nil
	-- Whether a game is currently in progress
	self.is_in_game = false
	-- Authoritative seed generated for the current game (nil until startGame,
	-- or for different-seeds games where each client uses its own)
	self.seed = nil

	host_client:set_lobby(self)
	host_client.is_ready_lobby = false
	host_client:send_action({
		action = "joinedLobby",
		code = self.code,
		type = self.game_mode,
		reconnectToken = host_client.reconnect_token,
	})
	return self
end

-- Voluntary leave — no grace period
function Lobby:leave(client)
	-- Cancel any pending reconnect slot for this lobby
	self.disconnected_slot = nil

	if self.host and self.host.id == client.id then
		self.host = self.guest
		self.guest = nil
	elseif self.guest and self.guest.id == client.id then
		self.guest = nil
	end

	client:set_lobby(nil)
	self.is_in_game = false

	local remaining = self.host or self.guest
	if not remaining then
		MP.SERVER.Lobbies[self.code] = nil
		MP.SERVER.on_lobby_destroyed()
	else
		self.handy_allow_mp_extension[client.id] = nil

		-- Stop game if someone leaves mid-game; remaining player returns to lobby
		self:broadcast_action({ action = "stopGame" })
		self:reset_players()
		self:broadcast_lobby_info()
	end
end

-- Connection lost — use grace period if a game is in progress and the
-- opponent is around to keep the lobby alive for.
function Lobby:disconnect(client)
	local is_host = self.host and self.host.id == client.id
	local is_guest = self.guest and self.guest.id == client.id
	if not is_host and not is_guest then return end

	-- If no game in progress or no other player, do a regular leave
	if not self.is_in_game or (is_host and not self.guest) or (is_guest and not self.host) then
		self:leave(client)
		return
	end

	local role = is_host and "host" or "guest"
	local enemy = is_host and self.guest or self.host

	-- Reserve the slot with a grace period (tick enforces the expiry)
	self.disconnected_slot = {
		reconnect_token = client.reconnect_token,
		client_id = client.id,
		role = role,
		expires_at = now() + MP.SERVER.RECONNECT_GRACE_PERIOD,
		saved = {
			lives = client.lives,
			score = client.score,
			score_raw = client.score_raw,
			hands_left = client.hands_left,
			ante = client.ante,
			skips = client.skips,
			furthest_blind = client.furthest_blind,
			is_ready = client.is_ready,
			first_ready = client.first_ready,
			is_ready_lobby = client.is_ready_lobby,
			round_lives_blocker = client.round_lives_blocker,
			timer_lives_blocker = client.timer_lives_blocker,
			location = client.location,
			username = client.username,
			mod_hash = client.mod_hash,
		},
	}

	-- Remove the client from the slot but keep the lobby alive
	if is_host then
		self.host = nil
	else
		self.guest = nil
	end
	client:set_lobby(nil)

	-- Notify the remaining player with the grace period so they can show a
	-- countdown
	if enemy then
		enemy:send_action({ action = "enemyDisconnected", timeout = MP.SERVER.RECONNECT_GRACE_PERIOD })
	end
end

-- Grace period expired: the vanished player's slot is already empty, so this
-- reduces to the remaining-player path of leave()
function Lobby:expire_disconnected_slot()
	local slot = self.disconnected_slot
	if not slot then return end
	self.disconnected_slot = nil

	self.handy_allow_mp_extension[slot.client_id] = nil
	self.is_in_game = false

	local remaining = self.host or self.guest
	if not remaining then
		MP.SERVER.Lobbies[self.code] = nil
		MP.SERVER.on_lobby_destroyed()
	else
		self:broadcast_action({ action = "stopGame" })
		self:reset_players()
		self:broadcast_lobby_info()
	end
end

-- Reconnecting client reclaims their slot
function Lobby:rejoin(new_client, reconnect_token)
	local slot = self.disconnected_slot
	if not slot or slot.reconnect_token ~= reconnect_token then
		return false
	end
	local saved = slot.saved
	self.disconnected_slot = nil

	-- Restore game state from the disconnected player onto the new client
	new_client.lives = saved.lives
	new_client.score = saved.score
	new_client.score_raw = saved.score_raw
	new_client.hands_left = saved.hands_left
	new_client.ante = saved.ante
	new_client.skips = saved.skips
	new_client.furthest_blind = saved.furthest_blind
	new_client.is_ready = saved.is_ready
	new_client.first_ready = saved.first_ready
	new_client.is_ready_lobby = saved.is_ready_lobby
	new_client.round_lives_blocker = saved.round_lives_blocker
	new_client.timer_lives_blocker = saved.timer_lives_blocker
	new_client.location = saved.location
	new_client.username = saved.username
	new_client.mod_hash = saved.mod_hash

	-- Place the new client in the correct slot
	if slot.role == "host" then
		self.host = new_client
	else
		self.guest = new_client
	end
	new_client:set_lobby(self)
	self.handy_allow_mp_extension[new_client.id] = false

	-- Send rejoin confirmation with the new reconnect token
	new_client:send_action({
		action = "rejoinedLobby",
		code = self.code,
		type = self.game_mode,
		reconnectToken = new_client.reconnect_token,
	})

	-- Notify the other player
	local enemy = slot.role == "host" and self.guest or self.host
	if enemy then enemy:send_action({ action = "enemyReconnected" }) end

	self:broadcast_lobby_info()
	return true
end

function Lobby:join(client)
	if self.guest then
		client:send_action({
			action = "error",
			message = "Lobby is full or does not exist.",
		})
		return
	end

	self.guest = client
	client:set_lobby(self)
	client.is_ready_lobby = false
	self.handy_allow_mp_extension[client.id] = false
	client:send_action({
		action = "joinedLobby",
		code = self.code,
		type = self.game_mode,
		reconnectToken = client.reconnect_token,
	})
	local opts = { action = "lobbyOptions", gamemode = self.game_mode }
	for k, v in pairs(self.options) do
		opts[k] = v
	end
	client:send_action(opts)
	self:broadcast_lobby_info()
end

function Lobby:broadcast_action(action)
	if self.host then self.host:send_action(action) end
	if self.guest then self.guest:send_action(action) end
end

function Lobby:broadcast_lobby_info()
	if not self.host then return end

	local action = {
		action = "lobbyInfo",
		host = self.host.username,
		hostHash = self.host.mod_hash,
		isHost = false,
		hostCached = self.host.is_cached,
	}

	if self.guest then
		action.guest = self.guest.username
		action.guestHash = self.guest.mod_hash
		action.guestCached = self.guest.is_cached
		action.guestReady = self.guest.is_ready_lobby
		self.guest:send_action(action)
	end

	-- Should only send true to the host
	action.isHost = true
	self.host:send_action(action)

	local enabled = true
	for _, v in pairs(self.handy_allow_mp_extension) do
		if not v then
			enabled = false
			break
		end
	end
	self:broadcast_action({ action = "handyMPExtensionLobbyEnabled", enabled = enabled })
end

function Lobby:set_players_lives(lives)
	if self.host then self.host.lives = lives end
	if self.guest then self.guest.lives = lives end
	self:broadcast_action({ action = "playerInfo", lives = lives })
end

function Lobby:set_options(options)
	for k, v in pairs(options) do
		if v == "true" then
			self.options[k] = true
		elseif v == "false" then
			self.options[k] = false
		else
			self.options[k] = v
		end
	end
	if self.guest then
		local opts = { action = "lobbyOptions", gamemode = self.game_mode }
		for k, v in pairs(options) do
			opts[k] = v
		end
		self.guest:send_action(opts)
	end
end

function Lobby:reset_players()
	self.is_in_game = false
	local players = { self.host, self.guest }
	for _, p in ipairs(players) do
		if p then
			p.is_ready = false
			p:reset_blocker()
			p:set_location("Blind Select")
			p.furthest_blind = 0
			p.skips = 0
			p:set_score("0")
		end
	end
	self.tcg_bets = {}
	self.first_ready_at = nil
end
