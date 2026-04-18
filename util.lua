util = {}

function util:print(...)
  if not ... then
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
        temp[#temp+1] = '+' .. key .. ' {' .. cache[v]..'}'
      elseif type(v) == 'table' then
        local new_key = name .. '.' .. key
        cache[v] = new_key
        temp[#temp+1] = '+' .. key .. _dump(v,space .. (next(t,k) and '|' or ' ' ).. string.rep(' ',#key),new_key)
      else
        temp[#temp+1] = '+' .. key .. ' [' .. tostring(v)..']'
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
  tbl[#tbl+1] = val
  return val
end

-- seek: find an item on one side of a boundary in a key-sorted list.
-- mode is 'before' | 'at-or-before' | 'after' | 'at-or-after'.
-- keyFn extracts the scalar key from an item (defaults to .ppq).
-- filter is an optional predicate to restrict the match.
function util:seek(items, mode, key, filter, keyFn)
  keyFn = keyFn or function(x) return x.ppq end
  local before = mode == 'before' or mode == 'at-or-before'
  local cmp
  if     mode == 'before'       then cmp = function(k) return k <  key end
  elseif mode == 'at-or-before' then cmp = function(k) return k <= key end
  elseif mode == 'after'        then cmp = function(k) return k >  key end
  elseif mode == 'at-or-after'  then cmp = function(k) return k >= key end
  end
  local hit
  for _, item in ipairs(items) do
    if cmp(keyFn(item)) then
      if not filter or filter(item) then
        if not before then return item end
        hit = item
      end
    elseif before then
      break
    end
  end
  return hit
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

-- Canonical Bézier handle table recovered from REAPER's `bezier` shape.
-- Indexed by |τ| at 0.1 steps (rows[1] = |τ|=0.0, rows[11] = |τ|=1.0).
-- Row: { h, θ_large (rad), θ_small (rad) }. See design/curves.md.
local BEZIER = {
  { 0.2794, 0.4636,    0.4636 },
  { 0.3442, 0.7704,    0.3384 },
  { 0.4020, 0.9849,    0.2466 },
  { 0.4642, 1.1455,    0.1812 },
  { 0.5326, 1.2647,    0.1353 },
  { 0.6059, 1.3532,    0.1011 },
  { 0.6820, 1.4199,    0.0738 },
  { 0.7604, 1.4714,    0.0515 },
  { 0.8397, 1.5116,    0.0321 },
  { 0.9198, 1.5441,    0.0154 },
  { 1.0000, math.pi/2, 0      },
}

local function bezierSample(tau, t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  local fi = util:clamp(math.abs(tau), 0, 1) * 10
  local i = math.min(math.floor(fi), 9)
  local f = fi - i
  local r0, r1 = BEZIER[i+1], BEZIER[i+2]
  local h  = r0[1] + (r1[1] - r0[1]) * f
  local tL = r0[2] + (r1[2] - r0[2]) * f
  local tS = r0[3] + (r1[3] - r0[3]) * f
  local t1, t2 = tS, tL
  if tau < 0 then t1, t2 = tL, tS end
  local ax, ay = h*math.cos(t1),     h*math.sin(t1)
  local bx, by = 1 - h*math.cos(t2), 1 - h*math.sin(t2)
  -- x(s) is monotonic on [0,1]; bisect to find s with x(s) = t, then eval y(s).
  local lo, hi = 0, 1
  for _ = 1, 20 do
    local s = (lo + hi) * 0.5
    local u = 1 - s
    local x = 3*u*u*s*ax + 3*u*s*s*bx + s*s*s
    if x < t then lo = s else hi = s end
  end
  local s = (lo + hi) * 0.5
  local u = 1 - s
  return 3*u*u*s*ay + 3*u*s*s*by + s*s*s
end

-- y ∈ [0,1] for normalised t ∈ [0,1], given a REAPER CC shape name.
-- tension is only used for 'bezier' and expected in [-1, 1].
function util:curveSample(shape, tension, t)
  if     shape == 'step'       then return t >= 1 and 1 or 0
  elseif shape == 'linear'     then return t
  elseif shape == 'slow'       then return t*t*(3 - 2*t)
  elseif shape == 'fast-start' then local u = 1 - t; return 1 - u*u*u
  elseif shape == 'fast-end'   then return t*t*t
  elseif shape == 'bezier'     then return bezierSample(tension or 0, t)
  end
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
    if n then return n end

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
