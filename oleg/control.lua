-- Минимальный мод "Олег" для Factorio с JSON-протоколом через UDP
-- Производственная (clean) версия — без диагностического вывода
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
  -- Попробуем найти сырое содержимое в разных возможных полях
  local raw = nil
  if event.data then
    raw = event.data
  elseif event.packet and event.packet.data then
    raw = event.packet.data
  elseif event.message then
    raw = event.message
  elseif event.payload then
    raw = event.payload
  else
    raw = nil
  end

  if not raw then return end

  -- Преобразуем в строку и очистим возможные нулевые байты и BOM
  local s = tostring(raw)
  s = s:gsub("%z", "")
  s = s:gsub("^\239\187\191", "")

  local ok, parsed = pcall(function() return json.decode(s) end)
  if not ok then
    -- Невалидный JSON — игнорируем
    return
  end
  if type(parsed) ~= "table" then return end

  if parsed.type == "response" and parsed.text then
    local pidx = parsed.player_index
    if pidx and game.get_player(pidx) then
      game.get_player(pidx).print("[Олег] " .. tostring(parsed.text))
    else
      game.print("[Олег] " .. tostring(parsed.text))
    end
  end
end)

-- Обработка обычного игрового чата (без команды) — отправляем игрокские сообщения боту
-- Защита от зацикливания: игнорируем сообщения, начинающиеся с префикса '[Олег]'
script.on_event(defines.events.on_console_chat, function(event)
  -- только сообщения от игроков
  if not event.player_index then return end
  local msg = event.message or ""
  -- Игнорируем сообщения, которые мод сам вывел
  if msg:match("^%[Олег%]") then
    return
  end
  -- Отправляем в bridge
  send_to_bridge(event.player_index, msg)
end)

-- Периодически вызывать helpers.recv_udp чтобы события генерировались
-- Вызываем каждые 5 тиков
local TICK_POLL_INTERVAL = 5
script.on_event(defines.events.on_tick, function(event)
  if (event.tick % TICK_POLL_INTERVAL) == 0 then
    -- Важно: вызываем helpers.recv_udp() без аргумента, чтобы обработать все пакеты
    pcall(function() helpers.recv_udp() end)
  end
end)

-- Команда /oleg для отправки сообщений боту (запасной вариант)
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
