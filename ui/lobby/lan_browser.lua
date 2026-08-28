-- LAN Browser UI: host advertises, guests discover
-- Mirrors balatromp-local-phone MainActivity host/client toggle + auto IP display.

local function lan_host_ip_text()
	local ip = MP.LAN and MP.LAN.get_local_ip() or nil
	if ip then return ip end
	local cands = MP.LAN and MP.LAN.get_local_ip_candidates() or {}
	if #cands > 0 then return table.concat(cands, " / ") end
	return "No auto-IP (hotspot? use 192.168.43.1)"
end

function G.UIDEF.create_UIBox_lan_host()
	local ip = lan_host_ip_text()
	local port = MP.LAN.get_default_port()
	-- ensure manual field has a sensible default
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
					{ n = G.UIT.T, config = { text = "Your LAN IP: " .. ip .. " :" .. port, scale = 0.38, colour = G.C.GREEN } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					{ n = G.UIT.T, config = { text = "Share this IP with guest on same Wi-Fi / hotspot", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.12 },
				nodes = {
					UIBox_button({ label = { "Copy IP" }, button = "lan_copy_ip", colour = G.C.BLUE, minw = 2.8, minh = 0.7, scale = 0.35 }),
					UIBox_button({ label = { "Create LAN Lobby" }, button = "lan_create_lobby", colour = G.C.GREEN, minw = 3.5, minh = 0.85, scale = 0.4 }),
				}
			},
			-- divider
			{
				n = G.UIT.R, config = { align = "cm", padding = 0.12 },
				nodes = {
					{ n = G.UIT.T, config = { text = "or enter hotspot IP manually", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
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
						keyboard_offset = 1,
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
					{ n = G.UIT.T, config = { text = "Hotspot host is usually 192.168.43.1", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
				}
			},
		}
	})
end

function G.UIDEF.create_UIBox_lan_join()
	local discovered = MP.LAN and MP.LAN.get_discovered() or {}
	local nodes = {}

	-- Manual IP input row — phone-friendly: smaller width, no overlap with back button
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.12 },
		nodes = {
			{ n = G.UIT.T, config = { text = "LAN Join — same Wi-Fi / hotspot as host", scale = 0.34, colour = G.C.UI.TEXT_LIGHT } }
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			create_text_input({
				w = 4.2, h = 0.8,
				max_length = 21,
				prompt_text = "192.168.43.1",
				ref_table = MP.LAN,
				ref_value = "_manual_ip",
				extended_corpus = true,
				keyboard_offset = 1,
				callback = function() end,
			})
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			UIBox_button({ label = { "Connect to IP" }, button = "lan_join_manual", colour = G.C.RED, minw = 3.2, minh = 0.7, scale = 0.35 }),
			UIBox_button({ label = { "Refresh" }, button = "lan_refresh", colour = G.C.BLUE, minw = 2.2, minh = 0.7, scale = 0.35 }),
		}
	})

	-- Discovered list
	if #discovered == 0 then
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.2 },
			nodes = {
				{ n = G.UIT.T, config = { text = "No LAN lobbies found. Make sure host pressed 'Start LAN'.", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.1 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Tip: host + guest must be on same Wi-Fi / hotspot.", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
	else
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.15 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Discovered (" .. #discovered .. "):", scale = 0.4, colour = G.C.GREEN } }
			}
		})
		for i, entry in ipairs(discovered) do
			if i > 6 then break end -- cap UI rows
			local label = (entry.host or "Host") .. "  " .. entry.ip .. ":" .. entry.port
			if entry.code and entry.code ~= "" then label = label .. "  [" .. entry.code .. "]" end
			-- store selection index on click via closure-friendly button func
			G.FUNCS["lan_join_discovered_" .. i] = function()
				MP.LAN._manual_ip = entry.ip
				MP.LAN.connect_to_host(entry.ip, entry.port)
				G.FUNCS.exit_overlay_menu()
				MP.UI.UTILS.overlay_message("Connecting to " .. entry.ip .. ":" .. entry.port)
			end
			table.insert(nodes, {
				n = G.UIT.R, config = { align = "cm", padding = 0.08 },
				nodes = {
					UIBox_button({ label = { label }, button = "lan_join_discovered_" .. i, colour = G.C.ORANGE, minw = 6, minh = 0.7, scale = 0.35 }),
				}
			})
		end
	end

	-- Help row
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
	-- don't auto-switch server yet; just show IP
	G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_host() })
end

