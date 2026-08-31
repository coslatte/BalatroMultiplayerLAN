function G.FUNCS.toggle_lan_mode(e)
	local cur = MP.LAN.get_ui_mode()
	local nxt = cur == "lan" and "online" or "lan"
	MP.LAN.set_ui_mode(nxt)
	-- Limpiar estado de red al cambiar de dominio para no mezclar Online<->LAN
	if nxt == "online" then
		-- Salir de modo LAN: dejar lobby offline primero (si está en uno) para limpiar estado
		if MP.LAN._offline and MP.LOBBY.code then
			pcall(function() MP.LAN.leave_offline_lobby() end)
		end
		-- Luego detener advertise/discovery y restaurar online si estaba en IP LAN
		pcall(function() MP.LAN.stop() end)
		if MP.SERVER and MP.SERVER.is_running() then MP.SERVER.stop() end
		-- Si el server_url es una IP LAN, volver al online por defecto
		local cfg = SMODS and SMODS.Mods and SMODS.Mods["Multiplayer"] and SMODS.Mods["Multiplayer"].config
		if cfg and cfg.server_url and cfg.server_url:match("^%d+%.%d+%.%d+%.%d+$") then
			MP.LAN.restore_online_server()
			MP.LAN.connect_to_host("balatro.virtualized.dev", 8788)
		end
		-- Iniciar hilo de red para modo Online
		if not MP.NETWORKING_THREAD then
			MP.start_networking_thread()
		end
	else
		-- Entrar a LAN: asegurar discovery detenido hasta que el usuario elija Host/Join
		pcall(function() MP.LAN.stop() end)
		if MP.SERVER and MP.SERVER.is_running() then MP.SERVER.stop() end
		-- Detener hilo de red si existe (modo LAN no lo usa)
		if MP.NETWORKING_THREAD then
			pcall(function()
				local quit_ack = love.thread.getChannel("mpThreadQuitAck")
				while quit_ack:pop() ~= nil do end
				love.thread.getChannel("uiToNetwork"):push("__MP_THREAD_QUIT__" .. tostring(MP.LAN._thread_gen or 1))
				quit_ack:demand(0.5)
			end)
			MP.NETWORKING_THREAD = nil
		end
	end
	if G.STAGE == G.STAGES.MAIN_MENU then
		if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
		G.FUNCS.overlay_menu({ definition = G.UIDEF.override_main_menu_play_button() })
	end
end

function G.UIDEF.override_main_menu_play_button()
	if not G.SETTINGS.tutorial_complete or G.SETTINGS.tutorial_progress ~= nil then
		return (
			create_UIBox_generic_options({
				contents = {
					UIBox_button({
						label = { localize("b_singleplayer") },
						colour = G.C.BLUE,
						button = "setup_run_singleplayer",
						minw = 5,
					}),
					{
						n = G.UIT.R,
						config = {
							align = "cm",
							padding = 0.5,
						},
						nodes = {
							{
								n = G.UIT.T,
								config = {
									text = localize("k_tutorial_not_complete"),
									colour = G.C.UI.TEXT_LIGHT,
									scale = 0.45,
								},
							},
						},
					},
					UIBox_button({
						label = { localize("b_skip_tutorial") },
						colour = G.C.RED,
						button = "skip_tutorial",
						minw = 5,
					}),
				},
			})
		)
	end

	local is_lan = MP.LAN.get_ui_mode() == "lan"
	return (
		create_UIBox_generic_options({
			contents = {
				UIBox_button({
					label = { localize("b_singleplayer") },
					colour = G.C.BLUE,
					button = "start_vanilla_sp",
					minw = 5,
				}),
				UIBox_button({
					label = { localize("b_sp_with_ruleset") },
					colour = G.C.ORANGE,
					button = "setup_practice_mode",
					minw = 5,
				}),
				-- Toggle row: Online <-> LAN
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.12 },
					nodes = {
						UIBox_button({
							label = { is_lan and "Mode: LAN  >" or "<  Mode: Online" },
							colour = is_lan and G.C.GREEN or G.C.BLUE,
							button = "toggle_lan_mode",
							minw = 4.5, minh = 0.6, scale = 0.38,
						}),
					}
				},
				-- LAN group
				is_lan and UIBox_button({
					label = { "Host LAN" },
					colour = G.C.GREEN,
					button = "lan_host_menu",
					minw = 5,
				}) or nil,
				is_lan and UIBox_button({
					label = { "Join LAN" },
					colour = G.C.ORANGE,
					button = "lan_join_menu",
					minw = 5,
				}) or nil,
				-- Online group
				not is_lan and MP.LOBBY.connected and UIBox_button({
					label = { localize("b_create_lobby") },
					colour = G.C.GREEN,
					button = "create_lobby",
					minw = 5,
				}) or nil,
				not is_lan and MP.LOBBY.connected and UIBox_button({
					label = { localize("b_join_lobby") },
					colour = G.C.RED,
					button = "join_lobby",
					minw = 5,
					minh = 0.7,
				}) or nil,
				not is_lan and MP.LOBBY.connected and UIBox_button({
					label = { localize("b_join_lobby_clipboard") },
					colour = G.C.PURPLE,
					button = "join_from_clipboard",
					minw = 5,
					minh = 0.7,
				}) or nil,
				not is_lan and not MP.LOBBY.connected and UIBox_button({
					label = { localize("b_reconnect") },
					colour = G.C.RED,
					button = "reconnect",
					minw = 5,
				}) or nil,
				-- hint row
				{
					n = G.UIT.R, config = { align = "cm", padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = is_lan and "LAN: hotspot / same Wi-Fi (port 8789)" or "Online: balatro.virtualized.dev:8788", scale = 0.28, colour = G.C.UI.TEXT_LIGHT } }
					}
				},
			},
		})
	)
end
