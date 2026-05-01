-- Exercises tm's swing transforms via swingSnapshot (the sole public
-- swing entry point). Contract: apply/unapply are inverses; missing
-- slots pass through; column is inner and global is outer (see
-- design/swing.md).

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }
local classic67 = { { atom = 'classic', shift = 0.17, period = 1 } }

return {
  {
    name = 'no slot configured ⇒ apply is identity',
    run = function(harness)
      local h = harness.mk()
      local snap = h.tm:swingSnapshot()
      for _, p in ipairs{ 0, 60, 120, 240, 480, 961 } do
        t.eq(snap.fromLogical(1, p), p, 'fromLogical at ' .. p)
        t.eq(snap.toLogical(1, p), p, 'toLogical at ' .. p)
      end
    end,
  },

  {
    name = 'global classic-58 fixes period boundaries and bows the interior',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      local snap = h.tm:swingSnapshot()
      -- 240 ppq/QN, period 1 QN = 240 ppq. Boundaries are fixed.
      t.eq(snap.fromLogical(1, 0),   0,   'origin fixed')
      t.eq(snap.fromLogical(1, 240), 240, 'period boundary fixed')
      t.eq(snap.fromLogical(1, 480), 480, 'two periods in, still fixed')
      -- Mid-period maps to 0.58 of the period = 139.2.
      local mid = snap.fromLogical(1, 120)
      t.truthy(math.abs(mid - 139.2) < 1e-9, 'mid-period maps to ~139.2, got ' .. tostring(mid))
    end,
  },

  {
    name = 'apply and unapply are inverses',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      local snap = h.tm:swingSnapshot()
      for _, p in ipairs{ 0, 30, 60, 119, 120, 121, 240, 361, 480, 961 } do
        local round = snap.toLogical(1, snap.fromLogical(1, p))
        t.truthy(math.abs(round - p) < 1e-9,
          'round-trip at ppq=' .. p .. ' gave ' .. tostring(round))
      end
    end,
  },

  {
    name = 'colSwing applies only to the named channel',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c67'] = classic67 } },
          take    = { colSwing = { [2] = 'c67' } },
        },
      }
      local snap = h.tm:swingSnapshot()
      t.eq(snap.fromLogical(1, 120), 120, 'chan 1 unswung')
      local c2 = snap.fromLogical(2, 120)
      t.truthy(math.abs(c2 - 0.67 * 240) < 1e-9,
        'chan 2 mid-period maps to 0.67 of period, got ' .. tostring(c2))
    end,
  },

  {
    name = 'column is inner, global is outer (order matters)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
          take    = { swing = 'c58', colSwing = { [1] = 'c67' } },
        },
      }
      local snap = h.tm:swingSnapshot()

      -- Compose by hand using the same factor build tm uses, so the
      -- ordering pin doesn't depend on the closed form of the active atom.
      local function factors(comp)
        local f = {}
        for i, x in ipairs(comp) do
          local T = timing.atomTilePeriod(x)
          f[i] = { S = timing.atoms[x.atom](x.shift / T),
                   T = T * h.tm:resolution() }
        end
        return f
      end
      local fc58, fc67 = factors(classic58), factors(classic67)
      local colInner = timing.applyFactors(fc58, timing.applyFactors(fc67, 120))
      local colOuter = timing.applyFactors(fc67, timing.applyFactors(fc58, 120))

      local got = snap.fromLogical(1, 120)
      t.truthy(math.abs(got - colInner) < 1e-9,
        'snap matches column-inner ordering: got ' .. tostring(got)
        .. ', column-then-global = ' .. tostring(colInner))
      t.truthy(math.abs(colInner - colOuter) > 1e-6,
        'orders should produce distinguishable results: ' ..
        tostring(colInner) .. ' vs ' .. tostring(colOuter))

      -- Inversion still round-trips.
      local round = snap.toLogical(1, got)
      t.truthy(math.abs(round - 120) < 1e-9, 'composed round-trip failed: ' .. tostring(round))
    end,
  },

  {
    name = 'missing slot name falls back to identity',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          -- Slot name not in the lib.
          take    = { swing = 'mysterious' },
        },
      }
      t.eq(h.tm:swingSnapshot().fromLogical(1, 120), 120, 'unknown slot name passes through')
    end,
  },

  {
    name = 'identity composite (empty array) acts as pass-through',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['id'] = {} } },
          take    = { swing = 'id' },
        },
      }
      t.eq(h.tm:swingSnapshot().fromLogical(1, 120), 120, 'empty composite is identity')
    end,
  },
}
