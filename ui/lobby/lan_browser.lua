-- LAN Browser UI: host advertises, guests discover
-- Join screen: room code input + discovered list (primary).
-- Host screen: IP display + create lobby.

local function lan_host_ip_text()
	local ip = MP.LAN and MP.LAN.get_local_ip() or nil
	if ip then return ip end
	local cands = MP.LAN and MP.LAN.get_local_ip_candidates() or {}
	if #cands > 0 then return table.concat(cands, " / ") end
	return "192.168.43.1"
end

function G.UIDEF.create_UIBox_lan_host()
	local ip = lan_host_ip_text()
	local port = MP.LAN.get_default_port()
	MP.LAN._manual_ip = MP.LAN._manual_ip or ""
	if MP.LAN._manual_ip == "" then
		local auto = MP.LAN.get_local_ip()
		MP.LAN._manual_ip = auto or MP.LAN.get_hotspot_hint()
	end
	return create_UIBox_generic_options({
		back_func = "play_options",
		contents = {
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.15 },
				nodes = {
					{ n = G.UIT.T, config = { text = "LAN Host", scale = 0.5, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.1 },
				nodes = {
					{ n = G.UIT.T, config = { text = ip .. " : " .. port, scale = 0.42, colour = G.C.GREEN } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					{ n = G.UIT.T, config = { text = "Share this IP with guests on the same network", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.12 },
				nodes = {
					UIBox_button({ label = { "Copy IP" }, button = "lan_copy_ip", colour = G.C.BLUE, minw = 2.8, minh = 0.7, scale = 0.35 }),
					UIBox_button({ label = { "Create Lobby" }, button = "lan_create_lobby", colour = G.C.GREEN, minw = 3.5, minh = 0.85, scale = 0.4 }),
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.12 },
				nodes = {
					{ n = G.UIT.T, config = { text = "or enter IP manually", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					create_text_input({
						w = 4.2, h = 0.8,
						max_length = 21,
						prompt_text = "192.168.43.1",
						ref_table = MP.LAN,
						ref_value = "_manual_ip",
						extended_corpus = true,
						keyboard_offset = 4,
						callback = function() end,
					})
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					UIBox_button({ label = { "Use Manual IP & Create" }, button = "lan_create_manual", colour = G.C.ORANGE, minw = 4, minh = 0.7, scale = 0.35 }),
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					{ n = G.UIT.T, config = { text = "Hotspot IP is usually 192.168.43.1", scale = 0.26, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
		}
	})
end

function G.UIDEF.create_UIBox_lan_join()
	local discovered = MP.LAN and MP.LAN.get_discovered() or {}
	local nodes = {}

	-- Title
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.15 },
		nodes = {
			{ n = G.UIT.T, config = { text = "LAN Join", scale = 0.5, colour = G.C.UI.TEXT_LIGHT } }
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.05 },
		nodes = {
			{ n = G.UIT.T, config = { text = "Same network as host", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
		}
	})

	-- Discovered rooms list (primary way to join)
	if #discovered > 0 then
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.15 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Available Rooms (" .. #discovered .. "):", scale = 0.4, colour = G.C.GREEN } }
			}
		})
		for i, entry in ipairs(discovered) do
			if i > 6 then break end
			local code_text = entry.code and entry.code ~= "" and entry.code or "?????"
			local label = code_text .. "  " .. (entry.host or "Host") .. "  " .. entry.ip .. ":" .. entry.port
			G.FUNCS["lan_join_discovered_" .. i] = function()
				MP.LAN._join_target_ip = entry.ip
				MP.LAN._join_target_port = entry.port
				MP.LAN._join_target_code = entry.code
				if entry.code and entry.code ~= "" then
					MP.LAN.set_discover_callback(nil)
					MP.LAN.connect_to_host(entry.ip, entry.port)
					G.FUNCS.exit_overlay_menu()
					G.E_MANAGER:add_event(Event({
						trigger = "after", delay = 1.0, blockable = false, blocking = false,
						func = function()
							if MP.LOBBY.connected then
								MP.ACTIONS.join_lobby(entry.code)
							end
							return true
						end,
					}))
				end
			end
			table.insert(nodes, {
				n = G.UIT.R, config = { align = "cm", padding = 0.06 },
				nodes = {
					UIBox_button({ label = { label }, button = "lan_join_discovered_" .. i, colour = G.C.ORANGE, minw = 6, minh = 0.65, scale = 0.33 }),
				}
			})
		end
	else
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.2 },
			nodes = {
				{ n = G.UIT.T, config = { text = "No rooms found. Host must create first.", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.1 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Both devices must be on same Wi-Fi or hotspot.", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
	end

	-- Divider
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.12 },
		nodes = {
			{ n = G.UIT.T, config = { text = "- or join by room code -", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
		}
	})

	-- Room code input (letters only, A-Z — keyboard-native)
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			create_text_input({
				w = 3.5, h = 0.8,
				max_length = 5,
				prompt_text = "Room code",
				ref_table = MP.LAN,
				ref_value = "_join_code",
				extended_corpus = false,
				all_caps = true,
				keyboard_offset = 5,
				callback = function()
					local code = (MP.LAN._join_code or ""):upper():match("^%s*(.-)%s*$")
					if code ~= "" then
						G.FUNCS.lan_join_code()
					end
				end,
			})
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			UIBox_button({ label = { "Join" }, button = "lan_join_code", colour = G.C.RED, minw = 2.5, minh = 0.7, scale = 0.35 }),
			UIBox_button({ label = { "Refresh" }, button = "lan_refresh", colour = G.C.BLUE, minw = 2.5, minh = 0.7, scale = 0.35 }),
		}
	})

	-- Divider
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.12 },
		nodes = {
			{ n = G.UIT.T, config = { text = "- or connect by IP (physical keyboard) -", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
		}
	})

	-- IP input (secondary, needs physical keyboard for dots)
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			create_text_input({
				w = 4.2, h = 0.7,
				max_length = 21,
				prompt_text = "IP address",
				ref_table = MP.LAN,
				ref_value = "_join_ip",
				extended_corpus = true,
				keyboard_offset = 5,
				callback = function() end,
			})
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			UIBox_button({ label = { "Connect to IP" }, button = "lan_join_ip", colour = G.C.ORANGE, minw = 3.5, minh = 0.7, scale = 0.35 }),
		}
	})

	-- Back button
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.15 },
		nodes = {
			UIBox_button({ label = { "Back to Online" }, button = "lan_use_online", colour = G.C.GREY or G.C.UI.TEXT_LIGHT, minw = 3, minh = 0.6, scale = 0.35 }),
		}
	})

	return create_UIBox_generic_options({
		back_func = "play_options",
		contents = { { n = G.UIT.C, config = { align = "cm", padding = 0.1 }, nodes = nodes } }
	})
