-- See docs/timing.md for the model and API reference.
-- @noindex

timing = {}
local M = timing

local EPS = 1e-12

----- Atoms

M.atoms = {
  id = function()
    return { {0, 0}, {1, 1} }
  end,

  classic = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5, 0.5 + a}, {1, 1} }
  end,

  pocket = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.25, 0.25 + a}, {0.75, 0.75 + a}, {1, 1} }
  end,

  shuffle = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {1/3, 1/3 - a}, {2/3, 2/3 + a}, {1, 1} }
  end,

  drag = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5 + a, 0.5}, {1, 1} }
  end,

  lilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    local k = a * 0.7
    return { {0, 0}, {0.25, 0.25 + k}, {0.5, 0.5}, {0.75, 0.75 - k}, {1, 1} }
  end,
}

-- Max |amount| keeping each atom strictly monotonic; callers clamp.
M.atomRange = {
  id      = 0,
  classic = 0.5,
  pocket  = 0.25,
  shuffle = 1/3,
  drag    = 0.5,
  lilt    = 0.35,
}

----- Composite registry

-- Seed data only — the project library (cfg.swings) is the source of
-- truth at slot-resolution time. classic-NN reads as "NN% swing".
M.presets = {
  ['id']         = {},
  ['classic-55'] = { {atom = 'classic', amount = 0.05, period = 1} },
  ['classic-58'] = { {atom = 'classic', amount = 0.08, period = 1} },
  ['classic-62'] = { {atom = 'classic', amount = 0.12, period = 1} },
  ['classic-67'] = { {atom = 'classic', amount = 0.17, period = 1} },
}

function M.findShape(name, userLib)
  if not name or not userLib then return nil end
  return userLib[name]
end

function M.isIdentity(composite)
  return not composite or #composite == 0
end

----- Period helpers

-- Bad shape is a caller bug; fail loudly rather than guessing.
function M.periodQN(period)
  local t = type(period)
  if t == 'number' then return period end
  if t == 'table'  then return period[1] / period[2] end
  error('timing: bad period ' .. tostring(period))
end

----- Evaluation and inversion

local function lerp(x0, y0, x1, y1, x)
  if x1 == x0 then return y0 end
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
end

-- axis = 1 for x (eval), 2 for y (invert).
local function findSegment(S, target, axis)
  local n = #S
  if target <= S[1][axis]     then return 1 end
  if target >= S[n][axis]     then return n - 1 end
  local lo, hi = 1, n - 1
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if S[mid][axis] <= target then lo = mid else hi = mid - 1 end
  end
  return lo
end

function M.eval(S, x)
  local i = findSegment(S, x, 1)
  return lerp(S[i][1], S[i][2], S[i+1][1], S[i+1][2], x)
end

function M.invert(S, y)
  local i = findSegment(S, y, 2)
  return lerp(S[i][2], S[i][1], S[i+1][2], S[i+1][1], y)
end

----- Group operations

-- Swap (x,y) per control point; monotonicity and endpoints preserved,
-- so no re-sort.
function M.inverse(S)
  local inv = {}
  for i = 1, #S do inv[i] = { S[i][2], S[i][1] } end
  return inv
end

-- Breakpoints of S∘T are T's x-points ∪ T⁻¹(S's x-points): both drive
-- slope changes of the composite.
function M.compose(S, T)
  local xs = {}
  for _, p in ipairs(T) do xs[#xs + 1] = p[1] end
  for _, p in ipairs(S) do xs[#xs + 1] = M.invert(T, p[1]) end
  table.sort(xs)

  local pts = {}
  local last
  for _, x in ipairs(xs) do
    if not last or x - last > EPS then
      pts[#pts + 1] = { x, M.eval(S, M.eval(T, x)) }
      last = x
    end
  end
  -- Pin endpoints exactly against accumulated floating-point drift.
  pts[1][1],      pts[1][2]      = 0, 0
  pts[#pts][1],   pts[#pts][2]   = 1, 1
  return pts
end

----- Tiled extension

-- T <= 0 degrades to identity so callers can drive off empty composites.
function M.tile(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.eval(S, t - n))
end

function M.tileInverse(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.invert(S, t - n))
end

function M.applyFactors(factors, ppq)
  for _, f in ipairs(factors) do ppq = M.tile(f.S, f.T, ppq) end
  return ppq
end

function M.unapplyFactors(factors, ppq)
  for i = #factors, 1, -1 do
    local f = factors[i]
    ppq = M.tileInverse(f.S, f.T, ppq)
  end
  return ppq
end

----- Delay <-> PPQ

-- Round at source so the map is an integer bijection on ℤ; every
-- intent ± delayToPPQ(d) stays in ℤ and round-trips are algebraic.
function M.delayToPPQ(d, res)
  return util.round(res * (d or 0) / 1000)
end

function M.ppqToDelay(p, res)
  return 1000 * p / res
end

return M
