-- Exercises tm's swing transforms via swingSnapshot (the sole public
-- swing entry point). Contract: apply/unapply are inverses; missing
-- slots pass through; column is inner and global is outer (see
-- design/swing.md).

local t = require('support')

local classic58 = { { atom = 'classic', amount = 0.08, period = 1 } }
local classic67 = { { atom = 'classic', amount = 0.17, period = 1 } }

return {
  {
    name = 'no slot configured ⇒ apply is identity',
    run = function(harness)
      local h = harness.mk()
      local snap = h.tm:swingSnapshot()
      for _, p in ipairs{ 0, 60, 120, 240, 480, 961 } do
        t.eq(snap.apply(1, p), p, 'apply at ' .. p)
        t.eq(snap.unapply(1, p), p, 'unapply at ' .. p)
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
      t.eq(snap.apply(1, 0),   0,   'origin fixed')
      t.eq(snap.apply(1, 240), 240, 'period boundary fixed')
      t.eq(snap.apply(1, 480), 480, 'two periods in, still fixed')
      -- Mid-period maps to 0.58 of the period = 139.2.
      local mid = snap.apply(1, 120)
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
        local round = snap.unapply(1, snap.apply(1, p))
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
      t.eq(snap.apply(1, 120), 120, 'chan 1 unswung')
      local c2 = snap.apply(2, 120)
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
      -- At ppq=120: column first pulls to 0.67 * 240 = 160.8, then global
      -- classic-58 applied to that: t = 160.8/240 = 0.67; S_58(0.67)?
      -- classic(0.08) is piecewise-linear {{0,0},{0.5,0.58},{1,1}} — at
      -- x=0.67 the slope is (1-0.58)/(1-0.5) = 0.84, so
      -- y = 0.58 + 0.84 * (0.67 - 0.5) = 0.58 + 0.1428 = 0.7228; tile=173.472.
      local got = snap.apply(1, 120)
      local expected = 240 * (0.58 + ((1 - 0.58) / (1 - 0.5)) * (160.8/240 - 0.5))
      t.truthy(math.abs(got - expected) < 1e-6,
        'composed swing mismatch: got ' .. tostring(got) .. ', expected ' .. tostring(expected))

      -- And inversion still round-trips.
      local round = snap.unapply(1, got)
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
      t.eq(h.tm:swingSnapshot().apply(1, 120), 120, 'unknown slot name passes through')
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
      t.eq(h.tm:swingSnapshot().apply(1, 120), 120, 'empty composite is identity')
    end,
  },
}
