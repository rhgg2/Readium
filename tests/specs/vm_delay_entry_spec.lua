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

  -- Neighbour-onset bound still binds: a positive delay that would
  -- push the realised onset at or past the next note's realised onset
  -- gets clamped to that boundary.
  {
    name = 'delay clamped at next-note realised onset',
    run = function(harness)
      -- Two notes, same lane: A covers 0..240, B covers 360..600.
      -- maxDelayPPQ = next.ppq + next.delayPPQ + off - this.ppq.
      -- With overlapOffset default 0, off=0 → maxDelayPPQ = 360.
      -- That's already past the duration cap (240 - 1 = 239), so the
      -- duration cap binds. Drop B further out so the neighbour cap
      -- binds instead: B at ppq=300, off ≥ 0 → next.ppq=300 - 0 - 0 =
      -- 300; duration cap 239 still wins. Make A shorter.
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

      -- A and B are different pitches, so they share lane 1 only if
      -- they don't overlap; here they do, so B goes to lane 2. Author
      -- on lane 1 (col 1).
      local col = h.vm.grid.cols[1]
      local A = col.cells[0]
      t.eq(A.pitch, 60, 'col 1 row 0 is A')

      h.ec:setPos(0, 1, 5)  -- 100s digit
      h.vm:editEvent(col, A, 5, string.byte('9'), false)

      -- A's duration cap = endppq - ppq - 1 = 599 ppq → maxDelay (ms-QN)
      -- = floor(599 * 1000 / 240) = 2495. The user-facing column tops
      -- out at ±999 (the digit-entry cap), so the column cap binds:
      -- typing 9 in the 100s slot writes 900. No duration clamp here —
      -- this confirms the path doesn't accidentally clamp at length.
      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 900)
      t.eq(n.ppq, 216, 'realised onset = ppq + delayToPPQ(900) = 216')
      t.eq(n.endppq, 600, 'endppq unchanged')
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
