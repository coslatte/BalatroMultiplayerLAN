-- Embedded LAN game server: action handlers.
-- Faithful Lua port of the official server's actionHandlers.ts
-- (github.com/Balatro-Multiplayer/BalatroMultiplayerAPI-Server). Every handler
-- mirrors its TS counterpart's semantics — field names, truthiness checks, and
-- authoritative decisions (lives, PvP outcomes, win conditions) included.
--
-- Handlers receive (args, client) where args is the decoded message minus the
-- action field, matching the TS `const { action, ...actionArgs }` destructuring.

local Lobby = MP.SERVER.Lobby
local get_enemy = MP.SERVER.get_enemy
local GameModes = MP.SERVER.GameModes
local INSANE = MP.INSANE_INT
local less_than = MP.SERVER.less_than
local generate_seed = MP.SERVER.generate_seed
local zero = INSANE.empty

-- Mirrors the official server's version gate (warn only, never disconnect)
local SERVER_VERSION = "0.3.2-MULTIPLAYER"
local TCG_SERVER_VERSION = 1

local handlers = {}

-- Relays the given fields (action excluded) to the opponent under action_name
local function relay_to_enemy(client, action_name, fields)
	local _, enemy = get_enemy(client)
	if not enemy then return end
	local msg = { action = action_name }
	for k, v in pairs(fields or {}) do
		msg[k] = v
	end
	enemy:send_action(msg)
end

local function enemy_of(client)
	return select(2, get_enemy(client))
end

-- ─── Connection & identity ───────────────────────────────────────────────────

handlers.username = function(args, client)
	client:set_username(args.username)
	client:set_mod_hash(args.modHash)
end

handlers.version = function(args, client)
	local client_version = tostring(args.version or ""):match("^(%d+%.%d+%.%d+)")
	if not client_version then return end
	local cmajor, cminor, cpatch = client_version:match("^(%d+)%.(%d+)%.(%d+)")
	local smajor, sminor, spatch = SERVER_VERSION:match("^(%d+)%.(%d+)%.(%d+)")
	cmajor, cminor, cpatch = tonumber(cmajor), tonumber(cminor), tonumber(cpatch)
	if
		cmajor < smajor
		or (cmajor == smajor and cminor < sminor)
		or (cmajor == smajor and cminor == sminor and cpatch < spatch)
	then
		client:send_action({
			action = "error",
			message = "[WARN] Server expecting version " .. SERVER_VERSION,
		})
	end
end

handlers.syncClient = function(args, client)
	client.is_cached = args.isCached
end

handlers.keepAlive = function(_, client)
	client:send_action({ action = "keepAliveAck" })
end

-- ─── Lobby lifecycle ────────────────────────────────────────────────────────

handlers.createLobby = function(args, client)
	-- Also sets the client's lobby to the newly created one
	Lobby.new(client, args.gameMode)
end

handlers.joinLobby = function(args, client)
	local lobby = Lobby.get(args.code)
	if not lobby then
		client:send_action({
			action = "error",
			message = "Lobby does not exist.",
		})
		return
	end
	lobby:join(client)
end

handlers.rejoinLobby = function(args, client)
	local lobby = Lobby.get(args.code)
	if not lobby then
		client:send_action({
			action = "error",
			message = "Lobby no longer exists.",
		})
		return
	end
	if not lobby:rejoin(client, args.reconnectToken) then
		client:send_action({
			action = "error",
			message = "Could not rejoin lobby. Token invalid or slot expired.",
		})
	end
end

handlers.lobbyInfo = function(_, client)
	if client.lobby then client.lobby:broadcast_lobby_info() end
end

handlers.leaveLobby = function(_, client)
	if client.lobby then client.lobby:leave(client) end
end

handlers.readyLobby = function(_, client)
	client.is_ready_lobby = true
	if client.lobby then client.lobby:broadcast_lobby_info() end
end

handlers.unreadyLobby = function(_, client)
	client.is_ready_lobby = false
	if client.lobby then client.lobby:broadcast_lobby_info() end
end

handlers.lobbyOptions = function(args, client)
	if client.lobby then client.lobby:set_options(args) end
end

-- Deprecated upstream; kept so the action is a silent no-op instead of unknown
handlers.gameInfo = function() end

-- ─── Game start & blind flow ────────────────────────────────────────────────

