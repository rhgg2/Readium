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
-- A swing is a sorted array of control points, starting at {0,0} and
-- ending at {1,1}, with strictly increasing x and y:
--
--   S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
--
-- Evaluation S(x) and inversion S^-1(y) are O(log n) via binary search
-- on the points. Swings form a group under composition; the identity
-- is { {0,0}, {1,1} }.
--
-- To act on a time axis, attach a period T. The tiled extension
-- reparameterises within each window of length T:
--
--   tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
--
-- This fixes every multiple of T. Period is a property of the *slot*
-- where a swing is installed, not of the swing itself, and is given
-- in quarter notes (decimal or {num, den}), matching REAPER's native
-- PPQ coordinate. QN is used in preference to "beat" because a beat
-- is time-sig-denominator-dependent and ambiguous in 6/8, 12/8, etc;
-- QN is always exactly one quarter note regardless of time sig.
]]--

timing = {}
local M = timing

local EPS = 1e-12

--------------------
-- Shapes: constructors and named registry
--------------------

M.id = { {0, 0}, {1, 1} }

-- classic(amount): single control point at x = 0.5, with y = 0.5 + amount.
-- amount = 0 is identity; amount > 0 pushes the off-beat later (classic
-- two-per-beat swing). Valid range: amount in (-0.5, 0.5).
function M.classic(amount)
  if not amount or amount == 0 then return M.id end
  return { {0, 0}, {0.5, 0.5 + amount}, {1, 1} }
end

-- Built-in registry of named shapes. Keys are the names users see in the
-- slot picker; values are Swings. Parallel to microtuning.tunings. The
-- naming convention `classic-NN` reads as "NN% swing" — the second half
-- of the window lands at x = 0.NN (so classic-50 is identity, classic-67
-- is the triplet feel).
M.presets = {
  ['id']         = M.id,
  ['classic-55'] = M.classic(0.05),
  ['classic-58'] = M.classic(0.08),
  ['classic-62'] = M.classic(0.12),
  ['classic-67'] = M.classic(0.17),
}

-- Look up a shape by name. Searches a user-supplied registry first
-- (typically cfg.swings), falling back to the built-in presets. Returns
-- nil if no entry matches — caller decides whether that means "use id"
-- or "surface an error".
function M.findShape(name, userLib)
  if not name then return nil end
  if userLib and userLib[name] then return userLib[name] end
  return M.presets[name]
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

-- Forward: raw PPQ → swung PPQ, given swing S and period T (PPQ).
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
