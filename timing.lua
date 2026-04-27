-- See docs/timing.md for the model and API reference.
-- @noindex

timing = {}
local M = timing

local EPS = 1e-12

----- Atoms

-- Atoms are unit-square shape generators; the editor calls them via
-- atom(shift / atomTilePeriod) so the user-visible knob is QN-of-shift,
-- atom-independent (see docs/timing.md "Composite model").

-- Smooth atoms sample to dense PWL — eval/invert/tile and the preview
-- renderer all consume the canonical {{x,y},...} form, so smooth becomes
-- a property of how the shape is generated, not of the runtime. SAMPLES
-- is a multiple of 12 so principal-pulse breakpoints (x = 1/4, 1/3,
-- 1/2, 2/3, 3/4) all land on exact sample points — the cross-atom
-- drop-in invariant stays algebraic.
local SAMPLES = 240

local function sampled(f)
  local pts = { {0, 0} }
  for i = 1, SAMPLES - 1 do
    local x = i / SAMPLES
    pts[#pts + 1] = { x, f(x) }
  end
  pts[#pts + 1] = { 1, 1 }
  return pts
end

M.atoms = {
  id = function()
    return { {0, 0}, {1, 1} }
  end,

  -- classic: PWL tent, single sharp kink at x=0.5. The reference shape
  -- against which the smooth atoms are calibrated.
  classic = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5, 0.5 + a}, {1, 1} }
  end,

  -- drag: PWL x-mirror of classic — the breakpoint slides along y=0.5.
  -- With the uniform a = shift/T convention, +shift slides the
  -- breakpoint later, so events near the midpoint arrive earlier than
  -- nominal. Magnitude only agrees with the others in the small-a limit.
  drag = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return { {0, 0}, {0.5 + a, 0.5}, {1, 1} }
  end,

  -- arc: smooth, single sin bump. y = x + a·sin(πx). Peak +a at x=0.5;
  -- slope 1 ± aπ at the endpoints. Smooth analogue of classic.
  arc = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * math.sin(math.pi * x) end)
  end,

  -- pocket: smooth flat-top bump. y = x + a·(1 − (2x−1)^6). Peak +a at
  -- x=0.5 with a near-plateau through the central region — the entire
  -- middle is shifted by ≈+a, the corners ramp smoothly to the
  -- endpoints. The "in the pocket" feel: events sit consistently behind
  -- the beat across a wide central band.
  pocket = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x)
      local d = 2*x - 1
      return x + a * (1 - d^6)
    end)
  end,

  -- lilt: smooth alternating sin. y = x + a·sin(2πx). Peak +a at
  -- x=0.25, trough −a at x=0.75 — alternating push/pull within each
  -- pair of pulses. pulsesPerCycle = 2.
  lilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * math.sin(2 * math.pi * x) end)
  end,

  -- shuffle: smooth triplet swing, anti-symmetric about x=0.5.
  -- Two-harmonic combination chosen so the extrema land exactly on the
  -- triplet positions: trough −a at x=1/3, peak +a at x=2/3. The
  -- coefficient k = 2/(3√3) sets |σ| = 1 at those extrema.
  shuffle = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    local k = 2 / (3 * math.sqrt(3))
    return sampled(function(x)
      return x + a * k * (-2*math.sin(2*math.pi*x) + math.sin(4*math.pi*x))
    end)
  end,

  -- tilt: smooth asymmetric bump skewed forward. y = x + a·(27/4)·x·(1−x)².
  -- Peak +a at x=1/3 — events near the front of the cycle get pushed
  -- back hardest, the back two-thirds settle smoothly. Unidirectional
  -- triplet feel; complement to shuffle's anti-symmetric pull-then-push.
  tilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * (27/4) * x * (1-x)^2 end)
  end,
}

