-- LAN Browser UI: host advertises, guests discover
-- Objetivo plan ORO: toggle Online/LAN, Host muestra IP local, Join lista salas LAN con IP+código

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
	local cands = MP.LAN.get_local_ip_candidates()
	MP.LAN._manual_ip = MP.LAN._manual_ip or ""
	if MP.LAN._manual_ip == "" then
		local auto = MP.LAN.get_local_ip()
		MP.LAN._manual_ip = auto or MP.LAN.get_hotspot_hint()
	end
	local nodes = {
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
			n = G.UIT.R, config = { align = "cm", padding = 0.06 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Share this IP with guests on the same network", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
			}
		},
	}
	-- Si hay múltiples interfaces, mostrarlas para contraste (universal PC/mobile)
	if #cands > 1 then
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.04 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Interfaces: " .. table.concat(cands, " • "), scale = 0.26, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
	end
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.12 },
		nodes = {
			UIBox_button({ label = { "Copy IP" }, button = "lan_copy_ip", colour = G.C.BLUE, minw = 2.8, minh = 0.7, scale = 0.35 }),
			UIBox_button({ label = { "Create Lobby" }, button = "lan_create_lobby", colour = G.C.GREEN, minw = 3.5, minh = 0.85, scale = 0.4 }),
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.12 },
		nodes = {
			{ n = G.UIT.T, config = { text = "or enter IP manually (bind / hotspot)", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
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
				keyboard_offset = 5,
				callback = function() end,
			})
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			UIBox_button({ label = { "Use Manual IP & Create" }, button = "lan_create_manual", colour = G.C.ORANGE, minw = 4, minh = 0.7, scale = 0.35 }),
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			{ n = G.UIT.T, config = { text = "Hotspot: 192.168.43.1  •  Windows hotspot: 192.168.137.1", scale = 0.24, colour = G.C.UI.TEXT_LIGHT } }
		}
	})

	return create_UIBox_generic_options({
		back_func = "play_options",
		contents = { { n = G.UIT.C, config = { align = "cm", padding = 0.1 }, nodes = nodes } }
	})
end

