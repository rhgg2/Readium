-- Pins the straightPPQ invariant across vm's authoring + editing paths.
--
-- Storage model: every event stamped under a frame carries straightPPQ
-- (and straightEndPPQ for notes), the canonical authoring-grid position
-- pre-swing, pre-delay. Mutation rules:
--   - snap-to-row             writes straightPPQ = row * sppr_currentFrame
--   - shift-by-row             straightPPQ += rowDelta * sppr_currentFrame
--   - delay nudge              straightPPQ unchanged, frame unchanged
--   - reswing                  straightPPQ unchanged, realised re-applied

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }

local function noteByPitch(dump, pitch)
  for _, n in ipairs(dump.notes) do if n.pitch == pitch then return n end end
end

local function ccByCC(dump, cc)
  for _, c in ipairs(dump.ccs) do if c.cc == cc then return c end end
end

return {

  ---------- AUTHORING

  {
    name = 'fresh note at cursor row r writes straightPPQ = r·sppr in current frame',
    run = function(harness)
      local h = harness.mk{ config = { take = { rowPerBeat = 4, currentOctave = 4 } } }
      h.vm:setGridSize(80, 40)

      -- C-4 at row 2, col 1, no swing → straight = realised = 120.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.truthy(n, 'note authored')
      t.eq(n.ppq,         120, 'realised ppq at row 2')
      t.eq(n.straightPPQ, 120, 'straight ppq pins authoring row')
      t.eq(n.frame.rpb,   4,   'frame.rpb stamped from take')
    end,
  },

  {
    name = 'fresh note under c58 stamps straightPPQ at the straight-grid row, ppq at the swung position',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      -- Row 2 = mid-period under c58: straight=120, realised≈139.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.straightPPQ, 120,   'straight pins row 2 (60 * 2)')
      t.truthy(math.abs(n.ppq - 139) <= 1,
        'realised lands at swung position, got ' .. n.ppq)
      t.eq(n.frame.swing, 'c58', 'frame.swing stamped from take')
    end,
  },

  {
    name = 'fresh cc at cursor row writes straightPPQ at row * sppr',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'cc', cc = 11, val = 0 } },
        },
        config = { take = { rowPerBeat = 8 } },
      }
      h.vm:setGridSize(80, 40)

      -- Find the cc=11 column.
      local ccColIdx
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 11 then ccColIdx = i end
      end
      h.ec:setPos(3, ccColIdx, 1)  -- row 3 in rpb=8 → sppr=30, straight=90
      h.vm:editEvent(h.vm.grid.cols[ccColIdx], nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.cc == 11 and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh, 'cc authored')
      t.eq(fresh.ppq,         90, 'realised ppq at row 3')
      t.eq(fresh.straightPPQ, 90, 'straightPPQ pins row 3 (30 * 3)')
    end,
  },

  ---------- DELAY NUDGE

  {
    name = 'delay nudge shifts realised onset but leaves end + straightPPQ intact',
    run = function(harness)
      -- Note covers intent ppq 120..360 (duration 240). Delay 500
      -- milli-QN = 120 ppq fits below the duration-1 collapse bound.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              straightPPQ = 120, straightEndPPQ = 360,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      -- Edit delay on the existing note. Note delay is decimal, stops 5..7.
      -- Set first nibble of delay magnitude to 5 → +500 ms-QN = 120 ppq.
      local cells = h.vm.grid.cols[1].cells
      local note  = cells[2]
      h.vm:editEvent(h.vm.grid.cols[1], note, 5, string.byte('5'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.straightPPQ, 120,    'straightPPQ untouched by delay nudge')
      t.eq(n.straightEndPPQ, 360, 'straightEndPPQ untouched by delay nudge')
      t.eq(n.delay, 500,          'delay applied (milli-QN, first digit slot)')
      t.eq(n.ppq,    240,         'realised onset shifted by delay')
      t.eq(n.endppq, 360,         'endppq stays put — delay shifts only the note-on')
    end,
  },

  ---------- RESWING ROUND-TRIP

  {
    name = 'reswing under same swing is a no-op on straightPPQ',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, straightPPQ = 120,
              chan = 1, msgType = 'cc', cc = 1, val = 64,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local c = ccByCC(h.fm:dump(), 1)
      t.eq(c.straightPPQ, 120, 'straightPPQ unchanged across same-swing reswing')
      -- realised re-applied; under same swing it's the same realised value
      -- (modulo rounding).
      t.truthy(math.abs(c.ppq - 139) <= 1, 'realised within ε of original')
    end,
  },
}