handlers.startGame = function(_, client)
	local lobby = client.lobby

	-- Only allow the host to start the game
	if not lobby or not lobby.host or lobby.host.id ~= client.id then
		return
	end

	local lives
	if lobby.options.starting_lives then
		lives = math.floor(tonumber(lobby.options.starting_lives) or 0)
	else
		lives = (GameModes[lobby.game_mode] or GameModes.attrition).starting_lives
	end

	local seed = lobby.options.different_seeds and nil or generate_seed()
	lobby.seed = seed
	-- reset_players() clears is_in_game, so it must run before we set it below
	lobby:reset_players()

	lobby.is_in_game = true
	local start = { action = "startGame", deck = "c_multiplayer_1" }
	if seed then start.seed = seed end
	lobby:broadcast_action(start)

	-- Reset players' lives
	lobby:set_players_lives(lives)

	-- Unready guest for next game
	if lobby.guest then
		lobby.guest.is_ready_lobby = false
	end
end

handlers.readyBlind = function(_, client)
	client.is_ready = true

	local lobby, enemy = get_enemy(client)

	if not client.first_ready and (not enemy or (not enemy.is_ready and not enemy.first_ready)) then
		client.first_ready = true
		if lobby then lobby.first_ready_at = MP.SERVER.now() end
		client:send_action({ action = "speedrun" })
	end

	local lob = client.lobby
	if lob and lob.host and lob.guest and lob.host.is_ready and lob.guest.is_ready then
		-- Grant speedrun to the second player if within 30s of the first
		if lob.first_ready_at and (MP.SERVER.now() - lob.first_ready_at) <= 30 then
			client:send_action({ action = "speedrun" })
		end
		lob.first_ready_at = nil

		-- Reset ready status for next blind
		lob.host.is_ready = false
		lob.guest.is_ready = false

		-- Reset scores and hands left for next blind
		lob.host:set_score("0")
		lob.guest:set_score("0")
		lob.host.hands_left = 4
		lob.guest.hands_left = 4

		-- Reset per-blind hand-played gate so opponent scores are withheld
		-- again at the start of each blind
		lob.host.played_this_blind = false
		lob.guest.played_this_blind = false

		local first_player
		if lob.host.first_ready then first_player = "host" end
		if lob.guest.first_ready then first_player = "guest" end

		lob:broadcast_action({ action = "startBlind", firstPlayer = first_player })
	end
end

handlers.unreadyBlind = function(_, client)
	client.is_ready = false
end

handlers.newRound = function(_, client)
	client:reset_blocker()
end

-- ─── PvP core (playHand) ────────────────────────────────────────────────────