function G.UIDEF.create_UIBox_lan_join()
	local discovered = MP.LAN and MP.LAN.get_discovered() or {}
	local nodes = {}

	-- Title - claro que es LAN, no internet
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.15 },
		nodes = {
			{ n = G.UIT.T, config = { text = "LAN Join", scale = 0.5, colour = G.C.UI.TEXT_LIGHT } }
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.05 },
		nodes = {
			{ n = G.UIT.T, config = { text = "Local network only — same Wi-Fi / hotspot as host", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
		}
	})

	-- Discovered rooms (LAN only, via UDP 8789)
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
				MP.LAN.set_discover_callback(nil)
				MP.LAN.connect_to_host(entry.ip, entry.port)
				G.FUNCS.exit_overlay_menu()
				G.E_MANAGER:add_event(Event({
					trigger = "after", delay = 1.0, blockable = false, blocking = false,
					func = function()
						if MP.LOBBY.connected and entry.code and entry.code ~= "" then
							MP.ACTIONS.join_lobby(entry.code)
						end
						return true
					end,
				}))
			end
			table.insert(nodes, {
				n = G.UIT.R, config = { align = "cm", padding = 0.06 },
				nodes = {
					UIBox_button({ label = { label }, button = "lan_join_discovered_" .. i, colour = G.C.ORANGE, minw = 6.2, minh = 0.65, scale = 0.32 }),
				}
			})
		end
	else
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.2 },
			nodes = {
				{ n = G.UIT.T, config = { text = "No LAN rooms found.", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
		table.insert(nodes, {
			n = G.UIT.R, config = { align = "cm", padding = 0.08 },
			nodes = {
				{ n = G.UIT.T, config = { text = "Host must press Create Lobby first (same Wi-Fi / hotspot).", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
			}
		})
	end

	-- Unified input: código de sala o IP fijo del host (preferir código)
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.14 },
		nodes = {
			{ n = G.UIT.T, config = { text = "Or enter code / host IP manually", scale = 0.3, colour = G.C.UI.TEXT_LIGHT } }
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			create_text_input({
				w = 5.2, h = 0.8,
				max_length = 21,
				prompt_text = "Codigo de sala o IP del host",
				ref_table = MP.LAN,
				ref_value = "_join_input",
				extended_corpus = true,
				all_caps = true,
				keyboard_offset = 5,
				callback = function()
					local v = (MP.LAN._join_input or ""):match("^%s*(.-)%s*$")
					if v ~= "" then G.FUNCS.lan_join_unified() end
				end,
			})
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.08 },
		nodes = {
			UIBox_button({ label = { "Join" }, button = "lan_join_unified", colour = G.C.RED, minw = 2.5, minh = 0.7, scale = 0.35 }),
			UIBox_button({ label = { "Refresh" }, button = "lan_refresh", colour = G.C.BLUE, minw = 2.5, minh = 0.7, scale = 0.35 }),
		}
	})
	table.insert(nodes, {
		n = G.UIT.R, config = { align = "cm", padding = 0.06 },
		nodes = {
			{ n = G.UIT.T, config = { text = "Code: 5 letters (e.g. ABCDE)  •  IP: 192.168.43.1", scale = 0.24, colour = G.C.UI.TEXT_LIGHT } }
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
	MP.LAN._join_input = ""
	if not MP.LAN._listener then
		MP.LAN.start_discovery()
	end
	G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
	MP.LAN.set_discover_callback(function()
		if G.OVERLAY_MENU then
			if MP.LAN._refresh_debounce and love.timer.getTime() - MP.LAN._refresh_debounce < 0.8 then return end
			MP.LAN._refresh_debounce = love.timer.getTime()
			local saved = MP.LAN._join_input or ""
			G.FUNCS.exit_overlay_menu()
			G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
			MP.LAN._join_input = saved
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
	sendDebugMessage("LAN host IP for guests: " .. (ip or hint) .. ":" .. port, "MULTIPLAYER")
	MP.LAN.start_host_advertise()
	MP.LAN._host_ip = ip or hint
	local srv_ok, srv_err = MP.SERVER.start(port)
	if not srv_ok then
		sendWarnMessage("LAN server: " .. tostring(srv_err) .. " — offline fallback", "MULTIPLAYER")
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
			if not MP.LOBBY.connected then sendDebugMessage("LAN: offline lobby fallback", "MULTIPLAYER") end
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
		sendWarnMessage("LAN server: " .. tostring(srv_err) .. " — offline fallback", "MULTIPLAYER")
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
			if not MP.LOBBY.connected then sendDebugMessage("LAN manual: offline fallback", "MULTIPLAYER") end
			G.FUNCS.create_lobby(e)
			return true
		end
	}))
end

-- Unified join: código de sala o IP fijo del host (preferir código)
function G.FUNCS.lan_join_unified(e)
	local raw = (MP.LAN._join_input or ""):match("^%s*(.-)%s*$")
	if raw == "" then
		MP.UI.UTILS.overlay_message("Enter room code or host IP")
		return
	end
	-- Normalizar: si tiene puntos -> IP, si solo letras -> código
	local is_ip = raw:match("^%d+%.%d+%.%d+%.%d+$") or raw == "localhost"
	local is_code = raw:match("^[A-Za-z]+$") and #raw <= 6

	-- Heurística: contiene punto -> IP, solo letras -> código, preferir código antes que IP
	if not is_ip and not is_code then
		-- mezcla? extraer posible IP o código
		if raw:match("%.") then is_ip = true
		elseif raw:match("^[A-Za-z0-9]+$") and #raw <= 6 then is_code = true; is_ip = false
		else
			MP.UI.UTILS.overlay_message("Invalid code/IP: " .. raw)
			return
		end
	end

	if is_code and not is_ip then
		local code = raw:upper()
		local target_ip, target_port
		for _, d in ipairs(MP.LAN.get_discovered()) do
			if d.code and d.code == code then target_ip = d.ip; target_port = d.port; break end
		end
		MP.LAN.set_discover_callback(nil)
		if target_ip then
			MP.LAN.connect_to_host(target_ip, target_port)
			G.FUNCS.exit_overlay_menu()
			G.E_MANAGER:add_event(Event({
				trigger = "after", delay = 1.0, blockable = false, blocking = false,
				func = function()
					if MP.LOBBY.connected then MP.ACTIONS.join_lobby(code) end
					return true
				end,
			}))
		else
			if MP.LOBBY.connected then
				MP.ACTIONS.join_lobby(code)
				G.FUNCS.exit_overlay_menu()
			else
				MP.UI.UTILS.overlay_message("Room '" .. code .. "' not found. Check host IP or create first.")
			end
		end
		return
	end

	-- IP path
	local ip = raw
	if not is_ip then
		MP.UI.UTILS.overlay_message("Invalid IP: " .. ip)
		return
	end
	local port = MP.LAN.get_default_port()
	MP.LAN.set_discover_callback(nil)
	MP.LAN.connect_to_host(ip, port)
	G.FUNCS.exit_overlay_menu()
	G.E_MANAGER:add_event(Event({
		trigger = "after", delay = 1.5, blockable = false, blocking = false,
		func = function()
			if MP.LOBBY.code then return true end
			if MP.LOBBY.connected then
				for _, d in ipairs(MP.LAN.get_discovered()) do
					if d.ip == ip and d.code and d.code ~= "" then MP.ACTIONS.join_lobby(d.code); return true end
				end
				MP.UI.UTILS.overlay_message("Connected to " .. ip .. " — enter room code")
			else
				MP.UI.UTILS.overlay_message("Cannot reach " .. ip .. ":" .. port)
			end
			return true
		end,
	}))
end

-- Legacy aliases for backwards compat (old buttons may still reference them)
G.FUNCS.lan_join_code = G.FUNCS.lan_join_unified
G.FUNCS.lan_join_ip = G.FUNCS.lan_join_unified
G.FUNCS.lan_join_manual = G.FUNCS.lan_join_unified

function G.FUNCS.lan_refresh(e)
	if G.OVERLAY_MENU then
		G.FUNCS.exit_overlay_menu()
		G.FUNCS.overlay_menu({ definition = G.UIDEF.create_UIBox_lan_join() })
	end
end

function G.FUNCS.lan_use_online(e)
	-- Leave offline LAN lobby first (if in one) to clean up state before switching
	if MP.LAN._offline and MP.LOBBY.code then
		pcall(function() MP.LAN.leave_offline_lobby() end)
	end
	if MP.SERVER and MP.SERVER.is_running() then MP.SERVER.stop() end
	MP.LAN.restore_online_server()
	MP.LAN.set_discover_callback(nil)
	MP.LAN.connect_to_host("balatro.virtualized.dev", MP.LAN.get_default_port())
	G.FUNCS.exit_overlay_menu()
	MP.UI.UTILS.overlay_message("Switched to online server")
end