function G.FUNCS.lan_join_menu(e)
	MP.LAN._manual_ip = MP.LAN._manual_ip or ""
	MP.LAN.start_discovery()
	G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
	-- live auto-refresh: when discovery finds/updates a room, rebuild the Join UI if still open
	MP.LAN.set_discover_callback(function()
		if G.OVERLAY_MENU then
			-- avoid flicker spam: debounce 0.6s
			if MP.LAN._refresh_debounce and love.timer.getTime() - MP.LAN._refresh_debounce < 0.6 then return end
			MP.LAN._refresh_debounce = love.timer.getTime()
			G.FUNCS.exit_overlay_menu()
			G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
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
	local candidates = MP.LAN.get_local_ip_candidates()
	local hint = MP.LAN.get_hotspot_hint()

	local host_self_ip = "127.0.0.1"
	-- Single non-blocking hint (not a blocking overlay)
	if not ip then
		sendDebugMessage("LAN: no auto-IP, host will use " .. host_self_ip .. ":" .. port .. "; guests use " .. hint .. ":" .. port, "MULTIPLAYER")
	else
		sendDebugMessage("LAN host IP for guests: " .. ip .. ":" .. port, "MULTIPLAYER")
	end

	MP.LAN.start_host_advertise()
	MP.LAN._host_ip = ip or hint
	MP.LAN._creating = true
	MP.LAN._suppress_error = true
	MP.LAN.connect_to_host(host_self_ip, port)
	G.FUNCS.exit_overlay_menu()

	-- Wait max 2s for local server; then create offline lobby anyway (no overlay, no block)
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

function G.FUNCS.lan_host_manual_ip(e)
	-- Alternate button: let host type its hotspot IP manually if auto failed
	MP.LAN._manual_ip = MP.LAN._manual_ip or MP.LAN.get_hotspot_hint()
	G.FUNCS.overlay_menu({
		definition = create_UIBox_generic_options({
			back_func = "lan_host_menu",
			contents = {
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.2 },
					nodes = {
						{ n = G.UIT.T, config = { text = "Enter your hotspot IP manually", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } }
					}
				},
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.1 },
					nodes = {
						create_text_input({
							w = 5, h = 0.9, max_length = 32,
							prompt_text = "e.g. 192.168.43.1",
							ref_table = MP.LAN, ref_value = "_manual_ip",
							extended_corpus = true, keyboard_offset = 4,
							callback = function() end,
						})
					}
				},
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.2 },
					nodes = {
						UIBox_button({ label = { "Use this IP & Create" }, button = "lan_create_manual", colour = G.C.GREEN, minw = 4, minh = 1, scale = 0.45 }),
					}
				},
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = "Hotspot host is usually 192.168.43.1 — check Settings > Hotspot", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
					}
				},
			}
		})
	})
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

function G.FUNCS.lan_join_manual(e)
	local ip = MP.LAN._manual_ip or ""
	ip = ip:match("^%s*(.-)%s*$")
	if ip == "" then
		MP.UI.UTILS.overlay_message("Enter host IP first")
		return
	end
	-- allow code+ip combo? if user pasted code, try join by code
	if ip:match("^[A-Za-z]+$") and #ip <= 6 then
		MP.LAN.set_discover_callback(nil)
		MP.ACTIONS.join_lobby(ip:upper())
		G.FUNCS.exit_overlay_menu()
		return
	end
	if not ip:match("^%d+%.%d+%.%d+%.%d+$") and ip ~= "localhost" and not ip:match("%.") then
		MP.UI.UTILS.overlay_message("Invalid IP: " .. ip)
		return
	end
	local port = MP.LAN.get_default_port()
	MP.LAN.set_discover_callback(nil)
	MP.LAN._manual_ip = ip
	-- try real server first; if offline, fallback will create local lobby
	MP.LAN.connect_to_host(ip, port)
	G.FUNCS.exit_overlay_menu()
	-- wait a moment then try offline join if not connected
	G.E_MANAGER:add_event(Event({ trigger = "after", delay = 1.0, blockable = false, blocking = false, func = function()
		if not MP.LOBBY.code then
			-- try offline join via discovered code or ip
			MP.LAN.join_offline_lobby(nil, ip, port)
			MP.UI.UTILS.overlay_message("Joined LAN lobby offline: " .. (MP.LOBBY.code or ""))
		else
			MP.UI.UTILS.overlay_message("Connecting to " .. ip .. ":" .. port)
		end
		return true
	end }))
end

function G.FUNCS.lan_refresh(e)
	MP.LAN.set_discover_callback(nil)
	G.FUNCS.exit_overlay_menu()
	G.FUNCS.lan_join_menu(e)
end

function G.FUNCS.lan_use_online(e)
	MP.LAN.restore_online_server()
	MP.LAN.set_discover_callback(nil)
	MP.LAN.connect_to_host("balatro.virtualized.dev", MP.LAN.get_default_port())
	G.FUNCS.exit_overlay_menu()
	MP.UI.UTILS.overlay_message("Switched to online server")
end

-- keep legacy second-overlay func for compat (no longer used, but prevent nil)
function G.FUNCS.lan_host_manual_ip(e)
	-- now inline in main host screen, just reopen host menu
	G.FUNCS.lan_host_menu(e)
	MP.UI.UTILS.overlay_message("Escribe el IP arriba y dale Use Manual IP & Create")
end

-- Ensure LAN stops advertising when lobby is left or game ends
local _orig_lobby_leave = G.FUNCS.lobby_leave
-- patched lazily after load; see core integration
