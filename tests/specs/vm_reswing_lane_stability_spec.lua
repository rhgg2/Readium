-- L2 lane stability under reswing's rounding edge.
--
-- The audit (design/audit/L2_lane_stability.md) found that reswing's
-- monotone-but-rounded `swing.fromLogical` can push diff-pitch
-- col-mates sitting near `lenient` overlap past the threshold, after
-- which `allocateNoteColumn` rejects the persisted lane and the
-- successor drifts to a fresh lane. The fix is `conformOverlaps`
-- (vm), which clips the predecessor's tail back to threshold before
-- the writes commit.

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }

return {

  {
    name = 'diff-pitch col-mates at lenient overlap survive a reswing into c58 in lane 1',
    run = function(harness)
      -- A and B are both lane 1 on chan 1, different pitches, authored
      -- under identity (so source ppq == ppqL). Their intent overlap
      -- is exactly `lenient` (overlapOffset=1/16, resolution=240 →
      -- lenient=15). Reswinging into c58 stretches the early portion
      -- of each period — A.endppq rounds up further than B.ppq does,
      -- pushing the overlap to 17 (> 15). On current buggy code B
      -- falls through allocateNoteColumn and lands in a fresh lane 2.
      -- With conformOverlaps, A's tail is clipped to B.newppq + 15
      -- and B keeps its lane 1.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 100, endppq = 300, ppqL = 100, endppqL = 300,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
            { ppq = 285, endppq = 500, ppqL = 285, endppqL = 500,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.pitch < b.pitch end)
      local A, B = notes[1], notes[2]
      t.eq(A.pitch, 60, 'A is pitch 60')
      t.eq(B.pitch, 64, 'B is pitch 64')
      t.eq(A.lane, 1,   'A still in lane 1 after reswing')
      t.eq(B.lane, 1,   'B still in lane 1 after reswing — no drift')

      -- A's tail was clipped so the overlap sits at exactly lenient.
      local lenient = 15
      t.truthy(A.endppq <= B.ppq + lenient,
               'A.endppq clipped within lenient of B.ppq; ' ..
               'A.endppq=' .. A.endppq .. ', B.ppq=' .. B.ppq)
      -- And by enough to put the overlap inside the accept window
      -- (overlapAmount > threshold is the rejection rule).
      t.truthy((A.endppq - B.ppq) <= lenient,
               'overlap amount ≤ lenient: ' .. (A.endppq - B.ppq))
    end,
  },

}
