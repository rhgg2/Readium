-- L2 lane stability under quantizeKeepRealised. Same column-allocation
-- fragility as the other scopes: snapping intent onto grid can collapse
-- two col-mates onto a same-onset collision or push their intent
-- overlap past lenient. Differs from plain quantize because endppq
-- stays put and delay absorbs the intent shift — so any post-conform
-- newppq adjustment requires a corresponding newDelay correction to
-- preserve the realised-onset contract (or be honestly clamped).

local t = require('support')

return {

  {
    name = 'quantizeKeepRealised on diff-pitch col-mates keeps both in lane 1',
    run = function(harness)
      -- A on grid (ppq=120), B just past row 2 by 5 ppq (ppq=125).
      -- Pre overlap = 140−125 = 15 = lenient ✓.
      -- quantizeKeepRealised:
      --   A: targetppq = 120 = e.ppq → skip.
      --   B: targetppq = 120, wantDelay = 0 + ppqToDelay(5) ≈ 21
      --      → B.newppq = 120, B.newDelay = 21 (realised stays 125).
      -- Now A.ppqI = 120, B.ppqI = 120 − 5 = 115. Both in lane 1.
      -- noteColumnAccepts: overlap = 140 − 115 = 25 > 15. Rejected.
      -- B drifts to lane 2 on current code. Conform must keep it
      -- in lane 1 (by shifting B's intent up + redoing delay, or
      -- clipping A's tail — A is unplanned here so the lift-up branch
      -- fires).
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 140, ppqL = 120, endppqL = 140,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
            { ppq = 125, endppq = 400, ppqL = 125, endppqL = 400,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0,
              lane = 1,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.vm:quantizeKeepRealisedAll()

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.pitch < b.pitch end)
      local A, B = notes[1], notes[2]
      t.eq(A.lane, 1, 'A still in lane 1')
      t.eq(B.lane, 1, 'B still in lane 1 — no drift')
    end,
  },

}
