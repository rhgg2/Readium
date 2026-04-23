-- Tiny assertion helpers. Hand-rolled, zero deps.

local M = {}

local function repr(v, depth)
  depth = depth or 0
  if depth > 4 then return '...' end
  local t = type(v)
  if t == 'string' then return string.format('%q', v) end
  if t ~= 'table' then return tostring(v) end
  local parts, isArr, n = {}, true, 0
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= 'number' then isArr = false end
  end
  if isArr then
    for i = 1, n do parts[i] = repr(v[i], depth + 1) end
    return '[' .. table.concat(parts, ', ') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for i, k in ipairs(keys) do
    parts[i] = tostring(k) .. '=' .. repr(v[k], depth + 1)
  end
  return '{' .. table.concat(parts, ', ') .. '}'
end

local function deepEq(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function M.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'eq') .. ': expected ' .. repr(expected) .. ', got ' .. repr(actual), 2)
  end
end

function M.deepEq(actual, expected, msg)
  if not deepEq(actual, expected) then
    error((msg or 'deepEq') .. ':\n  expected ' .. repr(expected) .. '\n  got      ' .. repr(actual), 2)
  end
end

function M.truthy(v, msg)
  if not v then error((msg or 'expected truthy') .. ', got ' .. repr(v), 2) end
end

function M.falsy(v, msg)
  if v then error((msg or 'expected falsy') .. ', got ' .. repr(v), 2) end
end

-- Assert that an event array contains events matching each expected spec,
-- in order, matching only the fields present on the spec (subset match).
function M.eventsMatch(actual, expected, msg)
  M.eq(#actual, #expected, (msg or 'eventsMatch') .. ' length')
  for i, spec in ipairs(expected) do
    for k, v in pairs(spec) do
      if not deepEq(actual[i][k], v) then
        error(string.format('%s: event[%d].%s: expected %s, got %s',
          msg or 'eventsMatch', i, k, repr(v), repr(actual[i][k])), 2)
      end
    end
  end
end

M.repr = repr
M.deepEqRaw = deepEq
return M
