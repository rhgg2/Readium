-- Stage-1 pins for the editCursor refactor (design/editCursor-refactor.md).
-- These assert current vm behaviour so Stage 2's mechanical rewrites can't
-- drift it silently. They cover the seams where cursor-only and selection
-- paths are expected to coincide, and the asymmetric-defaults carveouts.

local t = require('support')

-- Shared seed: a single chan-1 note at row 4 (ppq 240 with resolution=240,
-- 4 rpb → 60 ppq/row), endppq at row 6. Used wherever a spec pokes the
-- cursor onto a delay/vel/pitch stop of an existing note.
local function mkNoteHarness(harness, noteOverrides, takeCfg)
  local note = {
    ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100,
    detune = 0, delay = 0,
  }
  for k, v in pairs(noteOverrides or {}) do note[k] = v end
  local h = harness.mk{
    seed   = { notes = { note } },
    config = { take = takeCfg or {} },
  }
  h.vm:setGridSize(80, 40)
  return h
end

-- Selection with both ends at the current cursor → 1×1 region at cursor.
local function degenerateSel(h)
  h.vm:selStart()
  h.vm:selUpdate()
end

return {

  -- 1. Degenerate selBounds: cursor-only delete and a 1×1-sel deleteSel
  -- produce identical mutations on the delay stop. Both zero delay. The
  -- cursor-advance side-effect of `delete` (selClear; deleteEvent;
  -- scrollRowBy(advanceBy)) is not part of the invariant — we compare
  -- the resulting note state only.
  {
    name = 'delete on delay stop ≡ deleteSel on 1×1 delay-stop selection',
    run = function(harness)
      -- delay=500 (milli-QN) = +120 ppq at resolution=240. Seed ppq is
      -- realised, so intent ppq = 240 - 120 = 120 → intent row 2. Cursor
      -- on row 2 stop 5 (first delay stop) both aims at the same note.
      local mk = function()
        local h = mkNoteHarness(harness, { delay = 500 },
                                { noteDelay = { [1] = { [1] = true } } })
        h.vm:setCursor(2, 1, 5)
        return h
      end

      local h1 = mk()
      h1.cmgr.commands.delete()
      local after1 = h1.fm:dump().notes[1]

      local h2 = mk()
      degenerateSel(h2)
      h2.cmgr.commands.deleteSel()
      local after2 = h2.fm:dump().notes[1]

      t.eq(after1.delay,  0, 'cursor-delete zeros delay')
      t.eq(after2.delay,  0, 'deleteSel-on-1×1 zeros delay')
      t.eq(after1.ppq,    after2.ppq,    'ppq matches between the two paths')
      t.eq(after1.endppq, after2.endppq, 'endppq matches between the two paths')
      t.eq(after1.vel,    after2.vel,    'vel untouched by either')
      t.eq(after1.pitch,  after2.pitch,  'pitch untouched by either')
    end,
  },

  -- Pinned separately because the cursor-only path branches through
  -- deleteEvent (operating on col.cells[cursorRow]) while the sel path
  -- branches through deleteSelection (operating on ppq-between). Both
  -- should land on the same queueResetVelocities behaviour: vel resets
  -- to the preceding note's vel (or defaultVelocity if none).
  {
    name = 'delete on vel stop ≡ deleteSel on 1×1 vel-stop selection',
    run = function(harness)
      local mk = function()
        local h = mkNoteHarness(harness, { vel = 77 })
        -- Cursor on intent row 4, stop 3 (first vel stop, selGrp 2).
        h.vm:setCursor(4, 1, 3)
        return h
      end

      local h1 = mk()
      h1.cmgr.commands.delete()
      local a = h1.fm:dump().notes[1]

      local h2 = mk()
      degenerateSel(h2)
      h2.cmgr.commands.deleteSel()
      local b = h2.fm:dump().notes[1]

      t.eq(a.vel,    b.vel,    'vel matches between the two paths')
      t.eq(a.ppq,    b.ppq,    'ppq untouched')
      t.eq(a.endppq, b.endppq, 'endppq untouched')
      t.eq(a.pitch,  b.pitch,  'pitch untouched')
      -- No carry-forward source → defaultVelocity (100).
      t.eq(a.vel, 100, 'vel reset to default (no prior note)')
    end,
  },

  -- 2a. Copy with no selection treats cursor as a 1×1 region. Round-trip
  -- via paste: cursor on an existing note → copy → move cursor → paste
  -- reproduces the note at the new row.
  --
  -- Seed note fits inside 1 row (ppq 240..300) so collectSelection
  -- captures endRow; otherwise endRow is dropped and the paste stretches
  -- the note to nextNote or length (pinned in a separate spec below).
  {
    name = 'copy/paste round-trip with no selection copies cursor-row note',
    run = function(harness)
      local h = mkNoteHarness(harness, { endppq = 300 })
      h.vm:setCursor(4, 1, 1)  -- pitch stop, on note
      h.cmgr.commands.copy()
      h.vm:setCursor(8, 1, 1)  -- ppq 480, empty
      h.cmgr.commands.paste()

      local notes = h.fm:dump().notes
      local orig, pasted
      for _, n in ipairs(notes) do
        if     n.ppq == 240 then orig   = n
        elseif n.ppq == 480 then pasted = n end
      end
      t.truthy(orig,   'original note preserved at ppq=240')
      t.truthy(pasted, 'pasted note lands at cursor ppq=480')
      t.eq(pasted.pitch,  60,  'pasted pitch matches')
      t.eq(pasted.vel,    100, 'pasted vel matches')
      t.eq(pasted.endppq, 540, 'pasted endppq = ppq + source duration')
    end,
  },

  -- 2a'. Subtle pin: when a 1-row copy spans only the start of a longer
  -- note, the note's endRow is dropped in collectSelection (endppq
  -- exceeds the region's endPPQ). On paste, addNoteEvent sees
  -- `ce.endppq or nextNotePPQ` and stretches the pasted note to the
  -- next note (or take length). This is existing behaviour — pinning
  -- so Stage 2 can't drift it.
  {
    name = 'copy of 1-row slice of a longer note pastes as open-ended',
    run = function(harness)
      -- Note spans ppq 240..360 (2 rows). 1-row copy at row 4 captures
      -- only its start; endRow is dropped.
      local h = mkNoteHarness(harness)
      h.vm:setCursor(4, 1, 1)
      h.cmgr.commands.copy()
      h.vm:setCursor(8, 1, 1)
      h.cmgr.commands.paste()

      local pasted
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 480 then pasted = n end
      end
      t.truthy(pasted)
      -- No nextNote after ppq=480 → stretches to take length (3840).
      t.eq(pasted.endppq, 3840, 'open-ended paste stretches to length')
    end,
  },

  -- 2b. Copy on an empty cell is a no-op on the clipboard. Prior clip
  -- content survives — so a later paste pastes the prior content, not
  -- an empty replacement.
  {
    name = 'copy on empty cursor cell leaves clipboard intact',
    run = function(harness)
      local h = mkNoteHarness(harness)
      -- First, copy the note at row 4.
      h.vm:setCursor(4, 1, 1)
      h.cmgr.commands.copy()
      -- Now move to an empty row and copy — should be a no-op.
      h.vm:setCursor(12, 1, 1)
      h.cmgr.commands.copy()
      -- Paste somewhere else. Should paste the row-4 note, not nothing.
      h.vm:setCursor(16, 1, 1)  -- ppq 960
      h.cmgr.commands.paste()

      local notes = h.fm:dump().notes
      local pasted
      for _, n in ipairs(notes) do
        if n.ppq == 960 then pasted = n end
      end
      t.truthy(pasted, 'prior clipboard survives empty-cell copy')
      t.eq(pasted.pitch, 60, 'pasted content is the prior copy')
    end,
  },

  -- 3. forEachRowOp asymmetry: the design-doc carveout says no-sel
  -- insertRow shifts every column, while a single-cell sel shifts
  -- only the sel col. Two-channel scenario so both note cols appear
  -- in grid.cols (CC lanes are not auto-added).
  {
    name = 'insertRow with no sel shifts every col; with 1×1 sel shifts only sel col',
    run = function(harness)
      local mkScenario = function()
        local h = harness.mk{
          seed = {
            notes = {
              { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100,
                detune = 0, delay = 0 },
              { ppq = 240, endppq = 360, chan = 2, pitch = 64, vel = 100,
                detune = 0, delay = 0 },
            },
          },
        }
        h.vm:setGridSize(80, 40)
        return h
      end

      local function noteAtChan(dump, chan)
        for _, n in ipairs(dump.notes) do if n.chan == chan then return n end end
      end

      -- No-sel: cursor on row 0 col 1. insertRow shifts every col.
      local h1 = mkScenario()
      h1.vm:setCursor(0, 1, 1)
      h1.cmgr.commands.insertRow()
      local d1 = h1.fm:dump()
      t.eq(noteAtChan(d1, 1).ppq, 300, 'no-sel insertRow shifts chan-1 note')
      t.eq(noteAtChan(d1, 2).ppq, 300, 'no-sel insertRow shifts chan-2 note (every col)')

      -- 1×1 sel on chan-1 col only: chan-2 note untouched.
      local h2 = mkScenario()
      h2.vm:setCursor(0, 1, 1)
      degenerateSel(h2)
      h2.cmgr.commands.insertRow()
      local d2 = h2.fm:dump()
      t.eq(noteAtChan(d2, 1).ppq, 300, '1×1-sel insertRow shifts sel col')
      t.eq(noteAtChan(d2, 2).ppq, 240, '1×1-sel insertRow leaves non-sel col untouched')
    end,
  },

  -- 4. duplicate-down on a pitch-stop cursor clones the cursor-row note
  -- to the following row. Pinning the minimal invariant: note count +1
  -- and the clone appears at the next row with the same pitch/vel.
  {
    name = 'duplicateDown with no sel clones cursor-row note to next row',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.vm:setCursor(4, 1, 1)  -- pitch stop
      h.cmgr.commands.duplicateDown()

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'one new note created')
      local orig, clone
      for _, n in ipairs(notes) do
        if     n.ppq == 240 then orig  = n
        elseif n.ppq == 300 then clone = n end
      end
      t.truthy(orig,  'original preserved at ppq=240')
      t.truthy(clone, 'clone lands at ppq=300 (one row below)')
      t.eq(clone.pitch, 60)
      t.eq(clone.vel,   100)
    end,
  },

  -- 5a. adjustPosition (nudgeForward) with no sel moves the cursor-row
  -- note's ppq forward by rowPerBeat-unit. cursorNoteBefore → at-or-
  -- before means cursor on the note's row picks up the note.
  {
    name = 'nudgeForward with no sel advances cursor-row note by 1 row',
    run = function(harness)
      local h = mkNoteHarness(harness)  -- note at ppq 240
      h.vm:setCursor(4, 1, 1)
      h.cmgr.commands.nudgeForward()

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    300, 'note.ppq advanced by 1 row (60 ppq)')
      -- Duration preserved (both ends shift).
      t.eq(n.endppq - n.ppq, 120, 'note duration preserved')
    end,
  },

  -- 5b. nudgeFineUp with no sel on a pitch-stop cursor raises pitch by 1
  -- (untuned: pitchStep(coarse=false) = 1 semitone).
  {
    name = 'nudgeFineUp with no sel on pitch stop raises pitch by 1',
    run = function(harness)
      local h = mkNoteHarness(harness)  -- pitch = 60
      h.vm:setCursor(4, 1, 1)
      h.cmgr.commands.nudgeFineUp()

      local n = h.fm:dump().notes[1]
      t.eq(n.pitch, 61, 'pitch raised by 1')
    end,
  },

  -- 5c. noteOff with no sel on an empty row inside an active note's
  -- span truncates the note at the cursor's ppq. Cursor row 5 (ppq 300)
  -- on a note covering ppq 240..360 → endppq becomes 300.
  {
    name = 'noteOff with no sel truncates the active note to cursor ppq',
    run = function(harness)
      local h = mkNoteHarness(harness)  -- note ppq 240..360
      h.vm:setCursor(5, 1, 1)  -- inside note span, pitch stop
      h.cmgr.commands.noteOff()

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    240, 'ppq unchanged')
      t.eq(n.endppq, 300, 'endppq truncated to cursor row ppq')
    end,
  },
}