handlers.playHand = function(args, client)
	local lobby, enemy = get_enemy(client)

	if not lobby or not enemy or not lobby.host or not lobby.guest then
		handlers.stopGame(nil, client)
		return
	end

	client:set_score(args.score)

	local hands_left = args.handsLeft
	if type(hands_left) ~= "number" then
		hands_left = tonumber(hands_left)
	end
	client.hands_left = math.floor(hands_left or 0)

	-- Lobby option, default OFF: the client only enables it for standard-layer
	-- rulesets (and sends it explicitly), so gate only when it's truthy. Absent
	-- (old clients / non-standard rulesets) means the original immediate relay.
	local hide_score = not not lobby.options.hide_score_until_played
	-- A bootstrap play emitted at blind start reports score 0 (no hand actually
	-- committed). A real hand always scores > 0, so use that to decide whether
	-- the player has genuinely played this blind. Hand counts can vary in this
	-- game, so handsLeft is not a reliable signal.
	local played_real_hand = INSANE.greater_than(client.score, zero())
	if played_real_hand then client.played_this_blind = true end

	local host, guest = lobby.host, lobby.guest
	-- Equal scores: whoever readied first is "in front" for the PvP timer
	local is_host_turn
	if INSANE.equal(host.score, guest.score) then
		is_host_turn = host.first_ready
	else
		is_host_turn = INSANE.greater_than(host.score, guest.score)
	end

	-- Reveal our score to the enemy immediately, unless we're withholding it
	-- until they have also committed a hand this blind. This stops a player from
	-- watching the opponent's score before playing their own hand.
	if not hide_score or enemy.played_this_blind then
		enemy:send_action({
			action = "enemyInfo",
			handsLeft = args.handsLeft,
			score = client.score_raw,
			skips = client.skips,
			lives = client.lives,
			pvpTimerOrder = is_host_turn and "host" or "guest",
		})
	else
		enemy:send_action({
			action = "enemyInfo",
			handsLeft = args.handsLeft,
			noScore = true,
			skips = client.skips,
			lives = client.lives,
		})
	end

	-- On our first hand of the blind, send the enemy's current state to us. If
	-- they have already played, this is the score that was withheld until now;
	-- if they haven't, it's their reset state (score 0, full hands) — enough for
	-- us to stop masking their hand count now that we've committed our own hand.
	if not hide_score or client.played_this_blind then
		client:send_action({
			action = "enemyInfo",
			handsLeft = enemy.hands_left,
			score = enemy.score_raw,
			skips = enemy.skips,
			lives = enemy.lives,
			pvpTimerOrder = is_host_turn and "host" or "guest",
		})
	else
		client:send_action({
			action = "enemyInfo",
			handsLeft = enemy.hands_left,
			noScore = true,
			skips = enemy.skips,
			lives = enemy.lives,
		})
	end

	-- This info is only sent on a boss blind, so it shouldn't affect others
	local guest_out = guest.hands_left < 1 and less_than(guest.score, host.score)
	local host_out = host.hands_left < 1 and less_than(host.score, guest.score)
	local both_out = host.hands_left < 1 and guest.hands_left < 1
	if guest_out or host_out or both_out then
		local round_winner = less_than(guest.score, host.score) and host or guest
		local round_loser = round_winner == host and guest or host

		-- A tie never costs a life
		if not INSANE.equal(host.score, guest.score) then
			round_loser:lose_life("round")

			-- If no lives are left, we end the game
			if host.lives <= 0 or guest.lives <= 0 then
				local game_winner = host.lives > guest.lives and host or guest
				local game_loser = game_winner == host and guest or host

				game_winner:send_action({ action = "winGame" })
				game_loser:send_action({ action = "loseGame" })
				round_winner.first_ready = false
				round_loser.first_ready = false
				return
			end
		end

		round_winner.first_ready = false
		round_loser.first_ready = false
		round_winner:send_action({ action = "endPvP", lost = false })
		round_loser:send_action({
			action = "endPvP",
			lost = not INSANE.equal(guest.score, host.score),
		})
	end
end

-- ─── Life loss / win conditions ─────────────────────────────────────────────

handlers.failPvPTimer = function(_, client)
	local lobby = client.lobby

	client:lose_life("timer")

	if not lobby then return end

	if client.lives == 0 then
		local game_loser, game_winner
		if lobby.host and lobby.host.id == client.id then
			game_loser, game_winner = lobby.host, lobby.guest
		else
			game_loser, game_winner = lobby.guest, lobby.host
		end
		if game_winner then game_winner:send_action({ action = "winGame" }) end
		if game_loser then game_loser:send_action({ action = "loseGame" }) end
	else
		local round_winner, round_loser
		if lobby.host and lobby.host.id == client.id then
			round_winner, round_loser = lobby.guest, lobby.host
		else
			round_winner, round_loser = lobby.host, lobby.guest
		end
		if round_winner then round_winner.first_ready = false end
		if round_loser then round_loser.first_ready = false end
		if round_winner then
			round_winner:send_action({ action = "endPvP", lost = false, pvpTimerLost = true })
		end
		if round_loser then
			round_loser:send_action({ action = "endPvP", lost = true, pvpTimerLost = true })
		end
	end
end

handlers.failTimer = function(_, client)
	local lobby = client.lobby

	client:lose_life("timer")

	if not lobby then return end

	if client.lives == 0 then
		local game_loser, game_winner
		if lobby.host and lobby.host.id == client.id then
			game_loser, game_winner = lobby.host, lobby.guest
		else
			game_loser, game_winner = lobby.guest, lobby.host
		end
		if game_winner then game_winner:send_action({ action = "winGame" }) end
		if game_loser then game_loser:send_action({ action = "loseGame" }) end
	end
end

