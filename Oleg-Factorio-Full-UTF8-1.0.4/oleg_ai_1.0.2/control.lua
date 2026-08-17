local BRIDGE_PORT = 38767

local function hex_encode(text)
  local parts = {}
  for i = 1, #text do
    parts[#parts + 1] = string.format("%02X", text:byte(i))
  end
  return table.concat(parts)
end

local function hex_decode(text)
  if type(text) ~= "string" or #text % 2 ~= 0 then return nil end
  local parts = {}
  for i = 1, #text, 2 do
    local byte = tonumber(text:sub(i, i + 1), 16)
    if not byte then return nil end
    parts[#parts + 1] = string.char(byte)
  end
  return table.concat(parts)
end

local function add_button(player)
  if player and player.valid and not player.gui.top.oleg_button then
    player.gui.top.add{type = "button", name = "oleg_button", caption = "Олег"}
  end
end

local function set_response(player, text)
  local frame = player.gui.screen.oleg_window
  if frame and frame.valid and frame.oleg_body and frame.oleg_body.oleg_response then
    frame.oleg_body.oleg_response.caption = text
  end
end

local function toggle_window(player)
  local old = player.gui.screen.oleg_window
  if old and old.valid then old.destroy(); return end

  local frame = player.gui.screen.add{
    type = "frame", name = "oleg_window", direction = "vertical", caption = "Олег — ИИ-инженер"
  }
  frame.auto_center = true
  local body = frame.add{type = "flow", name = "oleg_body", direction = "vertical"}
  body.add{type = "label", caption = "Напиши вопрос. Ответ придёт сюда."}
  local input = body.add{type = "text-box", name = "oleg_input", text = ""}
  input.style.width = 520
  input.style.height = 100
  body.add{type = "button", name = "oleg_send", caption = "Отправить"}
  local response = body.add{type = "label", name = "oleg_response", caption = "Олег готов к разговору."}
  response.style.single_line = false
  response.style.maximal_width = 520
end

script.on_event(defines.events.on_player_created, function(event)
  add_button(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_tick, function()
  for _, player in pairs(game.connected_players) do add_button(player) end
  helpers.recv_udp()
end)

script.on_event(defines.events.on_gui_click, function(event)
  if not event.element or not event.element.valid then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if event.element.name == "oleg_button" then
    toggle_window(player)
    return
  end
  if event.element.name ~= "oleg_send" then return end

  local frame = player.gui.screen.oleg_window
  local input = frame and frame.valid and frame.oleg_body and frame.oleg_body.oleg_input
  if not input or not input.valid then return end
  local question = input.text
  if question:gsub("%s+", "") == "" then
    set_response(player, "Олег: напиши что-нибудь.")
    return
  end

  -- The UDP JSON contains only ASCII: user UTF-8 bytes are sent as HEX.
  local payload = helpers.table_to_json{
    type = "chat",
    player_index = player.index,
    message_hex = hex_encode(question)
  }
  set_response(player, "Олег думает...")
  helpers.send_udp(BRIDGE_PORT, payload)
  input.text = ""
end)

script.on_event(defines.events.on_udp_packet_received, function(event)
  local ok, packet = pcall(helpers.json_to_table, event.payload)
  if not ok or type(packet) ~= "table" or packet.type ~= "chat_response" then return end
  local player = game.get_player(packet.player_index)
  local answer = hex_decode(packet.text_hex)
  if player and answer then
    set_response(player, answer)
    player.print("Олег: " .. answer)
  end
end)
