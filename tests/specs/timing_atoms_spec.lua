-- Pin the shift semantics: composite factors carry `shift` in QN, and
-- materialise/applyFactors consume it via a = shift / atomTilePeriod(f).
-- The drop-in invariant: at fixed period, the principal pulse-breakpoint
-- of pulse 1 lands at (nominal_input + shift) regardless of atom
-- (classic, arc, pocket, lilt, shuffle, tilt). Drag is the documented
-- exception.

local t = require('support')
require('util')
require('timing')

-- Build the realised factor list the way the editor and tm do.
local function realise(composite, ppqPerQN)
  ppqPerQN = ppqPerQN or 1
  local out = {}
  for i, f in ipairs(composite) do
    local T = timing.atomTilePeriod(f)
    out[i] = { S = timing.atoms[f.atom](f.shift / T), T = T * ppqPerQN }
  end
  return out
end

-- Where pulse 1's principal breakpoint sits, in user-pulse units (QN).
local pulse1PrincipalQN = {
  classic = function(P) return 0.5 * P end,
  arc     = function(P) return 0.5 * P end,
  pocket  = function(P) return 0.5 * P end,
  lilt    = function(P) return 0.5 * P end,
  shuffle = function(P) return (2/3) * P end,
  tilt    = function(P) return (1/3) * P end,
}

return {
  {
    name = 'atomTilePeriod doubles for lilt, passes through for the rest',
    run = function()
      t.eq(timing.atomTilePeriod{ atom = 'classic', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'drag',    shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'arc',     shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'pocket',  shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'shuffle', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'tilt',    shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 1 }, 2)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 3 }, 6)
    end,
  },

  {
    name = 'principal pulse-1 breakpoint lands at nominal + shift, atom-independent',
    run = function()
      for _, atom in ipairs{ 'classic', 'arc', 'pocket', 'lilt',
                             'shuffle', 'tilt' } do
        for _, P in ipairs{ 1, 2, 4 } do
          for _, shift in ipairs{ 0.05, 0.10 } do
            local factors = realise({ { atom = atom, shift = shift, period = P } })
            local nominal = pulse1PrincipalQN[atom](P)
            local got     = timing.applyFactors(factors, nominal)
            local want    = nominal + shift
            t.truthy(math.abs(got - want) < 1e-9,
              atom .. ' P=' .. P .. ' shift=' .. shift ..
              ': principal landed at ' .. tostring(got) .. ', want ' .. tostring(want))
          end
        end
      end
    end,
  },

  {
    name = 'shift is period-decoupled: same shift, different periods, both land shift away',
    run = function()
      -- Same atom (classic), shift=0.1qn, periods 1 and 4. The unit-square
      -- amounts differ (0.1 vs 0.025) but the absolute pulse-1 principal
      -- displacement is 0.1qn in both cases.
      local f1 = realise({ { atom = 'classic', shift = 0.1, period = 1 } })
      local f4 = realise({ { atom = 'classic', shift = 0.1, period = 4 } })
      t.truthy(math.abs(timing.applyFactors(f1, 0.5) - 0.6) < 1e-9, 'P=1')
      t.truthy(math.abs(timing.applyFactors(f4, 2.0) - 2.1) < 1e-9, 'P=4')
    end,
  },

  {
    name = 'classic-58 preset matches the legacy 0.58 mapping',
    run = function()
      -- The seed preset value has not drifted: shift=0.08 at period=1
      -- still maps the half-period to 0.58 (matches tm_swing_spec).
      local factors = realise(timing.presets['classic-58'])
      t.truthy(math.abs(timing.applyFactors(factors, 0.5) - 0.58) < 1e-9)
    end,
  },

  {
    name = 'pocket and classic agree at the principal, disagree off it',
    run = function()
      -- The drop-in property: at the same period, pocket and classic put
      -- the principal in the same place. Off the principal, pocket's
      -- flat-top plateau diverges from classic's sharp tent — the
      -- interior shape differs even when the principals coincide.
      local fc = realise({ { atom = 'classic', shift = 0.1, period = 1 } })
      local fp = realise({ { atom = 'pocket',  shift = 0.1, period = 1 } })
      local gotC = timing.applyFactors(fc, 0.5)
      local gotP = timing.applyFactors(fp, 0.5)
      t.truthy(math.abs(gotC - gotP) < 1e-9,
        'principal: classic→' .. tostring(gotC) .. ' vs pocket→' .. tostring(gotP))
      -- At x=0.25 classic is on its first ramp (0.5+0.1)·0.5 = 0.3,
      -- pocket's plateau already lifts it close to 0.25+0.0984 ≈ 0.3484.
      local offC = timing.applyFactors(fc, 0.25)
      local offP = timing.applyFactors(fp, 0.25)
      t.truthy(math.abs(offC - offP) > 0.01,
        'interiors should differ at x=0.25: classic→' .. tostring(offC) ..
        ' vs pocket→' .. tostring(offP))
    end,
  },

  {
    name = 'smooth atoms produce densely-sampled shapes, PWL stays sparse',
    -- Structural pin: smooth-by-sampling means the shape carries many
    -- control points, where the PWL counterparts have only a handful.
    run = function()
      for _, name in ipairs{ 'arc', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        t.truthy(#timing.atoms[name](0.05) > 100,
          name .. ' should be densely sampled')
      end
      for _, name in ipairs{ 'classic', 'drag' } do
        t.truthy(#timing.atoms[name](0.05) <= 5,
          name .. ' should stay sparse')
      end
    end,
  },

  {
    name = 'smooth atoms are monotone strictly inside their documented range',
    -- Sample-at-boundary slope hits 0; test slightly inside (95% of range)
    -- and verify every sample step is strictly increasing.
    run = function()
      for _, name in ipairs{ 'arc', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        local a = 0.95 * timing.atomMeta[name].range
        local S = timing.atoms[name](a)
        for i = 2, #S do
          t.truthy(S[i][2] > S[i-1][2],
            name .. ' non-monotone at i=' .. i ..
            ': ' .. S[i-1][2] .. ' → ' .. S[i][2])
        end
      end
    end,
  },

  {
    name = 'identity atom: shift is meaningless, output passes through',
    run = function()
      local factors = realise({ { atom = 'id', shift = 0, period = 1 } })
      for _, p in ipairs{ 0, 0.25, 0.5, 0.99, 1.0, 1.25 } do
        t.truthy(math.abs(timing.applyFactors(factors, p) - p) < 1e-9)
      end
    end,
  },

  ---------- straightPPQPerRow

  {
    name = 'straightPPQPerRow gives 60 PPQ for default rpb=4 / 4/4 / res=240',
    run = function()
      t.eq(timing.straightPPQPerRow(4, 4, 240), 60)
    end,
  },

  {
    name = 'straightPPQPerRow handles non-divisor rpbs (returns float)',
    run = function()
      local v = timing.straightPPQPerRow(7, 4, 240)
      t.truthy(math.abs(v - 240/7) < 1e-12, 'rpb=7: ' .. tostring(v))
    end,
  },
}
