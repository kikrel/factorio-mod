-- Минимальный мод "Олег" для Factorio с JSON-протоколом через UDP
-- Использует helpers.send_udp / helpers.recv_udp и событие defines.events.on_udp_packet_received
-- Включите UDP при запуске Factorio: --enable-lua-udp=38766

local BRIDGE_PORT = 38767
local FACTORIO_RECV_PORT = 38766

local json = require("json") -- локальная json.lua библиотека в корне мода

local function safe_print(player_index, text)
  if player_index and game.get_player(player_index) then
    game.get_player(player_index).print(text)
  else
    game.print(text)
  end
end

local function send_to_bridge(player_index, message_text)
  local payload = {
    type = "request",
    player_index = player_index,
    text = message_text,
    lang = "ru",
  }
  local ok, encoded = pcall(function() return json.encode(payload) end)
  if not ok then
    safe_print(player_index, "Олег-мод: ошибка кодирования JSON: " .. tostring(encoded))
    return
  end
  -- helpers.send_udp(port, data, for_player?)
  local status, err = pcall(function() helpers.send_udp(BRIDGE_PORT, encoded, player_index) end)
  if not status then
    safe_print(player_index, "Олег-мод: ошибка при отправке в bridge: " .. tostring(err))
  end
end

-- Обработка входящих UDP-пакетов через событие on_udp_packet_received
script.on_event(defines.events.on_udp_packet_received, function(event)
  -- Ожидаем event.data как строку JSON
  local data = event.data or ""
  local ok, parsed = pcall(function() return json.decode(data) end)
  if not ok then
    -- Некорректный JSON — просто выведем сырые данные
    game.print("[Олег] Получен некорректный JSON: " .. tostring(data))
    return
  end

  if type(parsed) ~= "table" then
    game.print("[Олег] Неправильный формат сообщения: expected table")
    return
  end

  if parsed.type == "response" and parsed.text then
    local pidx = parsed.player_index
    if pidx and game.get_player(pidx) then
      game.get_player(pidx).print("[Олег] " .. tostring(parsed.text))
    else
      game.print("[Олег] " .. tostring(parsed.text))
    end
  else
    -- Другие типы или отсутствие text
    game.print("[Олег] Получено сообщение: " .. (tostring(parsed.text) or "(нет текста)"))
  end
end)

-- Периодически вызывать helpers.recv_udp чтобы события генерировались
-- Вызываем каждые 5 тиков
local TICK_POLL_INTERVAL = 5
script.on_event(defines.events.on_tick, function(event)
  if (event.tick % TICK_POLL_INTERVAL) == 0 then
    -- for_player = 0 чтобы принимать серверные/все пакеты; можно указать игрока
    pcall(function() helpers.recv_udp(0) end)
  end
end)

-- Команда /oleg для отправки сообщений боту
script.on_init(function()
  commands.add_command("oleg", "Отправить сообщение боту Олег: /oleg <текст>", function(cmd)
    if not cmd.player_index then
      if cmd.parameter then game.print("Команда /oleg предназначена для игроков: /oleg <сообщение>") end
      return
    end
    local txt = cmd.parameter or ""
    if txt == "" then
      game.get_player(cmd.player_index).print("Использование: /oleg <сообщение>")
      return
    end
    send_to_bridge(cmd.player_index, txt)
  end)
end)