end

-- Callbacks
function G.FUNCS.lan_host_menu(e)
	MP.LAN._manual_ip = ""
	G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_host() })
end

function G.FUNCS.lan_join_menu(e)
	MP.LAN._join_code = ""
	MP.LAN._join_ip = ""
	if not MP.LAN._listener then
		MP.LAN.start_discovery()
	end
	G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
	-- Live auto-refresh: rebuild join UI when discovery finds/updates rooms
	MP.LAN.set_discover_callback(function()
		if G.OVERLAY_MENU then
			if MP.LAN._refresh_debounce and love.timer.getTime() - MP.LAN._refresh_debounce < 0.8 then return end
			MP.LAN._refresh_debounce = love.timer.getTime()
			-- Preserve input values across rebuild
			local saved_code = MP.LAN._join_code or ""
			local saved_ip = MP.LAN._join_ip or ""
			G.FUNCS.exit_overlay_menu()
			G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
			MP.LAN._join_code = saved_code
			MP.LAN._join_ip = saved_ip
		end
	end)
end

function G.FUNCS.lan_copy_ip(e)
	local ip = MP.LAN.get_local_ip() or MP.LAN._manual_ip or ""
	local port = MP.LAN.get_default_port()
	if MP.UTILS and MP.UTILS.copy_to_clipboard then
		MP.UTILS.copy_to_clipboard(ip .. ":" .. port)
	end
	MP.UI.UTILS.overlay_message("Copied " .. ip .. ":" .. port)
end

function G.FUNCS.lan_create_lobby(e)
	local port = MP.LAN.get_default_port()
	local ip = MP.LAN.get_local_ip()
	local hint = MP.LAN.get_hotspot_hint()
	local host_self_ip = "127.0.0.1"

	sendDebugMessage("LAN host IP for guests: " .. (ip or hint) .. ":" .. port, "MULTIPLAYER")

	MP.LAN.start_host_advertise()
	MP.LAN._host_ip = ip or hint
	local srv_ok, srv_err = MP.SERVER.start(port)
	if not srv_ok then
		sendWarnMessage("LAN server: " .. tostring(srv_err) .. " — offline lobby fallback", "MULTIPLAYER")
	end
	MP.LAN._creating = true
	MP.LAN._suppress_error = true
	MP.LAN.connect_to_host(host_self_ip, port)
	G.FUNCS.exit_overlay_menu()

	G.E_MANAGER:add_event(Event({
		trigger = "after", delay = 2.0, blockable = false, blocking = false,
		func = function()
			MP.LAN._creating = nil
			MP.LAN._suppress_error = nil
			if not MP.LOBBY.connected then
				sendDebugMessage("LAN: no local server, creating offline lobby", "MULTIPLAYER")
			end
			G.FUNCS.create_lobby(e)
			return true
		end
	}))
end

