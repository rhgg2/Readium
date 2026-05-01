-- Pins the contract that hiding an extra note column only succeeds at
-- the topmost lane. Lane is rebuild-only at tm (assignNote rejects
-- writes), so interior holes can't be closed by shifting higher lanes
-- down — a previous version tried and silently failed (the column
-- reappeared on the next rebuild). Now the operation refuses cleanly,
-- and the user hides from the right inwards.

local t = require('support')

return {

  {
    name = 'hideExtraCol on topmost empty note lane shrinks extraColumns',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 1 },
          },
        },
        config = { take = { extraColumns = { [1] = { notes = 2 } } } },
      }
      h.vm:setGridSize(80, 40)

      -- chan 1 lane 1 (has the note) is grid.cols[1]; lane 2 (empty) is [2].
      local laneCol2 = h.vm.grid.cols[2]
      t.eq(laneCol2.lane, 2,            'grid.cols[2] is chan 1 lane 2')
      t.eq(#laneCol2.events, 0,         'lane 2 is empty')

      h.ec:setPos(0, 2, 1)
      h.vm:hideExtraCol()

      local extras = h.cm:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 1,
           'extraColumns notes count dropped from 2 to 1')

      local laneCols = {}
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then
          util.add(laneCols, c)
        end
      end
      t.eq(#laneCols, 1,                'only one note col left on chan 1')
      t.eq(#laneCols[1].events, 1,      'the seeded note survived')
    end,
  },

  {
    name = 'hideExtraCol on interior empty note lane is a no-op',
    run = function(harness)
      -- Lane 1 empty, lane 2 holds the note. Hiding lane 1 would have
      -- to shift lane 2 down — but lane is rebuild-only. Refuse.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 2 },
          },
        },
        config = { take = { extraColumns = { [1] = { notes = 2 } } } },
      }
      h.vm:setGridSize(80, 40)

      local laneCol1 = h.vm.grid.cols[1]
      t.eq(laneCol1.lane, 1,            'grid.cols[1] is chan 1 lane 1')
      t.eq(#laneCol1.events, 0,         'lane 1 is empty')

      h.ec:setPos(0, 1, 1)
      h.vm:hideExtraCol()

      local extras = h.cm:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 2,
           'extraColumns unchanged — interior hide refused')

      local laneCols = {}
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then
          util.add(laneCols, c)
        end
      end
      t.eq(#laneCols, 2,                'still two note cols on chan 1')
      local lane2 = laneCols[2]
      t.eq(#lane2.events, 1,            'note still in lane 2')
      t.eq(lane2.events[1].pitch, 60,   'note unchanged')
    end,
  },

}
