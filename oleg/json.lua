-- json.lua (rxi) -- minimal pure-Lua JSON module (encode/decode)
-- MIT licensed. Suitable for typical strings/numbers/booleans/nil/tables (arrays and objects).
local json = { _version = "0.1.2" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------
local encode

local escape_char_map = {
  [ "\\" ] = "\\\\",
  [ '"' ] = '\\"',
  [ "\b" ] = "\\b",
  [ "\f" ] = "\\f",
  [ "\n" ] = "\\n",
  [ "\r" ] = "\\r",
  [ "\t" ] = "\\t",
}
local escape_char_map_inv = { ["\\"] = "\\", ['\"'] = '"', ['/']="/", ['b']='\b', ['f']='\f', ['n']='\n', ['r']='\r', ['t']='\t' }

local function escape_string(s)
  return s:gsub('[%z\1-\31\\"]', function(c)
    return escape_char_map[c] or string.format("\\u%04x", c:byte())
  end)
end

local function is_array(t)
  -- check keys 1..n
  local max = 0
  local count = 0
  for k,v in pairs(t) do
    if type(k) == "number" and k > 0 and math.floor(k) == k then
      if k > max then max = k end
      count = count + 1
    else
      return false
    end
  end
  if max > count * 2 then -- sparse arrays likely objects
    return false
  end
  return true, max
end

local function encode_value(v, buf)
  local t = type(v)
  if t == "nil" then
    table.insert(buf, "null")
  elseif t == "boolean" then
    table.insert(buf, tostring(v))
  elseif t == "number" then
    -- JSON does not support NaN/inf
    if v ~= v or v == math.huge or v == -math.huge then
      table.insert(buf, "null")
    else
      table.insert(buf, tostring(v))
    end
  elseif t == "string" then
    table.insert(buf, '"' .. escape_string(v) .. '"')
  elseif t == "table" then
    local array_ok, max = is_array(v)
    if array_ok then
      table.insert(buf, "[")
      for i = 1, max do
        if i > 1 then table.insert(buf, ",") end
        encode_value(v[i], buf)
      end
      table.insert(buf, "]")
    else
      table.insert(buf, "{")
      local first = true
      for k, val in pairs(v) do
        if type(k) ~= "string" then
          -- skip non-string keys
        else
          if not first then table.insert(buf, ",") end
          first = false
          table.insert(buf, '"' .. escape_string(k) .. '":')
          encode_value(val, buf)
        end
      end
      table.insert(buf, "}")
    end
  else
    -- unsupported types -> null
    table.insert(buf, "null")
  end
end

function json.encode(v)
  local buf = {}
  encode_value(v, buf)
  return table.concat(buf)
end

-------------------------------------------------------------------------------
-- Decode (simple recursive descent)
-------------------------------------------------------------------------------
local pos, json_text

local function skip_ws()
  while true do
    local c = json_text:sub(pos,pos)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      pos = pos + 1
    else
      break
    end
  end
end

local function parse_null()
  if json_text:sub(pos, pos+3) == "null" then pos = pos + 4; return nil end
  error("invalid value at position " .. pos)
end

local function parse_true()
  if json_text:sub(pos, pos+3) == "true" then pos = pos + 4; return true end
  error("invalid value at position " .. pos)
end

local function parse_false()
  if json_text:sub(pos, pos+4) == "false" then pos = pos + 5; return false end
  error("invalid value at position " .. pos)
end

local function parse_number()
  local start_pos = pos
  local c = json_text:sub(pos,pos)
  if c == "-" then pos = pos + 1; c = json_text:sub(pos,pos) end
  if c >= "0" and c <= "9" then
    if c == "0" then pos = pos + 1
    else
      repeat pos = pos + 1; c = json_text:sub(pos,pos) until not (c >= "0" and c <= "9")
    end
  else
    error("invalid number at position " .. pos)
  end
  if json_text:sub(pos,pos) == "." then
    pos = pos + 1
    c = json_text:sub(pos,pos)
    if not (c >= "0" and c <= "9") then error("invalid number frac at " .. pos) end
    repeat pos = pos + 1; c = json_text:sub(pos,pos) until not (c >= "0" and c <= "9")
  end
  local exp = json_text:sub(pos,pos)
  if exp == "e" or exp == "E" then
    pos = pos + 1
    c = json_text:sub(pos,pos)
    if c == "+" or c == "-" then pos = pos + 1; c = json_text:sub(pos,pos) end
    if not (c >= "0" and c <= "9") then error("invalid number exp at " .. pos) end
    repeat pos = pos + 1; c = json_text:sub(pos,pos) until not (c >= "0" and c <= "9")
  end
  local num_s = json_text:sub(start_pos, pos-1)
  local num = tonumber(num_s)
  if not num then error("invalid number conversion at " .. start_pos) end
  return num
end

local function parse_string()
  local res = {}
  assert(json_text:sub(pos,pos) == '"')
  pos = pos + 1
  while true do
    local c = json_text:sub(pos,pos)
    if c == '"' then pos = pos + 1; return table.concat(res) end
    if c == "\\" then
      local esc = json_text:sub(pos+1,pos+1)
      if esc == "u" then
        local hex = json_text:sub(pos+2, pos+5)
        local n = tonumber(hex, 16)
        if not n then error("invalid \\u hex at " .. pos) end
        table.insert(res, utf8.char(n))
        pos = pos + 6
      else
        local ch = escape_char_map_inv[esc]
        if not ch then ch = esc end
        table.insert(res, ch)
        pos = pos + 2
      end
    else
      table.insert(res, c)
      pos = pos + 1
    end
  end
end

local function parse_array()
  assert(json_text:sub(pos,pos) == "[")
  pos = pos + 1
  skip_ws()
  local arr = {}
  if json_text:sub(pos,pos) == "]" then pos = pos + 1; return arr end
  while true do
    skip_ws()
    local val = json.decode_at(pos)
    table.insert(arr, val)
    pos = json._pos -- updated by decode_at
    skip_ws()
    local c = json_text:sub(pos,pos)
    if c == "," then pos = pos + 1
    elseif c == "]" then pos = pos + 1; break
    else error("expected ] or , at " .. pos) end
  end
  return arr
end

local function parse_object()
  assert(json_text:sub(pos,pos) == "{")
  pos = pos + 1
  skip_ws()
  local obj = {}
  if json_text:sub(pos,pos) == "}" then pos = pos + 1; return obj end
  while true do
    skip_ws()
    if json_text:sub(pos,pos) ~= '"' then error("expected string for object key at " .. pos) end
    local key = parse_string()
    skip_ws()
    if json_text:sub(pos,pos) ~= ":" then error("expected : after key at " .. pos) end
    pos = pos + 1
    skip_ws()
    local val = json.decode_at(pos)
    obj[key] = val
    pos = json._pos
    skip_ws()
    local c = json_text:sub(pos,pos)
    if c == "," then pos = pos + 1
    elseif c == "}" then pos = pos + 1; break
    else error("expected } or , at " .. pos) end
  end
  return obj
end

function json.decode_at(p)
  pos = p
  skip_ws()
  local c = json_text:sub(pos,pos)
  if c == "{" then
    local v = parse_object()
    json._pos = pos
    return v
  elseif c == "[" then
    local v = parse_array()
    json._pos = pos
    return v
  elseif c == '"' then
    local v = parse_string()
    json._pos = pos
    return v
  elseif c == "-" or (c >= "0" and c <= "9") then
    local v = parse_number()
    json._pos = pos
    return v
  elseif c == "n" then
    local v = parse_null(); json._pos = pos; return v
  elseif c == "t" then
    local v = parse_true(); json._pos = pos; return v
  elseif c == "f" then
    local v = parse_false(); json._pos = pos; return v
  else
    error("unexpected character '" .. c .. "' at " .. pos)
  end
end

function json.decode(s)
  json_text = s
  pos = 1
  local ok, res = pcall(function() return json.decode_at(1) end)
  if not ok then error(res) end
  skip_ws()
  if pos <= #json_text then
    -- trailing garbage allowed but warn? we'll ignore
  end
  return res
end

return json
