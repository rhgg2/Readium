-- L2 lane stability under insertRow/deleteRow with non-identity swing.
-- Each event's new ppq is recomputed from `swing.fromLogical`, which
-- rounds independently per event. Two diff-pitch col-mates sitting at
-- exactly `lenient` pre-edit overlap can land past it post-shift.

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }

return {

  {
    name = 'insertRow under c58 keeps threshold-brushing diff-pitch col-mates in lane 1',
    run = function(harness)
      -- Both events authored under c58. Pre-edit intent overlap is
      -- exactly lenient (225 − 210 = 15). insertRow shifts both
      -- ppqLs by +60 (one row at rpb=4); the rounded c58.fromLogical
      -- of A.endppqL pushes its tail up to 264 while B's onset only
      -- rises to 244. Post overlap = 20 > 15 → on current code, B
      -- drifts to lane 2. Conform clips A's tail to 244 + 15 = 259.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 139, endppq = 225, ppqL = 120, endppqL = 200,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
            { ppq = 210, endppq = 480, ppqL = 183, endppqL = 480,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      -- Cursor on row 0 of chan-1 lane-1; insertRow with no selection
      -- inserts one row at the cursor.
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('insertRow')

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.pitch < b.pitch end)
      local A, B = notes[1], notes[2]
      t.eq(A.lane, 1, 'A still in lane 1 after insertRow')
      t.eq(B.lane, 1, 'B still in lane 1 — no drift')

      local lenient = 15
      t.truthy((A.endppq - B.ppq) <= lenient,
               'A tail clipped within lenient: A.endppq=' .. A.endppq ..
               ', B.ppq=' .. B.ppq)
    end,
  },

}