-- Per-atom metadata. range = max |a| keeping the shape monotonic
-- (callers clamp). pulsesPerCycle = how many user-pulses fit inside
-- one atom cycle; only lilt has two principal pulses per cycle, so
-- its tile period is doubled.
M.atomMeta = {
  id      = { range = 0,                           pulsesPerCycle = 1 },
  classic = { range = 0.5,                         pulsesPerCycle = 1 },
  drag    = { range = 0.5,                         pulsesPerCycle = 1 },
  arc     = { range = 1/math.pi,                   pulsesPerCycle = 1 },
  pocket  = { range = 1/12,                        pulsesPerCycle = 1 },
  lilt    = { range = 1/(2*math.pi),               pulsesPerCycle = 2 },
  shuffle = { range = 9/(16*math.pi*math.sqrt(3)), pulsesPerCycle = 1 },
  tilt    = { range = 4/27,                        pulsesPerCycle = 1 },
}

-- The actual repeat period of a factor in QN: user period × pulsesPerCycle.
function M.atomTilePeriod(factor)
  return M.periodQN(factor.period) * M.atomMeta[factor.atom].pulsesPerCycle
end

----- Composite registry

-- Seed data only — the project library (cfg.swings) is the source of
-- truth at slot-resolution time. classic-NN reads as "NN% swing".
M.presets = {
  ['id']         = {},
  ['classic-55'] = { {atom = 'classic', shift = 0.05, period = 1} },
  ['classic-58'] = { {atom = 'classic', shift = 0.08, period = 1} },
  ['classic-62'] = { {atom = 'classic', shift = 0.12, period = 1} },
  ['classic-67'] = { {atom = 'classic', shift = 0.17, period = 1} },
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

-- Smallest T at which every factor's tile completes — i.e. the period
-- of the composite as a repeating function. For rationals nᵢ/dᵢ that's
-- lcm(nᵢ)/gcd(dᵢ). Empty composite ⇒ 1 qn (one beat). Tile periods
-- here are the *internal* ones (period × pulsesPerCycle), so the result
-- reflects the actual repeat rate of the transform, not the user-period.
function M.compositePeriodQN(composite)
  if not composite or #composite == 0 then return 1 end
  local nL, dG
  for _, f in ipairs(composite) do
    local p     = f.period
    local mult  = M.atomMeta[f.atom].pulsesPerCycle
    local n     = ((type(p) == 'table') and p[1] or p) * mult
    local d     = (type(p) == 'table') and p[2] or 1
    nL = nL and util.lcm(nL, n) or n
    dG = dG and util.gcd(dG, d) or d
  end
  return nL / dG
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

----- Authoring round-trip

-- Authoring stores ppq = round(apply(round(r * ppqPerRow))) for some
-- integer row r. Inverting that round-trip via unapply is ε-lossy: a
-- 0.5-PPQ rounding error in apply-space lands as ε/slope in intent-
-- space, and on steep apply segments (extreme atoms, multi-atom
-- composites) the drift can cross the half-row boundary — so the
-- nearest-row guess from unapply is no longer trustworthy.
--
-- Recover the row by direct round-trip test from a starting hint,
-- walking outward until apply lands further than `tolPPQ` from `ppq`
-- (apply is monotone, so once past tolerance no further r will hit).
-- Returns r on hit, nil if no integer row produces this realised ppq.
function M.recoverAuthoredRow(apply, ppqPerRow, ppq, hint, tolPPQ)
  tolPPQ = tolPPQ or 0.5
  local function tryRow(r) return util.round(apply(util.round(r * ppqPerRow))) end
  if tryRow(hint) == ppq then return hint end
  local upDone, downDone = false, false
  for d = 1, 64 do
    if not downDone then
      local p = tryRow(hint - d)
      if p == ppq then return hint - d end
      if p < ppq - tolPPQ then downDone = true end
    end
    if not upDone then
      local p = tryRow(hint + d)
      if p == ppq then return hint + d end
      if p > ppq + tolPPQ then upDone = true end
    end
    if upDone and downDone then return nil end
  end
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
