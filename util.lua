util = {}

function util:print(...)
  if ( not ... ) then
    reaper.ShowConsoleMsg("nil value\n")
    return
  end
  reaper.ShowConsoleMsg(table.concat({...}, "\t") .. "\n")
end

local function print(...)
  return util:print(...)
end

function util:print_r(root)
  local cache = {  [root] = "." }
  local function _dump(t,space,name)
    local temp = {}
    for k,v in pairs(t) do
      local key = tostring(k)
      if cache[v] then
        table.insert(temp,"+" .. key .. " {" .. cache[v].."}")
      elseif type(v) == "table" then
        local new_key = name .. "." .. key
        cache[v] = new_key
        table.insert(temp,"+" .. key .. _dump(v,space .. (next(t,k) and "|" or " " ).. string.rep(" ",#key),new_key))
      else
        table.insert(temp,"+" .. key .. " [" .. tostring(v).."]")
      end
    end
    return table.concat(temp,"\n"..space)
  end
  print(_dump(root, "",""))
end

util.REMOVE = { }

function util:assign(t1,t2,createIfNil)
  t1 = t1 or (createIfNil and { })
  if t2 then
    for k, v in pairs(t2) do
      if v == util.REMOVE then
        t1[k] = nil
      else
        t1[k] = v
      end
    end
  end
  return t1
end

util.IDX = { }

local function fillIdx(arg, val)
  if arg == util.IDX then return val end
  if type(arg) == 'table' then
    local rv = {}
    for k,v in pairs(arg) do
      rv[k] = fillIdx(v,val)
    end
    return rv
  end
  return arg
end


function util:add(tbl, val)
  local idx = #tbl+1
  local obj = fillIdx(val, idx)
  tbl[idx] = obj
  return obj
end

function util:pick(src, keys)
  local dst = {}
  for k in keys:gmatch("%S+") do
    dst[k] = src[k]
  end
  return dst
end

local function escape_string(s)
  return (s:gsub("[\\{},=]", function(c)
    return "\\" .. c
  end))
end

function util:serialise(value, exclude, seen)
  exclude = exclude or { } 
  local t = type(value)

  if t == "number" then
    return tostring(value)

  elseif t == "string" then
    return escape_string(value)

  elseif t == "table" then
    seen = seen or {}
    if seen[value] then
      error("cycle detected during serialisation")
    end
    seen[value] = true

    local parts = {}
    for k, v in pairs(value) do
      if not exclude[k] then
        local key_str = util:serialise(k, nil, seen)
        local val_str = util:serialise(v, nil, seen)
        parts[#parts+1] = key_str .. "=" .. val_str
      end
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"

  else
    error("unsupported type: " .. t)
  end
end

function util:unserialise(input)
  local pos = 1
  local len = #input

  local function peek()
    return input:sub(pos, pos)
  end

  local function nextChar()
    local c = input:sub(pos, pos)
    pos = pos + 1
    return c
  end

  local function parseStringToken()
    local buf = {}

    while pos <= len do
      local c = nextChar()

      if c == "\\" then
        local n = nextChar()

        if n == "{" or n == "}" or n == "," or n == "=" or n == "\\" then
          buf[#buf+1] = n
        else
          error("invalid escape: \\" .. tostring(n))
        end

      elseif c == "{" or c == "}" or c == "," or c == "=" then
        pos = pos - 1
        break

      else
        buf[#buf+1] = c
      end
    end

    local s = table.concat(buf)

    -- number detection
    local n = tonumber(s)
    if n ~= nil then
      return n
    end

    return s
  end

  local parseValue -- forward decl

  local function parseTable()
    if nextChar() ~= "{" then
      error("expected '{'")
    end

    local t = {}

    if peek() == "}" then
      nextChar()
      return t
    end

    while true do
      local key = parseValue()

      if nextChar() ~= "=" then
        error("expected '=' after key")
      end

      local val = parseValue()
      t[key] = val

      local c = nextChar()

      if c == "}" then
        break
      elseif c == "," then
        -- continue
      else
        error("expected ',' or '}'")
      end
    end

    return t
  end

  function parseValue()
    if peek() == "{" then
      return parseTable()
    else
      return parseStringToken()
    end
  end

  local result = parseValue()

  if pos <= len then
    error("trailing characters")
  end

  return result
end

function util:clamp(val,min,max)
  if val < min then
    return min
  elseif val > max then
    return max
  else
    return val
  end
end

function util:fromBase36(txt)
  if not tonumber(txt,36) then
    print("Error! " .. txt .. " is not a valid base36 string")
    return nil
  else
    return tonumber(txt,36)
  end
end

function util:toBase36(num)
  local alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  if num == 0 then return "0" end
  local result = ""
  while num > 0 do
    local remainder = num % 36
    result = string.sub(alphabet, remainder + 1, remainder + 1) .. result
    num = math.floor(num / 36)
  end
  return result
end