handlers.failRound = function(_, client)
	local lobby, enemy = get_enemy(client)
	if not lobby or not enemy then return end

	if lobby.options.death_on_round_loss then
		client:lose_life("round")
	end

	if client.lives == 0 then
		if lobby.game_mode == "survival" then
			if enemy.lives == 0 then
				if client.furthest_blind == enemy.furthest_blind then
					-- Survival draw behavior, both players win by default
					client:send_action({ action = "winGame" })
					enemy:send_action({ action = "winGame" })
				elseif client.furthest_blind < enemy.furthest_blind then
					client:send_action({ action = "loseGame" })
					enemy:send_action({ action = "winGame" })
				end
				-- Otherwise do nothing
			else
				if client.furthest_blind < enemy.furthest_blind then
					client:send_action({ action = "loseGame" })
					enemy:send_action({ action = "winGame" })
				end
				-- Otherwise do nothing
			end
		else
			local game_loser, game_winner
			if lobby.host and lobby.host.id == client.id then
				game_loser, game_winner = lobby.host, lobby.guest
			else
				game_loser, game_winner = lobby.guest, lobby.host
			end
			if game_winner then game_winner:send_action({ action = "winGame" }) end
			if game_loser then game_loser:send_action({ action = "loseGame" }) end
		end
	end
end

handlers.setFurthestBlind = function(args, client)
	local lobby, enemy = get_enemy(client)
	client.furthest_blind = args.furthestBlind
	if not lobby or not enemy then return end

	-- If enemy died and our furthestBlind is bigger, we win
	if lobby.game_mode == "survival" and enemy.lives == 0 and client.furthest_blind > enemy.furthest_blind then
		client:send_action({ action = "winGame" })
		enemy:send_action({ action = "loseGame" })
	end
end

handlers.stopGame = function(_, client)
	if not client.lobby then return end
	client.lobby:broadcast_action({ action = "stopGame" })
	client.lobby:reset_players()
end

-- ─── State reports ──────────────────────────────────────────────────────────

handlers.setAnte = function(args, client)
	client.ante = args.ante
end

handlers.setLocation = function(args, client)
	client:set_location(args.location)
end

handlers.skip = function(args, client)
	local _, enemy = get_enemy(client)
	client:set_skips(args.skips)
	if not enemy then return end
	enemy:send_action({
		action = "enemyInfo",
		handsLeft = client.hands_left,
		score = client.score_raw,
		skips = client.skips,
		lives = client.lives,
	})
end

handlers.dataSync = function(args, client)
	local enemy = enemy_of(client)
	if not enemy then return end
	local msg = { action = "dataSync" }
	local timer = tonumber(args.timer)
	if timer then msg.timer = timer end
	enemy:send_action(msg)
end

-- ─── Joker / effect relays ──────────────────────────────────────────────────

handlers.sendPhantom = function(args, client)
	relay_to_enemy(client, "sendPhantom", { key = args.key })
end

handlers.removePhantom = function(args, client)
	relay_to_enemy(client, "removePhantom", { key = args.key })
end

handlers.asteroid = function(_, client)
	relay_to_enemy(client, "asteroid", nil)
end

handlers.letsGoGamblingNemesis = function(_, client)
	relay_to_enemy(client, "letsGoGamblingNemesis", nil)
end

handlers.eatPizza = function(args, client)
	relay_to_enemy(client, "eatPizza", { whole = args.whole })
end

handlers.soldJoker = function(_, client)
	relay_to_enemy(client, "soldJoker", nil)
end

handlers.spentLastShop = function(args, client)
	relay_to_enemy(client, "spentLastShop", { amount = args.amount })
end

handlers.magnet = function(_, client)
	relay_to_enemy(client, "magnet", nil)
end

handlers.magnetResponse = function(args, client)
	relay_to_enemy(client, "magnetResponse", { key = args.key })
end

handlers.getEndGameJokers = function(_, client)
	relay_to_enemy(client, "getEndGameJokers", nil)
end

handlers.receiveEndGameJokers = function(args, client)
	relay_to_enemy(client, "receiveEndGameJokers", { keys = args.keys })
end

handlers.getNemesisDeck = function(_, client)
	relay_to_enemy(client, "getNemesisDeck", nil)
end

handlers.receiveNemesisDeck = function(args, client)
	relay_to_enemy(client, "receiveNemesisDeck", { cards = args.cards })
end

handlers.endGameStatsRequested = function(_, client)
	relay_to_enemy(client, "endGameStatsRequested", nil)
end

handlers.nemesisEndGameStats = function(args, client)
	relay_to_enemy(client, "nemesisEndGameStats", args)
end

