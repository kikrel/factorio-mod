local BRIDGE_PORT = 38767

local function hex_encode(data)
  local out = {}
  for i = 1, #data do
    out[#out + 1] = string.format("%02X", data:byte(i))
  end
  return table.concat(out)
end

local function hex_decode(data)
  local out = {}
  for i = 1, #data, 2 do
    local byte = tonumber(data:sub(i, i + 1), 16)
    if not byte then
      return nil
    end
    out[#out + 1] = string.char(byte)
  end
  return table.concat(out)
end


local function add_button(player)
  if player and player.valid and not player.gui.top.oleg_button then
    player.gui.top.add{
      type = "button",
      name = "oleg_button",
      caption = "Олег"
    }
  end
end

local function set_response(player, text)
  if not player or not player.valid then return end
  local window = player.gui.screen.oleg_window
  if not window or not window.valid then return end
  local body = window.children[1]
  if body and body.valid and body.oleg_response then
    body.oleg_response.caption = text
  end
end

local function open_gui(player)
  if player.gui.screen.oleg_window then
    player.gui.screen.oleg_window.destroy()
    return
  end

  local frame = player.gui.screen.add{
    type = "frame",
    name = "oleg_window",
    direction = "vertical",
    caption = "Олег — ИИ-инженер"
  }
  frame.auto_center = true

  local body = frame.add{type = "flow", direction = "vertical"}

  body.add{
    type = "label",
    caption = "Напиши вопрос. Ответ придёт сюда."
  }

  local input = body.add{
    type = "text-box",
    name = "oleg_input",
    text = ""
  }
  input.style.width = 520
  input.style.height = 100

  body.add{
    type = "button",
    name = "oleg_send",
    caption = "Отправить"
  }

  local response = body.add{
    type = "label",
    name = "oleg_response",
    caption = "Олег подключается..."
  }
  response.style.single_line = false
  response.style.maximal_width = 520
end

script.on_init(function()
  storage.pending = {}
end)

script.on_configuration_changed(function()
  storage.pending = storage.pending or {}
end)

script.on_event(defines.events.on_player_created, function(e)
  add_button(game.get_player(e.player_index))
end)

script.on_event(defines.events.on_tick, function()
  for _, player in pairs(game.connected_players) do
    add_button(player)
  end

  -- Factorio 2.0 requires recv_udp() to feed incoming packets into
  -- on_udp_packet_received.
  helpers.recv_udp()
end)

script.on_event(defines.events.on_gui_click, function(e)
  if not e.element or not e.element.valid then return end
  local player = game.get_player(e.player_index)
  if not player then return end

  if e.element.name == "oleg_button" then
    open_gui(player)
    return
  end

  if e.element.name == "oleg_send" then
    local window = player.gui.screen.oleg_window
    if not window or not window.valid then return end

    local body = window.children[1]
    local input = body and body.oleg_input
    if not input or not input.valid then return end

    local question = input.text
    if not question or question:gsub("%s+", "") == "" then
      set_response(player, "Олег: Напиши что-нибудь, инженер.")
      return
    end

    local request = {
      type = "chat",
      player_index = player.index,
      player_name = player.name,
      message_hex = hex_encode(question)
    }

    local ok, payload = pcall(helpers.table_to_json, request)
    if not ok then
      set_response(player, "Олег: не смог подготовить запрос.")
      return
    end

    set_response(player, "Олег подключается к мозгам...")
    helpers.send_udp(BRIDGE_PORT, payload)

    input.text = ""
  end
end)

script.on_event(defines.events.on_udp_packet_received, function(e)
  local ok, data = pcall(helpers.json_to_table, e.payload)
  if not ok or type(data) ~= "table" then return end

  if data.type == "chat_response" and data.player_index and data.text_hex then
    local player = game.get_player(data.player_index)
    if player then
      local answer = hex_decode(data.text_hex)
      if answer then
        set_response(player, answer)
        player.print("Олег: " .. answer)
      else
        set_response(player, "Не удалось декодировать ответ Олега.")
      end
    end
  end
end)
