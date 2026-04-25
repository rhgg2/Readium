-- Exercises the transient-tier frame override: matchGridToCursor toggles
-- swing/colSwing/rowPerBeat at cm's transient level; a real edit on any
-- of those keys at a persisted level releases the override.

local t = require('support')

local classic = { { atom = 'classic', amount = 0.08, period = 1 } }

return {
  {
    name = 'matchGridToCursor writes the cursor-note frame to the transient tier',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              frame = { swing = 'c58', colSwing = nil, rpb = 8 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic } },
          take    = { swing = nil, rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Place cursor on the note (chan 1, lane 1, row 0, stop 1).
      h.ec:setPos(0, 1, 1)

      h.cmgr.commands.matchGridToCursor()

      t.eq(h.cm:getAt('transient', 'swing'),      'c58', 'swing pushed to transient')
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), 8,     'rowPerBeat pushed to transient')
      t.eq(h.cm:get('rowPerBeat'),                8,     'merged read sees transient rpb')
    end,
  },

  {
    name = 'matchGridToCursor toggle-off clears the transient frame keys',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              frame = { swing = 'c58', colSwing = nil, rpb = 8 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic } },
          take    = { rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)

      h.cmgr.commands.matchGridToCursor()
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), 8, 'override active')

      h.cmgr.commands.matchGridToCursor()
      t.eq(h.cm:getAt('transient', 'swing'),      nil, 'swing cleared')
      t.eq(h.cm:getAt('transient', 'colSwing'),   nil, 'colSwing cleared')
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), nil, 'rowPerBeat cleared')
      t.eq(h.cm:get('rowPerBeat'),                4,   'merged read falls back to take')
    end,
  },

  {
    name = 'a real edit on a frame key while transient is active releases it',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic } },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Pretend matchGridToCursor stamped this; we only care about the
      -- callback contract, not the toggle path.
      h.cm:assign('transient', { swing = 'c58', rowPerBeat = 8 })
      t.eq(h.cm:get('rowPerBeat'), 8, 'transient is in effect')

      -- A user-side rpb change (vm:setRowPerBeat writes to 'track').
      h.cm:set('track', 'rowPerBeat', 16)

      t.eq(h.cm:getAt('transient', 'swing'),      nil, 'transient swing dropped')
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), nil, 'transient rpb dropped')
      t.eq(h.cm:get('rowPerBeat'),                16,  'user value visible')
    end,
  },

  {
    name = 'vm:setRowPerBeat under an active transient override does not double-rescale ec',
    run = function(harness)
      -- ec:rescaleRow is integer floor of cursorRow*newRPB/oldRPB.
      -- If the override path double-rescales (transient.rpb=8 → user n=16
      -- once, then 8→16 again on release), cursor row 4 ends up at 16
      -- instead of 8. Pin the single-rescale invariant.
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic } },
        },
      }
      h.vm:setGridSize(80, 40)
      h.cm:assign('transient', { swing = 'c58', rowPerBeat = 8 })
      -- Place cursor at row 4 (in rpb=8). Halving expected to land row 2.
      h.ec:setPos(4, 1, 1)
      t.eq(h.ec:row(), 4, 'cursor at row 4 under rpb=8')

      h.vm:setRowPerBeat(4)
      t.eq(h.cm:get('rowPerBeat'),                4,   'cm rowPerBeat is the user value')
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), nil, 'transient rpb dropped')
      t.eq(h.ec:row(), 2, 'cursor rescaled from 4 (in rpb=8) to 2 (in rpb=4) — single rescale')
    end,
  },

  {
    name = 'cm:set at the transient tier does NOT trigger self-release',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic } },
        },
      }
      h.vm:setGridSize(80, 40)
      h.cm:assign('transient', { swing = 'c58', rowPerBeat = 8 })
      -- A subsequent transient-level write must survive — only non-transient
      -- writes should release the override.
      h.cm:set('transient', 'rowPerBeat', 16)
      t.eq(h.cm:getAt('transient', 'rowPerBeat'), 16, 'transient write preserved')
      t.eq(h.cm:getAt('transient', 'swing'),      'c58', 'transient swing preserved')
    end,
  },
}
