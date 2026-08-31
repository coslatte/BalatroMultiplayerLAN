# PLAN DE ORO — Balatro Multiplayer LAN

> **Plan inicial concretado:** Servidor TCP embebido con paridad total al Online + hardening del thread de networking + descubrimiento LAN por UDP + UI LAN con toggle Online/LAN.
> Este documento exporta el plan que efectivamente se implementó y finalizó. Todo lo descripto está en `dev` (sin commit) y empaquetado en `dist/MultiplayerLAN-v0.1.zip`.

## 1) Objetivo del plan

Permitir partidas LAN sin depender de `balatro.virtualized.dev`, con paridad de gameplay total (mismas reglas, vidas, PvP, timers, reconexión) y sin que dos threads compitan por el canal `uiToNetwork`.

## 2) Stack relevante

- LÖVE2D + Lovely + SMODS (Balatro >=1.0.1o)
- `love.socket` (luasocket) + `love.thread` + `love.thread.Channel`
- Servidor upstream: `BalatroMultiplayerAPI-Server` (WebSocket/TCP)

## 3) Tareas propuestas vs. concretadas

| # | Tarea propuesta | Estado | Artefactos |
|---|---|---|---|
| 1 | **Servidor TCP embebido** en main thread, no bloqueante, newline-delimited JSON, `connected`+`version` al accept, keepAlive 15s / retry 5s×4, grace de reconexión 60s | ✅ Concretada | `networking/server/lobby.lua` (501 L), `networking/server/handlers.lua` (694 L), `networking/server/init.lua` (293 L) |
| 2 | **Hardening del thread de networking** — sentinel generacional para reemplazo de thread sin perder mensajes | ✅ Concretada | `networking/socket.lua` (THREAD_GEN/MY_GEN, QUIT_PREFIX, `quit_sentinel_for_me`, `tryReconnect` peek), `networking/lan.lua` `restart_networking` |
| 3 | **Host advertise / guest discovery** UDP broadcast puerto 8789, multi-target (255.255.255.255 + 192.168.43.255 + 192.168.137.255 …), probe/advertise | ✅ Concretada | `networking/lan.lua` `start_host_advertise/start_discovery/tick/build_advertise_payload` |
| 4 | **UI LAN phone-friendly** — Host muestra IP:port, Copy, Manual IP; Join muestra discovered + manual + Refresh | ✅ Concretada | `ui/lobby/lan_browser.lua` (449 L) |
| 5 | **Auto-join por room code** tras conectar (delay 1.0s, vía discovery o prompt) | ✅ Concretada | `lan_browser.lua` `lan_join_discovered_N`, `lan_join_manual` (ramas code vs IP) |
| 6 | **Config** — `lan_bind_ip`, `lan_broadcast_port`, `lan_ui_mode` | ✅ Concretada | `config.lua` |
| 7 | **Wiring host/guest + fallback offline + ciclo de vida del servidor** (start/stop/request_stop/on_lobby_destroyed, `Game:update` tick) | ✅ Concretada | `core.lua` (carga server/* + `_thread_gen=1`), `networking/server/init.lua` tick, `lan_browser.lua` `lan_create_lobby/manual/use_online` |
| 8 | **Toggle Online / LAN en menú Play** (no mostrar todo directo) | ✅ Concretada (última iteración) | `ui/main_menu/play_button/play_button.lua` toggle + `MP.LAN.get/set_ui_mode` |
| 9 | **Tests** — lifecycle del servidor + sentinel | ✅ Concretada | `tests/test_server_lifecycle.lua` 47 asserts |
| 10 | **Build de prueba** `MultiplayerLAN-v0.1.zip` | ✅ Concretada | `dist/MultiplayerLAN-v0.1.zip` (3.6 MB) |

## 4) Detalle de implementación concretada

### 4.1 Servidor (`networking/server/`)
- `lobby.lua`: `MP.SERVER.Lobbies`, `ClientState` (id, reconnect_token, lives/score/score_raw, blockers, location), `Lobby.new/get/join/leave/disconnect/expire_disconnected_slot/rejoin`, `get_enemy`, `generate_seed`.
- `handlers.lua`: port fiel de `actionHandlers.ts` — `username/version/syncClient/keepAlive`, `createLobby/joinLobby/rejoinLobby/lobbyInfo/leaveLobby/readyLobby`, `startGame/readyBlind`, `playHand` (hide_score_until_played, pvpTimerOrder, endPvP/winGame), `failPvPTimer/failTimer/failRound`, relays (`sendPhantom`, `magnet`, etc.), `moddedAction`, `handyMP`.
- `init.lua`: `make_entry/close_fn/send_fn`, `handle_message`, `start(port,bind_ip)` con `socket.bind` + `settimeout(0)`, `do_stop/stop/request_stop/is_running/on_lobby_destroyed`, `tick()` (accept/drain/keepAlive/grace/deferred stop/sweep), `install_tick` encadenado a `Game:update` (corre en todo stage, no solo MAIN_MENU).

### 4.2 Thread hardening (`socket.lua` + `lan.lua`)
- `socket.lua` chunk recibe `THREAD_GEN`, `MY_GEN=tonumber(THREAD_GEN)or 1`, `QUIT_PREFIX="__MP_THREAD_QUIT__"`, `quit_sentinel_for_me(msg)` → `gen==nil or gen>MY_GEN`.
- `mainThreadMessageQueue` chequea sentinel antes de `{"action":"connect"}` → cierra socket, `hasGivenUp=true`, `push("ok")` a `mpThreadQuitAck`, `return` (muere coroutine).
- `tryReconnect` hace `peek()` antes de cada `sleep` → aborta si hay reemplazo.
- `lan.lua` `BROADCAST_PORT` leído de `SMODS.Mods["Multiplayer"].config.lan_broadcast_port` (fallback 8789). `restart_networking` incrementa `_thread_gen`, limpia `mpThreadQuitAck`, `push("__MP_THREAD_QUIT__"..gen)` a `uiToNetwork`, `demand(0.5)` best-effort, `newThread(SOCKET):start(url,port,gen)` + `MP.ACTIONS.connect()`.
- `core.lua` inicia con `_thread_gen=1` y `start(url,port,gen)`.

### 4.3 Discovery (`lan.lua`)
- `get_local_ip_candidates()` prueba `8.8.8.8/1.1.1.1/192.168.43.1…` + `dns.gethostname/toip`.
- `start_host_advertise` (advertiser broadcast + host_listener en BROADCAST_PORT), `start_discovery` (listener + probe inmediato), `tick(dt)` (host broadcast cada 1.0s + responde probes; join probe cada 1.5s + drain datagrams, fallback regex si json falla).
- `connect_to_host/restore_online_server`, `create_offline_lobby/join_offline_lobby/leave_offline_lobby`, `wrap_lan_actions` (create/join/leave).

### 4.4 UI (`lan_browser.lua` + `play_button.lua`)
- `lan_browser.lua`: `create_UIBox_lan_host/join`, `lan_host_menu/join_menu/copy_ip/create_lobby/create_manual/join_manual/refresh/use_online`. Host levanta `MP.SERVER.start(port)` antes de `connect_to_host(127.0.0.1)`. Guest auto-join 1.0s por `entry.code`. `lan_join_manual` maneja `^[A-Za-z]{1,6}$` → resuelve `target_ip` vía `get_discovered()`, y rama IP → `connected? (discovered code ? join : prompt) : offline`.
- `play_button.lua`: `G.FUNCS.toggle_lan_mode` flippea `lan_ui_mode` y refresca overlay con `G.UIDEF.override_main_menu_play_button()`. Render condicional: `is_lan ? Host/Join LAN : Create/Join online`.

### 4.5 Config (`config.lua`)
```lua
["lan_broadcast_port"] = 8789,
["lan_default_port"] = 8788,
["lan_bind_ip"] = "",
["lan_ui_mode"] = "online",
```

## 5) Validación

- `luac -p` 9/9: `config, core, lan, socket, lobby, handlers, init, browser, play_button` → 0
- `lua tests/test_server_lifecycle.lua` → 47 passed, 0 failed (requiere `package.preload` para `json/socket` + stubs `Game/G`)
- `test_serialization_guard / rlog_*` → OK

## 6) Build de prueba

- `dist/MultiplayerLAN-v0.1.zip` (3614092 bytes, 440 archivos, `Multiplayer.json` at zip root, version `0.1`, incluye working tree con cambios sin commitear).
- `dist/MultiplayerLAN-v0.1/` carpeta stage.
- Instalación: extraer zip a `%APPDATA%\Balatro\Mods\Multiplayer` (resulta `Mods/Multiplayer/Multiplayer.json`), requiere Lovely >=0.9 + SMODS >=1.0.0~BETA-1620a.

## 7) Commit recomendado (pendiente)

```
git add config.lua core.lua networking/lan.lua networking/socket.lua ui/lobby/lan_browser.lua ui/main_menu/play_button/play_button.lua networking/server/lobby.lua networking/server/handlers.lua networking/server/init.lua tests/test_server_lifecycle.lua PLAN_ORO_LAN.md
git commit -m "LAN: embedded TCP relay + thread generation sentinel + UI auto-join + Online/LAN toggle"
```

---
*Exportado: 2026-08-31 — rama `dev`, working tree sin commit, Lua 5.4.6 en PATH.*
