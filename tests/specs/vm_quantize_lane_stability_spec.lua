-- L2 lane stability under quantize. Quantize snaps each event to the
-- nearest grid row independently, so two off-grid col-mates can
-- collapse onto the same intent ppq, or onto adjacent rows whose
-- post-snap distance crosses the lenient threshold. Same root-cause
-- as the reswing fragility — exercised here through quantize's
-- different code path (assignStamp / row-snap rather than
-- swing.fromLogical).

local t = require('support')

return {

  {
    name = 'diff-pitch col-mates that quantize-collapse onto the same ppq stay in lane 1',
    run = function(harness)
      -- A on row 2 exactly, with a tail extending sub-row into row 3
      -- (endppq=152). B between rows 2 and 3 (ppq=140). Pre-quantize:
      --   A = 120 / 152, pitch 60, lane 1
      --   B = 140 / 400, pitch 64, lane 1
      -- Their intent overlap is 152−140 = 12 ≤ lenient=15 ✓.
      --
      -- Quantize at rpb=4, res=240 (logPerRow=60):
      --   A.endppq rounds up: row 2.53 → row 3 → endppq=180
      --   B.ppq   rounds down: row 2.33 → row 2 → ppq=120
      -- Both events end up at ppq=120, a same-onset collision the
      -- allocator rejects via `noteppqI == evtppqI`. On current code,
      -- B falls through to a fresh lane 2.
      --
      -- conformOverlaps must (1) shift the later-source-ppqL one (B)
      -- by 1 ppq, then (2) clip A's tail back to within lenient of
      -- B's new ppq. Result: A = 120/136, B = 121/360, both lane 1.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 152, ppqL = 120, endppqL = 152,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
            { ppq = 140, endppq = 400, ppqL = 140, endppqL = 400,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.pitch < b.pitch end)
      local A, B = notes[1], notes[2]
      t.eq(A.pitch, 60, 'A is pitch 60')
      t.eq(B.pitch, 64, 'B is pitch 64')
      t.eq(A.lane, 1,   'A still in lane 1 after quantize')
      t.eq(B.lane, 1,   'B still in lane 1 after quantize — no drift')

      -- Onsets remain distinct (1-ppq separation from same-onset shift).
      t.truthy(A.ppq ~= B.ppq, 'onsets distinct: A.ppq=' .. A.ppq .. ', B.ppq=' .. B.ppq)
      -- Tail-clip leaves overlap within lenient.
      local lenient = 15
      t.truthy((A.endppq - B.ppq) <= lenient,
               'overlap ≤ lenient: A.endppq=' .. A.endppq .. ', B.ppq=' .. B.ppq)
    end,
  },

}
