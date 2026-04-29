-- Pin the shift semantics: composite factors carry `shift` in QN, and
-- materialise/applyFactors consume it via a = shift / atomTilePeriod(f).
-- The shift invariant: at fixed period, the atom's principal lands at
-- (nominal + shift) for every atom (classic, pocket, lilt, shuffle, tilt).

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

-- Where the atom's principal sits, in QN. For PPC=1 atoms this is the
-- principal feature within pulse 1; for PPC=2 atoms it sits at unit-x=0.5
-- of the tile, which maps to qn = T·0.5 = P (the user-period boundary
-- for pocket; mid-pulse for lilt because lilt's peak is at unit-x=0.25).
local principalQN = {
  classic = function(P) return 0.5 * P end,
  pocket  = function(P) return P end,
  lilt    = function(P) return 0.5 * P end,
  shuffle = function(P) return (2/3) * P end,
  tilt    = function(P) return (1/3) * P end,
}

return {
  {
    name = 'atomTilePeriod doubles for lilt and pocket, passes through for the rest',
    run = function()
      t.eq(timing.atomTilePeriod{ atom = 'classic', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'shuffle', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'tilt',    shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 1 }, 2)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 3 }, 6)
      t.eq(timing.atomTilePeriod{ atom = 'pocket',  shift = 0, period = 1 }, 2)
      t.eq(timing.atomTilePeriod{ atom = 'pocket',  shift = 0, period = 3 }, 6)
    end,
  },

  {
    name = 'principal lands at nominal + shift, atom-independent',
    run = function()
      for _, atom in ipairs{ 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        for _, P in ipairs{ 1, 2, 4 } do
          for _, shift in ipairs{ 0.05, 0.10 } do
            local factors = realise({ { atom = atom, shift = shift, period = P } })
            local nominal = principalQN[atom](P)
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
    name = 'smooth atoms produce densely-sampled shapes, id stays sparse',
    -- Structural pin: smooth-by-sampling means the shape carries many
    -- control points; id is the lone PWL atom and stays a 2-point line.
    run = function()
      for _, name in ipairs{ 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        t.truthy(#timing.atoms[name](0.05) > 100,
          name .. ' should be densely sampled')
      end
      t.truthy(#timing.atoms.id(0.05) <= 5, 'id should stay sparse')
    end,
  },

  {
    name = 'smooth atoms are monotone strictly inside their documented range',
    -- Sample-at-boundary slope hits 0; test slightly inside (95% of range)
    -- and verify every sample step is strictly increasing.
    run = function()
      for _, name in ipairs{ 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' } do
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