function G.FUNCS.lan_create_manual(e)
	local ip = (MP.LAN._manual_ip or ""):match("^%s*(.-)%s*$")
	if ip == "" then ip = MP.LAN.get_hotspot_hint() end
	if not ip:match("^%d+%.%d+%.%d+%.%d+$") then
		MP.UI.UTILS.overlay_message("Invalid IP: " .. ip .. " (e.g. 192.168.43.1)")
		return
	end
	local port = MP.LAN.get_default_port()
	MP.LAN.start_host_advertise()
	MP.LAN._host_ip = ip
	local srv_ok, srv_err = MP.SERVER.start(port)
	if not srv_ok then
		sendWarnMessage("LAN server: " .. tostring(srv_err) .. " — offline lobby fallback", "MULTIPLAYER")
	end
	MP.LAN._creating = true
	MP.LAN._suppress_error = true
	MP.LAN.connect_to_host("127.0.0.1", port)
	G.FUNCS.exit_overlay_menu()
	G.E_MANAGER:add_event(Event({
		trigger = "after", delay = 2.0, blockable = false, blocking = false,
		func = function()
			MP.LAN._creating = nil
			MP.LAN._suppress_error = nil
			if not MP.LOBBY.connected then
				sendDebugMessage("LAN manual: no local server, creating offline lobby", "MULTIPLAYER")
			end
			G.FUNCS.create_lobby(e)
			return true
		end
	}))
end

-- Join by room code (primary path — phone keyboard compatible)
function G.FUNCS.lan_join_code(e)
	local code = (MP.LAN._join_code or ""):upper():match("^%s*(.-)%s*$")
	if code == "" then
		MP.UI.UTILS.overlay_message("Enter a room code")
		return
	end
	-- Try to find the host IP from discovered list
	local target_ip, target_port
	for _, d in ipairs(MP.LAN.get_discovered()) do
		if d.code and d.code == code then
			target_ip = d.ip
			target_port = d.port
			break
		end
	end
	MP.LAN.set_discover_callback(nil)
	if target_ip then
		-- Found in discovery — connect directly
		MP.LAN.connect_to_host(target_ip, target_port)
		G.FUNCS.exit_overlay_menu()
		G.E_MANAGER:add_event(Event({
			trigger = "after", delay = 1.0, blockable = false, blocking = false,
			func = function()
				if MP.LOBBY.connected then
					MP.ACTIONS.join_lobby(code)
				end
				return true
			end,
		}))
	else
		-- Code not found in discovery — try to join via connected server
		if MP.LOBBY.connected then
			MP.ACTIONS.join_lobby(code)
			G.FUNCS.exit_overlay_menu()
		else
			MP.UI.UTILS.overlay_message("Room '" .. code .. "' not found. Make sure host created it.")
		end
	end
end

-- Join by IP (secondary — needs physical keyboard for dots)
function G.FUNCS.lan_join_ip(e)
	local ip = (MP.LAN._join_ip or ""):match("^%s*(.-)%s*$")
	if ip == "" then
		MP.UI.UTILS.overlay_message("Enter host IP")
		return
	end
	if not ip:match("^%d+%.%d+%.%d+%.%d+$") and ip ~= "localhost" then
		MP.UI.UTILS.overlay_message("Invalid IP: " .. ip)
		return
	end
	local port = MP.LAN.get_default_port()
	MP.LAN.set_discover_callback(nil)
	MP.LAN.connect_to_host(ip, port)
	G.FUNCS.exit_overlay_menu()
	-- Wait for connection then try to discover the room code
	G.E_MANAGER:add_event(Event({
		trigger = "after", delay = 1.5, blockable = false, blocking = false,
		func = function()
			if MP.LOBBY.code then return true end
			if MP.LOBBY.connected then
				-- Try auto-join from discovered list
				for _, d in ipairs(MP.LAN.get_discovered()) do
					if d.ip == ip and d.code and d.code ~= "" then
						MP.ACTIONS.join_lobby(d.code)
						return true
					end
				end
				MP.UI.UTILS.overlay_message("Connected to " .. ip .. " — enter room code")
			else
				MP.UI.UTILS.overlay_message("Cannot reach " .. ip .. ":" .. port)
			end
			return true
		end,
	}))
end

function G.FUNCS.lan_refresh(e)
	-- Don't restart discovery — just rebuild UI with current list
	if G.OVERLAY_MENU then
		G.FUNCS.exit_overlay_menu()
		G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
	end
end

function G.FUNCS.lan_use_online(e)
	if MP.SERVER and MP.SERVER.is_running() then MP.SERVER.stop() end
	MP.LAN.restore_online_server()
	MP.LAN.set_discover_callback(nil)
	MP.LAN.connect_to_host("balatro.virtualized.dev", MP.LAN.get_default_port())
	G.FUNCS.exit_overlay_menu()
	MP.UI.UTILS.overlay_message("Switched to online server")
end
