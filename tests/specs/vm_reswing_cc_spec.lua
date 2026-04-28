-- Reswing under per-event frame metadata. Each CC/PB/AT/PC/PA carries
-- the frame it was authored in; reswing reads that frame directly,
-- rather than borrowing one from a lane-1 note nearby.

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }
local classic67 = { { atom = 'classic', shift = 0.17, period = 1 } }

local function findCC(dump, msgType, chan)
  for _, c in ipairs(dump.ccs) do
    if c.msgType == msgType and (chan == nil or c.chan == chan) then return c end
  end
end

return {
  {
    name = 'CC authored under c58 reswings to identity using its straightPPQ',
    run = function(harness)
      -- Row 2 in rpb=4 has straight ppq 120; under c58 that lands at 139.
      -- Reswing target = identity, so the realised ppq returns to 120.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, straightPPQ = 120,
              chan = 2, msgType = 'cc', cc = 1, val = 64,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = nil, rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.truthy(cc, 'cc survives reswing')
      t.eq(cc.ppq, 120, 'cc reswung to identity-frame intent ppq=120')
    end,
  },

  {
    name = 'CC without a frame is skipped by reswing',
    run = function(harness)
      -- No frame metadata → reswing has no auth to invert; leaves it alone.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, chan = 2, msgType = 'cc', cc = 1, val = 64 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.eq(cc.ppq, 139, 'frameless cc untouched')
    end,
  },

  {
    name = 'reswing restamps cc.frame to the current frame',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, straightPPQ = 120,
              chan = 2, msgType = 'cc', cc = 1, val = 64,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
          take    = { swing = 'c67', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.eq(cc.frame.swing, 'c67', 'frame restamped to current swing')
      t.eq(cc.frame.rpb,   4,     'frame restamped rpb')
    end,
  },

  {
    name = 'tm:addEvent does NOT auto-stamp frame (vm/ec own that responsibility)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 8 },
        },
      }
      h.tm:addEvent('cc', { ppq = 0, chan = 3, cc = 7, val = 100 })
      h.tm:flush()
      local cc = findCC(h.fm:dump(), 'cc', 3)
      t.truthy(cc, 'cc landed')
      t.eq(cc.frame, nil, 'tm did not stamp frame — caller must do it')
    end,
  },

  {
    name = 'vm:editEvent on a cc column stamps the current frame',
    run = function(harness)
      local h = harness.mk{
        seed = {
          -- Existing cc to materialise a cc=11 column on chan 1.
          ccs = { { ppq = 0, chan = 1, msgType = 'cc', cc = 11, val = 0 } },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 8 },
        },
      }
      h.vm:setGridSize(80, 40)

      local ccCol
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 11 then ccCol = col end
      end
      t.truthy(ccCol, 'cc=11 column present')

      -- Author a new cc one row down (row 1 = ppq 30 under rpb=8).
      h.ec:setPos(1, 1, 1)
      -- Find the col index for ccCol.
      local ccColIdx
      for i, col in ipairs(h.vm.grid.cols) do
        if col == ccCol then ccColIdx = i end
      end
      h.ec:setPos(1, ccColIdx, 1)
      h.vm:editEvent(ccCol, nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'cc' and c.cc == 11 and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh and fresh.frame, 'authored cc carries a frame')
      t.eq(fresh.frame.swing, 'c58', 'frame.swing matches cm')
      t.eq(fresh.frame.rpb,   8,     'frame.rpb matches cm')
    end,
  },

  {
    name = 'PB reswung twice: straightPPQ + frame survive the first pass',
    run = function(harness)
      -- assignPb's ppq-change path delete-and-re-adds the pb. If the new
      -- pb doesn't inherit straightPPQ/frame, the *next* reswing reads
      -- straightPPQ=nil and tile() / round() blow up.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, straightPPQ = 120,
              chan = 2, msgType = 'pb', val = 0,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = nil, rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()
      h.vm:reswingAll()

      local pb = findCC(h.fm:dump(), 'pb', 2)
      t.truthy(pb, 'pb survives both reswings')
      t.eq(pb.ppq, 120, 'pb at identity-frame intent ppq=120')
      t.eq(pb.straightPPQ, 120, 'straightPPQ preserved across reswing')
      t.truthy(pb.frame, 'frame preserved across reswing')
    end,
  },

  {
    name = 'CC frame metadata surfaces on tm column events after rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60, chan = 1, msgType = 'cc', cc = 11, val = 50,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      local ch  = h.tm:getChannel(1)
      local col = ch.columns.ccs[11]
      t.truthy(col and col.events[1], 'cc column event present')
      t.eq(col.events[1].frame.swing, 'c58',
           'cc.frame propagated from mm onto tm column event')
    end,
  },
}
