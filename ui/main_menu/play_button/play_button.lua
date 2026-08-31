function G.FUNCS.toggle_lan_mode(e)
	local cur = MP.LAN.get_ui_mode()
	local nxt = cur == "lan" and "online" or "lan"
	MP.LAN.set_ui_mode(nxt)
	if G.STAGE == G.STAGES.MAIN_MENU then
		-- refresh the Play menu in place
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
					minh = 0.7,
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
