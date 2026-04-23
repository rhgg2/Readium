-- Exercises vm editing commands against seeded tm state.

local t = require('support')

return {
  -- Delete on a note's delay stop (selGrp 3, no block selection) resets
  -- the delay metadata to 0 and lets the realisation line shift ppq
  -- back to the intent row. The view layer speaks intent only: it must
  -- not edit realised ppq directly.
  {
    name = 'delete on delay stop zeroes delay metadata',
    run = function(harness)
      -- resolution=240, 4 rpb → 1 row = 60 ppq. delay=500 milli-QN = +120 ppq.
      -- Seed realised ppq=180 so intent ppq=60 → row 1.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 180, endppq = 420, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 500 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)
      -- Col 1 is chan-1 lane-1 note col with delay enabled (7 stops,
      -- selGroups = {1,1,2,2,3,3,3}). Stop 5 → selGrp 3.
      h.vm:setCursor(1, 1, 5)
      h.cmgr.commands.delete()

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0, 'delay metadata zeroed')
      t.eq(note.ppq,   60, 'realised ppq shifted back to intent row')
      t.eq(note.endppq, 300, 'endppq shifted by the same delta')
    end,
  },

  -- End-state invariant: after placing a new note at (chan, pitch, ppq),
  -- no other note on the same (chan, pitch) may still cover ppq. The
  -- invariant is enforced jointly by addNoteEvent's cross-col truncate
  -- (pre-flush, in-memory) and tm:rebuild's group-by-pitch normalisation
  -- (post-flush). Either alone would pass this test; both together keep
  -- col.events consistent throughout a composite operation.
  {
    name = 'placing a new note clears same-pitch coverage in other cols of the channel',
    run = function(harness)
      -- Overlapping notes of DIFFERENT pitches on chan 1 force two lanes:
      --   A  pitch=60 covers [0, 600) → col 1
      --   Y  pitch=64 covers [120, 360) → col 2
      -- Typing C at row 8 (ppq=480) in col 2 places a new pitch-60 note
      -- past Y's end. A still covers ppq=480 and must be truncated back —
      -- cross-col, same pitch, same channel.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 600, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 120, endppq = 360, chan = 1, pitch = 64, vel = 80,  detune = 0, delay = 0 },
          },
        },
        config = { take = { currentOctave = 4 } },
      }
      h.vm:setGridSize(80, 40)

      local col2 = h.vm.grid.cols[2]
      t.eq(col2.type, 'note')
      t.eq(col2.midiChan, 1)
      t.eq(col2.lane, 2)

      -- Row 8 = ppq 480 (resolution 240, 4 rpb). Stop 1 = note name.
      -- 'z' in colemak = C; currentOctave=4 + octOff=0 → pitch 60.
      h.vm:setCursor(8, 2, 1)
      h.vm:editEvent(col2, nil, 1, string.byte('z'), false)

      local notes = h.fm:dump().notes
      local A, newN
      for _, n in ipairs(notes) do
        if     n.ppq == 0   and n.pitch == 60 then A    = n
        elseif n.ppq == 480 and n.pitch == 60 then newN = n end
      end
      t.truthy(A,           'original ppq=0 pitch-60 note survives')
      t.eq(A.endppq, 480,   'A truncated to new note ppq (was 600)')
      t.truthy(newN,        'new C-4 note placed at ppq=480')
    end,
  },

  -- No-op when delay is already zero: the branch is guarded so the
  -- keystroke doesn't emit a redundant flush.
  {
    name = 'delete on delay stop is a no-op when delay is already 0',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 60, endppq = 300, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)
      h.vm:setCursor(1, 1, 5)
      h.cmgr.commands.delete()

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0)
      t.eq(note.ppq,   60, 'ppq unchanged')
      t.eq(note.endppq, 300, 'endppq unchanged')
    end,
  },
}
