-- Минимальный мод "Олег" для Factorio с JSON-протоколом через UDP
-- Диагностический режим: выводит детальную информацию о входящих UDP-пакетах
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

-- DEBUG: расширенный обработчик входящих UDP-пакетов
script.on_event(defines.events.on_udp_packet_received, function(event)
  -- Соберём и выведем все ключи события (без значений, чтобы не переполнять чат)
  local keys = {}
  for k,_ in pairs(event) do
    table.insert(keys, tostring(k))
  end
  game.print("[Олег DEBUG] event keys: " .. table.concat(keys, ", "))

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

  local raw_type = type(raw)
  local raw_len = 0
  if raw then raw_len = #tostring(raw) end
  game.print("[Олег DEBUG] raw type=" .. raw_type .. " len=" .. tostring(raw_len))

  local sample = "(no data)"
  if raw then
    local s = tostring(raw)
    if #s > 300 then s = s:sub(1,300) .. " ... (truncated)" end
    sample = s
  end
  game.print("[Олег DEBUG] raw sample: " .. sample)

  -- Попробуем декодировать JSON безопасно
  if raw then
    local ok, parsed = pcall(function() return json.decode(tostring(raw)) end)
    if not ok then
      game.print("[Олег DEBUG] JSON decode failed: " .. tostring(parsed))
      return
    end
    if type(parsed) ~= "table" then
      game.print("[Олег DEBUG] parsed JSON is not a table")
      return
    end

    game.print("[Олег DEBUG] JSON decoded keys: " .. table.concat((function()
      local ks = {}
      for k,_ in pairs(parsed) do table.insert(ks, tostring(k)) end
      return ks
    end)(), ", "))

    if parsed.type == "response" and parsed.text then
      local pidx = parsed.player_index
      if pidx and game.get_player(pidx) then
        game.get_player(pidx).print("[Олег] " .. tostring(parsed.text))
      else
        -- если player_index отсутствует или невалиден, печатаем в global chat
        game.print("[Олег] " .. tostring(parsed.text))
      end
    else
      game.print("[Олег DEBUG] parsed has no .type==\"response\" or no .text field")
    end
  else
    game.print("[Олег DEBUG] no raw data field found in event")
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
