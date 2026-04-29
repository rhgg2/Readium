-- Exercises vm editing commands against seeded tm state.

local t = require('support')

return {
  -- Delete on a note's delay stop (selGrp 3, no block selection) resets
  -- the delay metadata to 0 and lets the realisation line shift the
  -- note-on back to the intent row. Endppq is intent in storage and
  -- never carries the delay offset, so it doesn't move when delay is
  -- cleared. The view layer speaks intent only: it must not edit
  -- realised ppq directly.
  {
    name = 'delete on delay stop zeroes delay metadata',
    run = function(harness)
      -- resolution=240, 4 rpb → 1 row = 60 ppq. delay=500 milli-QN = +120 ppq.
      -- Seed realised onset ppq=180 so intent ppq=60 → row 1. Endppq=420
      -- is already intent (= realised end under the new delay model).
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
      h.ec:setPos(1, 1, 5)
      h.cmgr.commands.delete()

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0, 'delay metadata zeroed')
      t.eq(note.ppq,   60, 'realised ppq shifted back to intent row')
      t.eq(note.endppq, 420, 'endppq stays put (delay never shifted it)')
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
      h.ec:setPos(8, 2, 1)
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

  -- Write-boundary clamp: if a same-(chan, pitch) note starts inside the
  -- new note's body on another column, the new note's endppq must be
  -- clamped to that start at the moment of addition — not merely repaired
  -- post-hoc by rebuild. tm:addEvent owns the invariant.
  {
    name = 'placing a new note clamps its endppq to a same-pitch successor in another col',
    run = function(harness)
      -- Two-lane setup on chan 1:
      --   A  pitch=60, covers [0, 120)        → col 1
      --   Y  pitch=64, covers [0, 600)        → col 2 (forces a 2nd lane)
      --   B  pitch=60, covers [360, 600)      → col 1 (after A, same col)
      -- Typing C at row 1 (ppq=60) in col 2 places a new pitch-60 note.
      -- placeNewNote's same-col seek finds the next pitch-60 note AFTER
      -- ppq=60 in col 2 — there is none, so without cross-col awareness
      -- the new note would run to the take end. B starts at ppq=360 on
      -- col 1, same (chan, pitch): the write-time clamp must shorten
      -- the new note to endppq=360.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 0,   endppq = 600, chan = 1, pitch = 64, vel = 80,  detune = 0, delay = 0 },
            { ppq = 360, endppq = 600, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
        },
        config = { take = { currentOctave = 4 } },
      }
      h.vm:setGridSize(80, 40)

      local col2 = h.vm.grid.cols[2]
      t.eq(col2.lane, 2)

      h.ec:setPos(1, 2, 1)
      h.vm:editEvent(col2, nil, 1, string.byte('z'), false)

      local newN
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 60 and n.pitch == 60 then newN = n end
      end
      t.truthy(newN,        'new C-4 note placed at ppq=60')
      t.eq(newN.endppq, 360, 'new note endppq clamped to B.ppq (cross-col same-key successor)')
    end,
  },

  -- No-op when delay is already zero: the branch is guarded so the
  -- keystroke doesn't emit a redundant flush.
  -- Single-cell pitch delete extends the predecessor's endppq to the next
  -- note's start when the predecessor was tied to the deleted note.
  {
    name = 'delete on pitch tied predecessor extends to next note',
    run = function(harness)
      -- res=240, 4 rpb → 1 row = 60 ppq. Three sequential same-pitch notes:
      --   A: rows 0..1 (ppq 0..120), tied to B
      --   B: rows 2..3 (ppq 120..240), tied to C
      --   C: rows 4..5 (ppq 240..360)
      -- Delete B → A.endppq should jump to C.ppq=240.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1) -- row 2 = ppq 120 (B), pitch stop
      h.cmgr.commands.delete()

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'B deleted')
      local A, C
      for _, n in ipairs(notes) do
        if     n.ppq == 0   then A = n
        elseif n.ppq == 240 then C = n end
      end
      t.truthy(A and C, 'A and C survive')
      t.eq(A.endppq, 240, 'A extended to C.ppq')
    end,
  },

  -- Single-cell vel delete carries forward from the most recent prior event,
  -- including PAs — not just the previous note.
  {
    name = 'delete on vel inherits from a prior PA event',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 80,  detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, msgType = 'pa', pitch = 60, val = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 3) -- row 4 = ppq 240 (note B), vel stop
      h.cmgr.commands.delete()

      local note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 240 then note = n end
      end
      t.truthy(note, 'B survives')
      t.eq(note.vel, 70, 'B.vel inherits from prior PA, not prior note')
    end,
  },

  -- Single-cell pitch delete on a PA cell is a no-op: pitch kind targets
  -- notes only, even when the cell under the cursor is a PA.
  {
    name = 'delete on pitch over a PA cell is a no-op',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, msgType = 'pa', pitch = 60, val = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1) -- row 2 = ppq 120 (PA cell), pitch stop
      h.cmgr.commands.delete()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'note untouched')
      local stillPA = false
      for _, c in ipairs(dump.ccs) do
        if c.msgType == 'pa' and c.ppq == 120 then stillPA = true end
      end
      t.truthy(stillPA, 'PA untouched')
    end,
  },

  -- Selection pitch delete operates on notes only; PAs in the rectangle
  -- are left alone (vel-kind delete is the channel for removing PAs).
  -- Host note sits outside the selection so its survival isolates what the
  -- queue function does on its own — no cascade-from-host noise.
  {
    name = 'selection pitch delete leaves PAs alone',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            -- Cell at row 0; covers ppq 0..480 so it hosts the PA.
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            -- Cell at row 2; pitch=60 means hosted by the note above.
            { ppq = 120, chan = 1, msgType = 'pa', pitch = 60, val = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Selection rows 1..3 (ppq [60, 240)) excludes the host note (row 0)
      -- and includes the PA (row 2).
      h.ec:setSelection{ row1=1, row2=3, col1=1, col2=1, kind1='pitch', kind2='pitch' }

      h.cmgr.commands.deleteSel()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'host note untouched (outside selection)')
      local stillPA = false
      for _, c in ipairs(dump.ccs) do
        if c.msgType == 'pa' and c.ppq == 120 then stillPA = true end
      end
      t.truthy(stillPA, 'PA preserved under pitch-kind selection delete')
    end,
  },

  -- Selection vel delete removes PAs in the rectangle; notes get vel reset.
  {
    name = 'selection vel delete deletes PAs and resets note vels',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            -- Host note for the PA, sits at row 0 outside the selection.
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, msgType = 'pa', pitch = 60, val = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Rows 1..3 covers the PA cell (row 2) but not the host note (row 0).
      h.ec:setSelection{ row1=1, row2=3, col1=1, col2=1, kind1='vel', kind2='vel' }

      h.cmgr.commands.deleteSel()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'host note survives')
      local paGone = true
      for _, c in ipairs(dump.ccs) do
        if c.msgType == 'pa' and c.ppq == 120 then paGone = false end
      end
      t.truthy(paGone, 'PA in vel-kind selection deleted')
    end,
  },

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
      h.ec:setPos(1, 1, 5)
      h.cmgr.commands.delete()

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0)
      t.eq(note.ppq,   60, 'ppq unchanged')
      t.eq(note.endppq, 300, 'endppq unchanged')
    end,
  },
}
