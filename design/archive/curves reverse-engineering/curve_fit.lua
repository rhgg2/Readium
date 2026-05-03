-- Fit candidate formulas to recorded curve samples.
-- Usage: lua curve_fit.lua

local SEGMENT_PPQ = 3840  -- overwritten from manifest.csv
local MAX_VAL = 127       -- overwritten from manifest.csv if a max_val column is present

local function readManifest(path)
  local f = io.open(path, 'r')
  if not f then return end
  local header
  for line in f:lines() do
    if not header then
      header = {}
      local i = 1
      for col in line:gmatch('[^,]+') do header[col] = i; i = i + 1 end
    else
      local cols, i = {}, 1
      for col in line:gmatch('[^,]+') do cols[i] = col; i = i + 1 end
      SEGMENT_PPQ = tonumber(cols[header.segment_ppq]) or SEGMENT_PPQ
      if header.max_val then
        MAX_VAL = tonumber(cols[header.max_val]) or MAX_VAL
      end
      break
    end
  end
  f:close()
end

local function readCsv(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local rows = {}
  local header = true
  for line in f:lines() do
    if header then header = false
    else
      local ppq, val = line:match('^([%-%d%.]+),([%-%d%.]+)$')
      if ppq then rows[#rows+1] = { t = tonumber(ppq)/SEGMENT_PPQ, y = tonumber(val)/MAX_VAL } end
    end
  end
  f:close()
  return rows
end

readManifest('design/curve_samples/manifest.csv')
print(('(SEGMENT_PPQ = %d, MAX_VAL = %d → quantisation floor ≈ %.5f)'):format(
  SEGMENT_PPQ, MAX_VAL, (1/MAX_VAL)/math.sqrt(12)))

-- SSE between a candidate y-function and the samples.
local function sse(rows, f)
  local s = 0
  for _, r in ipairs(rows) do
    local d = f(r.t) - r.y
    s = s + d*d
  end
  return s
end

-- Report best candidate from a named list.
local function pickBest(name, rows, candidates)
  print(('=== %s (%d samples) ==='):format(name, #rows))
  local best, bestErr
  local results = {}
  for _, c in ipairs(candidates) do
    local err = sse(rows, c.f)
    results[#results+1] = { label = c.label, err = err }
    if not bestErr or err < bestErr then bestErr, best = err, c end
  end
  table.sort(results, function(a, b) return a.err < b.err end)
  for _, r in ipairs(results) do
    print(('  %-30s SSE=%.6f  RMSE=%.5f'):format(r.label, r.err, math.sqrt(r.err/#rows)))
  end
  return best
end

-- ---------- linear / step / slow / fast-* ----------

local shapes = {
  step = {
    { label = 'step at 1.0',  f = function(t) return t >= 1 and 1 or 0 end },
  },
  linear = {
    { label = 'y = t',        f = function(t) return t end },
  },
  slow = {
    { label = '3t^2 - 2t^3',  f = function(t) return 3*t*t - 2*t*t*t end },
    { label = '6t^5-15t^4+10t^3', f = function(t) return t*t*t*(t*(t*6-15)+10) end },
    { label = '0.5-0.5cos(pi t)', f = function(t) return 0.5 - 0.5*math.cos(math.pi*t) end },
  },
  ['fast-start'] = {
    { label = '1-(1-t)^2',    f = function(t) return 1 - (1-t)^2 end },
    { label = '1-(1-t)^3',    f = function(t) return 1 - (1-t)^3 end },
    { label = 'sqrt(t)',      f = function(t) return math.sqrt(t) end },
    { label = 'sin(pi t/2)',  f = function(t) return math.sin(math.pi*t/2) end },
  },
  ['fast-end'] = {
    { label = 't^2',          f = function(t) return t*t end },
    { label = 't^3',          f = function(t) return t*t*t end },
    { label = '1-cos(pi t/2)', f = function(t) return 1 - math.cos(math.pi*t/2) end },
  },
}

for name, cands in pairs(shapes) do
  local rows = readCsv(('design/curve_samples/%s.csv'):format(name))
  if rows then pickBest(name, rows, cands) end
end

-- ---------- bezier ----------

-- Cubic bezier at parameter s with controls (0,0),(ax,ay),(bx,by),(1,1).
local function bez(s, ax, ay, bx, by)
  local u = 1-s
  local w0 = u*u*u
  local w1 = 3*s*u*u
  local w2 = 3*s*s*u
  local w3 = s*s*s
  -- P0 = (0,0), P3 = (1,1) so:
  return w1*ax + w2*bx + w3, w1*ay + w2*by + w3
end

-- For a given control-point set, evaluate y at target x by dense sampling + linear interp.
local function makeBezFn(ax, ay, bx, by, N)
  N = N or 2000
  local xs, ys = {}, {}
  for i = 0, N do
    local s = i/N
    local x, y = bez(s, ax, ay, bx, by)
    xs[i+1], ys[i+1] = x, y
  end
  return function(t)
    -- binary search for the segment whose x straddles t
    local lo, hi = 1, #xs
    while hi - lo > 1 do
      local mid = (lo + hi) // 2
      if xs[mid] <= t then lo = mid else hi = mid end
    end
    local dx = xs[hi] - xs[lo]
    if dx < 1e-12 then return ys[lo] end
    local f = (t - xs[lo]) / dx
    return ys[lo] + f * (ys[hi] - ys[lo])
  end
end

-- Coarse-to-fine search for (ax, ay, bx, by) minimising SSE.
local function fitBezier(rows)
  local bestErr, bestP = math.huge, nil
  -- coarse grid
  local step = 0.1
  local ax, ay, bx, by
  for A = 0, 1, step do
    for B = 0, 1, step do
      for C = 0, 1, step do
        for D = 0, 1, step do
          local f = makeBezFn(A, B, C, D, 400)
          local err = sse(rows, f)
          if err < bestErr then bestErr, bestP = err, { A, B, C, D } end
        end
      end
    end
  end
  -- refine
  for _ = 1, 6 do
    step = step * 0.4
    local A0, B0, C0, D0 = bestP[1], bestP[2], bestP[3], bestP[4]
    for dA = -2, 2 do
      for dB = -2, 2 do
        for dC = -2, 2 do
          for dD = -2, 2 do
            local A = math.max(0, math.min(1, A0 + dA*step))
            local B = math.max(0, math.min(1, B0 + dB*step))
            local C = math.max(0, math.min(1, C0 + dC*step))
            local D = math.max(0, math.min(1, D0 + dD*step))
            local f = makeBezFn(A, B, C, D, 1000)
            local err = sse(rows, f)
            if err < bestErr then bestErr, bestP = err, { A, B, C, D } end
          end
        end
      end
    end
  end
  return bestP, bestErr
end

-- Diagnostic: is the tau=0→0.25 jump in control points real, or a local min?
-- Cross-evaluate tau=0's clean fit (0.25, 0.125, 0.75, 0.875) on tau=0.25 data
-- and compare against the fitted tau=0.25 params.
print()
print('=== cross-check: how well does tau=0 fit each curve? ===')
for _, tau in ipairs({ 0.00, 0.30, 0.50, 0.70 }) do
  local name = ('bezier_%.2f'):format(tau)
  local rows = readCsv(('design/curve_samples/%s.csv'):format(name))
  if rows then
    local f = makeBezFn(0.25, 0.125, 0.75, 0.875, 2000)
    print(('  %s using (1/4,1/8,3/4,7/8): RMSE=%.5f'):format(name, math.sqrt(sse(rows, f)/#rows)))
  end
end

print()
print('=== bezier fits (free 4-param) ===')
print(('%-18s %8s %8s %8s %8s  %10s'):format('tension', 'ax', 'ay', 'bx', 'by', 'RMSE'))
local tensions = {}
for i = -10, 10 do tensions[#tensions+1] = i / 10 end
local freeFits = {}
for _, tau in ipairs(tensions) do
  local name = ('bezier_%.2f'):format(tau)
  local rows = readCsv(('design/curve_samples/%s.csv'):format(name))
  if rows then
    local p, err = fitBezier(rows)
    freeFits[tau] = { p = p, rmse = math.sqrt(err/#rows) }
    print(('%-18s %8.4f %8.4f %8.4f %8.4f  %10.5f'):format(name, p[1], p[2], p[3], p[4], math.sqrt(err/#rows)))
  end
end

-- Canonical-form fit: constrain h1 = h2 (equal handle tangent magnitudes).
-- Parameterise by (h, θ1, θ2):
--   P1 = (h·cosθ1, h·sinθ1),  P2 = (1 − h·cosθ2, 1 − h·sinθ2)
-- θ1 is the tangent angle at P0 (0 = horizontal, π/2 = vertical),
-- θ2 is the tangent angle at P3 (same convention).
-- Holds exactly at τ=0 and τ=±1. For intermediate τ the fit forces a
-- different cubic Bézier whose y(x) approximates the actual curve.
local function makeBezFromHTheta(h, t1, t2, N)
  return makeBezFn(h*math.cos(t1), h*math.sin(t1), 1 - h*math.cos(t2), 1 - h*math.sin(t2), N)
end

local function fitCanonical(rows)
  local bestErr, bestP = math.huge, nil
  -- Coarse grid
  for h = 0.1, 1.2, 0.1 do
    for t1 = 0, math.pi/2, math.pi/20 do
      for t2 = 0, math.pi/2, math.pi/20 do
        local err = sse(rows, makeBezFromHTheta(h, t1, t2, 400))
        if err < bestErr then bestErr, bestP = err, { h, t1, t2 } end
      end
    end
  end
  -- Refine
  local sh, st = 0.05, math.pi/40
  for _ = 1, 10 do
    local h0, a0, b0 = bestP[1], bestP[2], bestP[3]
    for dh = -3, 3 do
      for da = -3, 3 do
        for db = -3, 3 do
          local h  = math.max(0, h0 + dh*sh)
          local t1 = math.max(0, math.min(math.pi/2, a0 + da*st))
          local t2 = math.max(0, math.min(math.pi/2, b0 + db*st))
          local err = sse(rows, makeBezFromHTheta(h, t1, t2, 1000))
          if err < bestErr then bestErr, bestP = err, { h, t1, t2 } end
        end
      end
    end
    sh, st = sh*0.5, st*0.5
  end
  return bestP, bestErr
end

print()
print('=== bezier fits (canonical h1 = h2) ===')
print(('%-18s %8s %8s %8s  |  %8s %8s %8s %8s  %10s  %8s'):format(
  'tension', 'h', 'θ1(deg)', 'θ2(deg)', 'ax', 'ay', 'bx', 'by', 'RMSE', 'Δ vs free'))
for _, tau in ipairs(tensions) do
  local name = ('bezier_%.2f'):format(tau)
  local rows = readCsv(('design/curve_samples/%s.csv'):format(name))
  if rows then
    local p, err = fitCanonical(rows)
    local h, t1, t2 = p[1], p[2], p[3]
    local ax, ay = h*math.cos(t1), h*math.sin(t1)
    local bx, by = 1 - h*math.cos(t2), 1 - h*math.sin(t2)
    local rmse = math.sqrt(err/#rows)
    local freeR = freeFits[tau] and freeFits[tau].rmse or 0
    print(('%-18s %8.4f %8.2f %8.2f  |  %8.4f %8.4f %8.4f %8.4f  %10.5f  %+8.5f'):format(
      name, h, math.deg(t1), math.deg(t2), ax, ay, bx, by, rmse, rmse - freeR))
  end
end
