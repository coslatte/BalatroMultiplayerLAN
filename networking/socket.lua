-- Code for networking stuff that runs in a separate thread

-- Since threads run on a separate lua environment, we need to require
-- the necessary modules again
return [[
local CONFIG_URL, CONFIG_PORT, THREAD_GEN = ...
local MY_GEN = tonumber(THREAD_GEN) or 1

require("love.filesystem")
local json = require("json")
local socket = require("socket")

local DEBUGGING = false

-- Defining this again, for debugging this thread
local function initializeThreadDebugSocketConnection()
	CLIENT = socket.connect("localhost", 12346)
	if not CLIENT then
		sendWarnMessage("Failed to connect to the debug server", "MULTIPLAYER")
	end
end

function SEND_THREAD_DEBUG_MESSAGE(message)
	if DEBUGGING and CLIENT and message then
		CLIENT:send(message .. "\n")
	end
end

if DEBUGGING then
	initializeThreadDebugSocketConnection()
end

Networking = {}
local isSocketClosed = true
local hasGivenUp = false -- true after all reconnect attempts failed
local networkToUiChannel = love.thread.getChannel("networkToUi")
local uiToNetworkChannel = love.thread.getChannel("uiToNetwork")

-- LAN thread replacement: when the networking thread is restarted (LAN mode
-- switches the endpoint), the old thread is asked to go inert via a quit
-- sentinel. Two live threads would both pop uiToNetwork and split outgoing
-- messages between a dead socket and the new one. The sentinel carries the
-- generation of the replacement thread; a thread only quits for a generation
-- newer than its own.
local QUIT_PREFIX = "__MP_THREAD_QUIT__"
local function quit_sentinel_for_me(msg)
	if type(msg) ~= "string" then return false end
	if msg:sub(1, #QUIT_PREFIX) ~= QUIT_PREFIX then return false end
	local gen = tonumber(msg:sub(#QUIT_PREFIX + 1))
	return gen == nil or gen > MY_GEN
end

-- Reconnection settings
local maxReconnectAttempts = 3
local reconnectDelays = { 2, 4, 8 } -- seconds, exponential backoff

function Networking.connect()
	-- TODO: Check first if Networking.Client is not null
	-- and if it is, skip this function

	SEND_THREAD_DEBUG_MESSAGE(
		string.format("Attempting to connect to multiplayer server... URL: %s, PORT: %d", CONFIG_URL, CONFIG_PORT)
	)

	Networking.Client = socket.tcp()
	-- Allow for 10 seconds to reconnect
	Networking.Client:settimeout(10)

	Networking.Client:setoption("tcp-nodelay", true)
	local connectionResult, errorMessage = Networking.Client:connect(CONFIG_URL, CONFIG_PORT) -- Not sure if I want to make these values public yet

	if connectionResult ~= 1 then
		SEND_THREAD_DEBUG_MESSAGE(string.format("%s", errorMessage))
		networkToUiChannel:push(json.encode({
			action = "error",
			message = "Failed to connect to multiplayer server",
		}))
		return false
	else
		isSocketClosed = false
		hasGivenUp = false
	end

	Networking.Client:settimeout(0)
	return true
end

-- Attempt automatic reconnection with exponential backoff.
-- Returns true if reconnected, false if all attempts failed.
function Networking.tryReconnect()
	SEND_THREAD_DEBUG_MESSAGE("Connection lost, attempting automatic reconnection...")

	for attempt = 1, maxReconnectAttempts do
		local delay = reconnectDelays[attempt] or reconnectDelays[#reconnectDelays]
		SEND_THREAD_DEBUG_MESSAGE(string.format("Reconnect attempt %d/%d in %ds...", attempt, maxReconnectAttempts, delay))
		-- Abort reconnecting if a replacement thread already took over
		if quit_sentinel_for_me(uiToNetworkChannel:peek()) then
			SEND_THREAD_DEBUG_MESSAGE("Replacement thread detected, abandoning reconnection.")
			return false
		end
		socket.sleep(delay)

		if Networking.connect() then
			SEND_THREAD_DEBUG_MESSAGE("Reconnected successfully!")
			return true
		end
	end

	SEND_THREAD_DEBUG_MESSAGE("All reconnection attempts failed.")
	return false
end

-- Check for messages from the main thread
local mainThreadMessageQueue = function()
	-- Executes a max of requestsPerCycle action requests
	-- from the main thread and then yields
	local requestsPerCycle = 25
	while true do
		for _ = 1, requestsPerCycle do
			local msg = uiToNetworkChannel:pop()
			if msg then
				if quit_sentinel_for_me(msg) then
					-- We are obsolete: close up and go inert. Returning ends
					-- this coroutine, so this thread never touches the
					-- uiToNetwork channel again.
					if Networking.Client then
						pcall(function() Networking.Client:close() end)
					end
					isSocketClosed = true
					hasGivenUp = true
					love.thread.getChannel("mpThreadQuitAck"):push("ok")
					return
				end
				if msg == "{\"action\":\"connect\"}" then
					hasGivenUp = false
					Networking.connect()
				else
					Networking.Client:send(msg .. "\n")
				end
			else
				-- If there are no more messages, yield
				coroutine.yield()
			end
		end

		coroutine.yield()
	end
end
local mainThreadCoroutine = coroutine.create(mainThreadMessageQueue)

local timer = function(time)
	local init = os.time()
	local diff = os.difftime(os.time(), init)
	while diff < time do
		coroutine.yield(diff)
		diff = os.difftime(os.time(), init)
	end
end
local timerCoroutine = coroutine.create(timer)

-- All values are in seconds
local keepAliveInitialTimeout = 20
local keepAliveRetryTimeout = 5
local keepAliveRetryCount = 4

local isRetry = false
local retryCount = 0

-- Check for network packets
local networkPacketQueue = function()
	local packetsPerCycle = 25
	while true do
		if Networking.Client and not hasGivenUp then
			-- Tries to fetch a packet a max of packetsPerCycle times
			-- and then yields
			for _ = 1, packetsPerCycle do
				local data, error, partial = Networking.Client:receive()
				if data then
					-- Packet arrived, reset retries
					isRetry = false
					retryCount = 0
					-- Also reset timer
					timerCoroutine = coroutine.create(timer)

					-- Respond to server keepAlive directly on the socket
					-- to avoid latency from routing through the UI thread
					if string.find(data, '"keepAlive"') and not string.find(data, 'Ack') then
						Networking.Client:send('{"action":"keepAliveAck"}\n')
					end

					-- Send the string as is to the main thread
					networkToUiChannel:push(data)
				elseif error == "close" then
					-- Connection closed, attempt automatic reconnection
					isSocketClosed = true
					retryCount = 0
					isRetry = false
					timerCoroutine = coroutine.create(timer)

					networkToUiChannel:push("{\"action\":\"reconnecting\"}")
					if not Networking.tryReconnect() then
						hasGivenUp = true
						networkToUiChannel:push("{\"action\":\"disconnected\"}")
					end
					break
				else
					-- If there are no more packets, yield
					coroutine.yield()
				end
			end

			coroutine.yield()
		end

		coroutine.yield()
	end
end
local networkCoroutine = coroutine.create(networkPacketQueue)

-- Checks for network packets,
-- then sends them to the main thread
-- then advances timers
-- and then sleeps
while true do
	coroutine.resume(mainThreadCoroutine)
	coroutine.resume(networkCoroutine)

	-- Run Timer
	if not isSocketClosed and coroutine.status(timerCoroutine) ~= "dead" then
		coroutine.resume(timerCoroutine, keepAliveInitialTimeout)
	elseif not isSocketClosed then
		-- Timer triggered
		isRetry = true

		if retryCount > keepAliveRetryCount then
			Networking.Client:close()

			-- Keepalive failed, attempt automatic reconnection
			isSocketClosed = true
			retryCount = 0
			isRetry = false
			timerCoroutine = coroutine.create(timer)

			networkToUiChannel:push("{\"action\":\"reconnecting\"}")
			if not Networking.tryReconnect() then
				hasGivenUp = true
				networkToUiChannel:push("{\"action\":\"disconnected\"}")
			end
		end

		if isRetry then
			retryCount = retryCount + 1
			-- Send keepAlive without cutting the line
			uiToNetworkChannel:push("{\"action\":\"keepAlive\"}")

			-- Restart the timer
			timerCoroutine = coroutine.create(timer)
			coroutine.resume(timerCoroutine, keepAliveRetryTimeout)
		end
	end

	-- Sleeps for 50 milliseconds
	socket.sleep(0.05)
end
]]
