--[[
@noindex
--
-- timing.lua
--
-- Pure module: swings as piecewise-linear orientation-preserving
-- homeomorphisms of [0,1] fixing the endpoints, with composition,
-- inversion, and tiled extension along a periodic (PPQ) axis. No
-- module-level state; all functions take explicit arguments.
--
-- A swing shape is a sorted array of control points, starting at
-- {0,0} and ending at {1,1}, with strictly increasing x and y:
--
--   S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
--
-- Evaluation S(x) and inversion S^-1(y) are O(log n) via binary search
-- on the points. Shapes form a group under composition; the identity
-- is { {0,0}, {1,1} }.
--
-- To act on a time axis, attach a period T. The tiled extension
-- reparameterises within each window of length T:
--
--   tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
--
-- This fixes every multiple of T. Period is in quarter notes (decimal
-- or {num, den}), matching REAPER's native PPQ coordinate. QN is used
-- in preference to "beat" because a beat is time-sig-denominator-
-- dependent and ambiguous in 6/8, 12/8, etc; QN is always exactly one
-- quarter note regardless of time sig.
--
-- A user-facing swing is a *composite*: an ordered list of factors,
-- each a basic shape with its own period. The realised view transform
-- is the composition of the factors' tiled extensions:
--
--   composite = { {atom, amount, period}, ... }
--
-- where `atom` names an entry in `timing.atoms`, `amount` is that
-- atom's shape parameter, and `period` is in QN. An empty array is
-- the identity composite. The library lives in `cfg.swings` at project
-- scope; slots reference composites by name only, and the name is
-- guaranteed to resolve within the project's library.
]]--

timing = {}
local M = timing

local EPS = 1e-12

--------------------
-- Atoms: basic shape constructors on [0,1]
--
-- Each atom takes a single `amount` parameter and returns a PWL shape.
-- Ranges noted below keep the result strictly monotonic; going beyond
-- the open interval collapses a segment and breaks invertibility.
-- Callers (UI, config load) are responsible for clamping.
--------------------

M.atoms = {
  -- identity: amount ignored.
  id = function()
    return { {0, 0}, {1, 1} }
  end,

  -- classic: single kink at the midpoint. a > 0 pushes the off-beat
  -- later ("swung"); a < 0 earlier. Range: a ∈ (-0.5, 0.5).
  classic = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5, 0.5 + a}, {1, 1} }
  end,

  -- pocket: endpoints fixed, interior pushed back (a > 0) or forward
  -- (a < 0) uniformly. Range: a ∈ (-0.25, 0.25).
  pocket = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.25, 0.25 + a}, {0.75, 0.75 + a}, {1, 1} }
  end,

  -- shuffle: triplet feel at the thirds. a = 1/6 gives the classical
  -- 2:1 ratio. Range: a ∈ (-1/3, 1/3).
  shuffle = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {1/3, 1/3 - a}, {2/3, 2/3 + a}, {1, 1} }
  end,

  -- drag: asymmetric — stretches the first half (a > 0) or the second
  -- (a < 0). Negative amount is "rush". Range: a ∈ (-0.5, 0.5).
  drag = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5 + a, 0.5}, {1, 1} }
  end,

  -- lilt: smooth bump and return, midpoint pinned. Approximates a
  -- gentle sinusoidal lilt. Range: a ∈ (-0.35, 0.35).
  lilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    local k = a * 0.7
    return { {0, 0}, {0.25, 0.25 + k}, {0.5, 0.5}, {0.75, 0.75 - k}, {1, 1} }
  end,
}

-- Maximum |amount| keeping the atom strictly monotonic. The atom itself
-- does not clamp; UI widgets and config loaders read this to build
-- range-aware sliders / validators.
M.atomRange = {
  id      = 0,
  classic = 0.5,
  pocket  = 0.25,
  shuffle = 1/3,
  drag    = 0.5,
  lilt    = 0.35,
}

--------------------
-- Composite registry and lookup
--
-- Builtin presets are seed data — not consulted at slot-resolution
-- time. A project's runtime library (`cfg.swings`) is the sole source
-- of truth for name → composite; presets exist so the UI / cycle
-- commands can copy entries into the library on demand.
--
-- Naming convention `classic-NN` reads as "NN% swing" — the second
-- half of the window lands at x = 0.NN (classic-50 = identity,
-- classic-67 = triplet feel).
--------------------

M.presets = {
  ['id']         = {},
  ['classic-55'] = { {atom = 'classic', amount = 0.05, period = 1} },
  ['classic-58'] = { {atom = 'classic', amount = 0.08, period = 1} },
  ['classic-62'] = { {atom = 'classic', amount = 0.12, period = 1} },
  ['classic-67'] = { {atom = 'classic', amount = 0.17, period = 1} },
}

-- Look up a composite by name in the project library. Missing name or
-- missing library returns nil; callers treat nil as identity.
function M.findShape(name, userLib)
  if not name or not userLib then return nil end
  return userLib[name]
end

-- True if the composite is identity (nil or empty). Useful for
-- early-out in slot resolution.
function M.isIdentity(composite)
  return not composite or #composite == 0
end

--------------------
-- Period helpers
--------------------

-- A period is either a number or a two-element array {num, den} meaning
-- num/den. Returns the period as a scalar in QN. Other shapes are a
-- caller bug; fail loudly rather than guessing.
function M.periodQN(period)
  local t = type(period)
  if t == 'number' then return period end
  if t == 'table'  then return period[1] / period[2] end
  error('timing: bad period ' .. tostring(period))
end

--------------------
-- Evaluation and inversion
--------------------

local function lerp(x0, y0, x1, y1, x)
  if x1 == x0 then return y0 end
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
end

-- Largest i in [1, #S-1] with S[i][axis] <= target. Binary search.
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

--------------------
-- Group operations
--------------------

-- S^-1: swap (x,y) on every control point. Endpoints are already fixed,
-- and strict monotonicity is preserved, so no re-sorting is needed.
function M.inverse(S)
  local inv = {}
  for i = 1, #S do inv[i] = { S[i][2], S[i][1] } end
  return inv
end

-- (S o T)(x) = S(T(x)). Piecewise-linear with breakpoints at T's x-points
-- and at T^-1(S's x-points) — both drive slope changes of the composite.
-- Materialise by evaluating the composition at the union of breakpoints.
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

--------------------
-- Tiled extension on a PPQ axis
--------------------

-- Forward: raw PPQ → swung PPQ, given shape S and period T (PPQ).
-- Multiples of T are fixed points. T <= 0 is treated as identity.
function M.tile(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.eval(S, t - n))
end

-- Inverse of tile for the same (S, T).
function M.tileInverse(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.invert(S, t - n))
end

return M