handlers.startAnteTimer = function(args, client)
	local fields = { time = args.time }
	if args.isPvP then fields.isPvP = true end
	relay_to_enemy(client, "startAnteTimer", fields)
end

handlers.pauseAnteTimer = function(args, client)
	relay_to_enemy(client, "pauseAnteTimer", { time = args.time })
end

-- ─── Modded actions ─────────────────────────────────────────────────────────

handlers.moddedAction = function(args, client)
	local lobby, enemy = get_enemy(client)
	if not lobby or not enemy then return end

	local target = args.target
	local msg = { action = "moddedAction" }
	if lobby.host and lobby.host.id == client.id then
		msg.from = "host"
	else
		msg.from = "guest"
	end
	for k, v in pairs(args) do
		if k ~= "target" then msg[k] = v end
	end

	local relay_target = target or "nemesis"
	if relay_target == "all" then
		lobby:broadcast_action(msg)
	else
		enemy:send_action(msg)
	end
end

-- ─── Handy MP extension ─────────────────────────────────────────────────────

handlers.handyMPExtensionEnable = function(_, client)
	if not client.lobby then return end
	client.lobby.handy_allow_mp_extension[client.id] = true
	client.lobby:broadcast_lobby_info()
end

handlers.handyMPExtensionDisable = function(_, client)
	if not client.lobby then return end
	client.lobby.handy_allow_mp_extension[client.id] = false
	client.lobby:broadcast_lobby_info()
end

-- ─── Anti-cheat log storage (no-op for LAN — relay is between friends) ──────

handlers.submitLogHashes = function() end
handlers.streamLogLines = function() end

-- ─── TCG (deprecated upstream — kept for parity with TCG-modded clients) ────

handlers.tcgServerVersion = function(args, client)
	local version = tonumber(args.version)
	if version and version >= TCG_SERVER_VERSION then
		client:send_action({ action = "tcg_compatible" })
	end
end

handlers.startTcgBetting = function(_, client)
	local lobby = client.lobby

	-- Only allow the host to start the TCG game
	if not lobby or not lobby.host or lobby.host.id ~= client.id then
		return
	end

	-- Clear any existing bets
	lobby.tcg_bets = {}

	-- Broadcast startGame with seed to both players
	lobby:broadcast_action({
		action = "startGame",
		deck = "c_multiplayer_1",
		seed = generate_seed(),
	})
end

handlers.tcgBet = function(args, client)
	local lobby, enemy = get_enemy(client)
	if not lobby or not enemy then return end

	-- Store this client's bet
	lobby.tcg_bets[client.id] = tonumber(args.bet)

	-- Check if both players have bet
	if not lobby.host or not lobby.guest then return end
	if lobby.tcg_bets[lobby.host.id] == nil or lobby.tcg_bets[lobby.guest.id] == nil then
		return
	end

	-- Both players have bet, determine winner
	local host_bet = lobby.tcg_bets[lobby.host.id] or 0
	local guest_bet = lobby.tcg_bets[lobby.guest.id] or 0

	local winner, loser
	if host_bet > guest_bet then
		winner, loser = lobby.host, lobby.guest
	elseif guest_bet > host_bet then
		winner, loser = lobby.guest, lobby.host
	else
		-- Equal bets - flip a coin
		if math.random() < 0.5 then
			winner, loser = lobby.host, lobby.guest
		else
			winner, loser = lobby.guest, lobby.host
		end
	end

	local winner_bet = lobby.tcg_bets[winner.id] or 0

	-- Winner receives their bet as damage and starts first
	winner:send_action({
		action = "tcgStartGame",
		damage = winner_bet,
		starting = true,
	})

	-- Loser receives 0 damage and doesn't start
	loser:send_action({
		action = "tcgStartGame",
		damage = 0,
		starting = false,
	})

	-- Clear bets for next round
	lobby.tcg_bets = {}
end

handlers.tcgPlayerStatus = function(args, client)
	relay_to_enemy(client, "tcgPlayerStatus", args)
end

handlers.tcgEndTurn = function(args, client)
	relay_to_enemy(client, "tcgStartTurn", args)
end

-- ─── Registry ───────────────────────────────────────────────────────────────

MP.SERVER.handlers = handlers

-- Server-internal handler for connection drops (not a client action)
function MP.SERVER.disconnect_from_lobby(client)
	if client.lobby then
		client.lobby:disconnect(client)
	end
end
