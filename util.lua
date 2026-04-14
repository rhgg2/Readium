util = {}

function util:print(...)
  if ( not ... ) then
    reaper.ShowConsoleMsg('nil value\n')
    return
  end
  reaper.ShowConsoleMsg(table.concat({...}, '\t') .. '\n')
end

local function print(...)
  return util:print(...)
end

-- dev only
function util:print_r(root)
  local cache = {  [root] = '.' }
  local function _dump(t,space,name)
    local temp = {}
    for k,v in pairs(t) do
      local key = tostring(k)
      if cache[v] then
        table.insert(temp,'+' .. key .. ' {' .. cache[v]..'}')
      elseif type(v) == 'table' then
        local new_key = name .. '.' .. key
        cache[v] = new_key
        table.insert(temp,'+' .. key .. _dump(v,space .. (next(t,k) and '|' or ' ' ).. string.rep(' ',#key),new_key))
      else
        table.insert(temp,'+' .. key .. ' [' .. tostring(v)..']')
      end
    end
    return table.concat(temp,'\n'..space)
  end
  print(_dump(root, '',''))
end

util.REMOVE = { }

function util:assign(t1,t2)
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

function util:add(tbl, val)
  local idx = #tbl+1
  tbl[idx] = val
  return val
end

function util:clone(src, exclude)
  if not src then return end
  local dst = {}
  for k, v in pairs(src) do
    if not (exclude and exclude[k]) then dst[k] = v end
  end
  return dst
end

local function escape_string(s)
  return (s:gsub('[\\{},=]', function(c)
    return '\\' .. c
  end))
end

function util:installHooks(owner)
  local listeners = {}
  function owner:addCallback(fn)    listeners[fn] = true end
  function owner:removeCallback(fn) listeners[fn] = nil  end
  return function(...)
    for fn in pairs(listeners) do fn(...) end
  end
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

function util:oneOf(choices, txt)
  for k in choices:gmatch('%S+') do
    if txt == k then return true end
  end
  return false
end


function util:serialise(value, exclude, seen)
  exclude = exclude or { } 
  local t = type(value)

  if t == 'number' or t == 'boolean' then
    return tostring(value)

  elseif t == 'string' then
    return escape_string(value)

  elseif t == 'table' then
    seen = seen or {}
    if seen[value] then
      error('cycle detected during serialisation')
    end
    seen[value] = true

    local parts = {}
    for k, v in pairs(value) do
      if not exclude[k] then
        local key_str = util:serialise(k, nil, seen)
        local val_str = util:serialise(v, nil, seen)
        parts[#parts+1] = key_str .. '=' .. val_str
      end
    end

    seen[value] = nil
    return '{' .. table.concat(parts, ',') .. '}'

  else
    error('unsupported type: ' .. t)
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

      if c == '\\' then
        local n = nextChar()

        if n == '{' or n == '}' or n == ',' or n == '=' or n == '\\' then
          buf[#buf+1] = n
        else
          error('invalid escape: \\' .. tostring(n))
        end

      elseif c == '{' or c == '}' or c == ',' or c == '=' then
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

    -- boolean
    if s == 'true' then return true end
    if s == 'false' then return false end

    return s
  end

  local parseValue -- forward decl

  local function parseTable()
    if nextChar() ~= '{' then
      error("expected '{'")
    end

    local t = {}

    if peek() == '}' then
      nextChar()
      return t
    end

    while true do
      local key = parseValue()

      if nextChar() ~= '=' then
        error("expected '=' after key")
      end

      local val = parseValue()
      t[key] = val

      local c = nextChar()

      if c == '}' then
        break
      elseif c == ',' then
        -- continue
      else
        error("expected ',' or '}'")
      end
    end

    return t
  end

  function parseValue()
    if peek() == '{' then
      return parseTable()
    else
      return parseStringToken()
    end
  end

  local result = parseValue()

  if pos <= len then
    error('trailing characters')
  end

  return result
end 
