-- Pins the "delay shifts only the note-on" model and the bounds vm
-- enforces when the user types into the delay sub-column.

local t = require('support')

return {

  -- Regression: a note ending at the item edge used to be uneditable
  -- on the delay column because overlapBounds capped maxEnd at item
  -- length and delayRange treated that as a cap on realised endppq.
  -- Under the new model endppq is intent and never moves, so item
  -- length is irrelevant — only the next-note onset and the duration
  -- collapse bound clamp.
  {
    name = 'positive delay accepted on a note ending at item length',
    run = function(harness)
      -- Item length defaults to 4 bars (rpb=4, beats=4 per bar →
      -- numRows≈64, length=3840 ppq at res=240). Seed a single note that
      -- ends well inside that, and another with endppq at length to be
      -- sure neither is clamped.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 3840, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local note = col.cells[0]
      t.truthy(note, 'note at row 0')

      h.ec:setPos(0, 1, 5)  -- delay 100s digit
      h.vm:editEvent(col, note, 5, string.byte('5'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 500, 'digit landed despite endppq sitting at item length')
      t.eq(n.endppq, 3840, 'endppq unchanged — delay does not move it')
      t.eq(n.ppq, 120, 'realised onset shifted by delayToPPQ(500) = 120')
    end,
  },

  -- The duration-collapse bound: realised onset must stay strictly
  -- below endppq, so a delay that would push the note-on at or past
  -- the note's own end gets clamped at endppq - 1 ppq.
  {
    name = 'delay clamped so realised duration stays >= 1 ppq',
    run = function(harness)
      -- Note covers intent ppq 0..120 (one row at rpb=4, res=240).
      -- maxDelayPPQ = endppq - ppq - 1 = 119 → maxDelay (ms-QN) =
      -- floor(1000 * 119 / 240) = 495.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      h.vm:editEvent(col, col.cells[0], 5, string.byte('9'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 495, 'delay clamped to floor((endppq-ppq-1)*1000/res)')
      t.eq(n.endppq, 120, 'endppq still pinned at intent end')
    end,
  },

  -- Different-pitch neighbours impose NO delay constraint — chord
  -- /dyad realisation overlap is musically fine. Only the duration
  -- self-cap and the digit-entry cap (±999) bind on this geometry.
  {
    name = 'different-pitch next imposes no delay constraint',
    run = function(harness)
      -- A at intent 0..600, B different pitch at intent 240..480.
      -- They share the channel; B is in lane 2 (intent overlap of 360
      -- exceeds the default overlapOffset). delayRange on A sees no
      -- same-pitch neighbour at all → only the duration cap (599 ppq
      -- → 2495 ms-QN) bounds. The digit-entry cap (±999) binds first.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 600, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 80,
              detune = 0, delay = 0 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local A = col.cells[0]
      t.eq(A.pitch, 60, 'col 1 row 0 is A')

      h.ec:setPos(0, 1, 5)  -- 100s digit
      h.vm:editEvent(col, A, 5, string.byte('9'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 900, 'no neighbour clamp; column cap (±999) binds')
      t.eq(n.ppq, 216, 'realised onset = ppq + delayToPPQ(900) = 216')
      t.eq(n.endppq, 600, 'endppq unchanged')
    end,
  },

  -- Same-pitch repeats can't co-exist on a MIDI (chan, pitch), so a
  -- same-pitch prev binds delay HARD at its intent end — no
  -- overlapOffset leniency. Different from the different-pitch case
  -- above, where the neighbour imposes no constraint at all.
  {
    name = 'same-pitch prev binds delay hard at intent end (no off)',
    run = function(harness)
      -- A pitch 60 ends at intent 120. B pitch 60 starts at intent 240,
      -- pre-seeded with delay = 600 ms-QN (storage ppq = 240 + 144 =
      -- 384). Typing '-' negates the delay → wants -600. delayRange's
      -- minDelay = (A.endppq − B.intent) × 1000 / res = (120 − 240) ×
      -- 1000 / 240 = -500. Hard zero, no leniency. -600 clamps to -500.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0   },
            { ppq = 384, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 600 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local B = col.cells[4]  -- B at intent ppq 240 = row 4 (rpb=4, res=240)
      t.truthy(B, 'B is at row 4')
      t.eq(B.delay, 600, 'B seeded with delay = 600')

      h.ec:setPos(4, 1, 5)
      h.vm:editEvent(col, B, 5, string.byte('-'), false)

      -- A still at storage ppq 0; B's storage ppq shifted by clamped delay.
      local Bafter
      for _, x in ipairs(h.fm:dump().notes) do
        if x.ppq ~= 0 then Bafter = x end
      end
      t.eq(Bafter.delay, -500, 'delay clamped at same-pitch minimum (no off)')
      t.eq(Bafter.ppq, 120, 'realised onset = A.endppq exactly')
    end,
  },

  -- Same-pitch lookup is per (chan, pitch), not per column. If a
  -- same-pitch prev sits in a different lane (forced via lane
  -- metadata), delayRange must still find it.
  {
    name = 'same-pitch prev in another column still binds delay',
    run = function(harness)
      -- A in lane 1, B in lane 2, both pitch 60 on chan 1, intent
      -- non-overlapping. Without channel-wide lookup, delayRange on B
      -- would see no prev (B is alone in lane 2) and let -600 land.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0,   lane = 1 },
            { ppq = 384, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 600, lane = 2 },
          },
        },
        config = {
          take = {
            noteDelay   = { [1] = { [1] = true, [2] = true } },
            extraColumns = { [1] = { notes = 2 } },
          },
        },
      }
      h.vm:setGridSize(80, 40)

      -- B is in col 2 (channel 1's second note lane).
      local colB = h.vm.grid.cols[2]
      local B = colB.cells[4]
      t.truthy(B, 'B at row 4 in lane 2')

      h.ec:setPos(4, 2, 5)
      h.vm:editEvent(colB, B, 5, string.byte('-'), false)

      local Bafter
      for _, x in ipairs(h.fm:dump().notes) do
        if x.ppq ~= 0 then Bafter = x end
      end
      t.eq(Bafter.delay, -500,
        'channel-wide same-pitch lookup found A in lane 1; clamp at -500')
    end,
  },

  -- Performance delay must not reorder onsets within a column. A
  -- same-column predecessor (any pitch) binds the floor at its
  -- realised onset; without this, a large negative delay could
  -- push a later note's onset before its column-neighbour's,
  -- breaking the realised-order = intent-order invariant the pb
  -- model relies on.
  {
    name = 'same-column prev binds delay so realised onsets stay ordered',
    run = function(harness)
      -- A and B both lane 1 of channel 1, different pitches, intent
      -- non-overlapping. B is seeded with delay = -100 (storage ppq
      -- 336 = intent 360 + delayToPPQ(-100,240) = 360 − 24) so a
      -- single '9' on the 100s digit produces newDelay = -1 * 900
      -- (sign carried from the existing negative). Bound floor =
      -- ppqToDelay(A.realisedOnset + 1 − B.intent, 240)
      --        = ppqToDelay(241 − 360, 240) ≈ -495.83 → ceil = -495.
      -- So -900 clamps to -495, leaving B's realised onset at 241 —
      -- just after A's at 240. Without the bound, -900 would land
      -- and B's realised onset would jump to 144, before A.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0    },
            { ppq = 336, endppq = 720, chan = 1, pitch = 64, vel = 100,
              detune = 0, delay = -100 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local B = col.cells[6]
      t.truthy(B and B.pitch == 64, 'B at row 6, lane 1')

      h.ec:setPos(6, 1, 5)  -- delay 100s digit
      h.vm:editEvent(col, B, 5, string.byte('9'), false)

      local Bafter
      for _, x in ipairs(h.fm:dump().notes) do
        if x.pitch == 64 then Bafter = x end
      end
      t.eq(Bafter.delay, -495,
        'clamped at A.realisedOnset + 1 — performance delay must not reorder')
      t.eq(Bafter.ppq, 241,
        'realised onset stays just after A.realisedOnset = 240')
    end,
  },

  -- Negative delay floors at 0: a note at ppq=0 cannot be nudged
  -- earlier (realised ppq must remain non-negative).
  {
    name = 'negative delay refused on a note at intent ppq 0',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      -- '-' on a zero delay is a no-op (the editEvent guard).
      h.vm:editEvent(col, col.cells[0], 5, string.byte('-'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 0)
      t.eq(n.ppq, 0)
    end,
  },
}
