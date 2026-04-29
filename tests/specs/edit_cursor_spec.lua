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
-- extendTo to current pos: creates a fresh sel (no movement, no anchor drift).
local function degenerateSel(h)
  h.ec:extendTo(h.ec:pos())
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
        h.ec:setPos(2, 1, 5)
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
        h.ec:setPos(4, 1, 3)
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
      h.ec:setPos(4, 1, 1)  -- pitch stop, on note
      h.cmgr.commands.copy()
      h.ec:setPos(8, 1, 1)  -- ppq 480, empty
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
      h.ec:setPos(4, 1, 1)
      h.cmgr.commands.copy()
      h.ec:setPos(8, 1, 1)
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
      h.ec:setPos(4, 1, 1)
      h.cmgr.commands.copy()
      -- Now move to an empty row and copy — should be a no-op.
      h.ec:setPos(12, 1, 1)
      h.cmgr.commands.copy()
      -- Paste somewhere else. Should paste the row-4 note, not nothing.
      h.ec:setPos(16, 1, 1)  -- ppq 960
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
      h1.ec:setPos(0, 1, 1)
      h1.cmgr.commands.insertRow()
      local d1 = h1.fm:dump()
      t.eq(noteAtChan(d1, 1).ppq, 300, 'no-sel insertRow shifts chan-1 note')
      t.eq(noteAtChan(d1, 2).ppq, 300, 'no-sel insertRow shifts chan-2 note (every col)')

      -- 1×1 sel on chan-1 col only: chan-2 note untouched.
      local h2 = mkScenario()
      h2.ec:setPos(0, 1, 1)
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
      h.ec:setPos(4, 1, 1)  -- pitch stop
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

  -- 4b. duplicate's sel path. pasteSingle branches on ec:cursorKind(),
  -- which reads the stop ec lands on before paste. The invariant is
  -- that the pre-paste stop shares a kind with sel.col1/kind1 — held
  -- today by firstStopForKind(c1, kind1), and by the regionStart verb
  -- that replaces it. Pitch and vel probe distinct paste branches;
  -- together they catch a kind-dispatch regression in the refactor.
  {
    name = 'duplicateDown with 1x1 pitch-kind sel clones cursor-row note',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setPos(4, 1, 1)  -- pitch stop
      degenerateSel(h)
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
      t.eq(clone.pitch, 60, 'pitch-kind paste reproduces pitch')
      t.eq(clone.vel,   100)
    end,
  },

  -- 4c. Kind-width counterpart: 1x1 sel on a vel stop (selGrp 2, stop 3
  -- on a plain note col). pasteSingle's vel branch requires an existing
  -- note at the target row, so seed two notes and verify the source vel
  -- is written onto the target note. Pinning this guards against a
  -- regionStart implementation that lands on stop 1 (pitch) instead of
  -- the first stop of kind1 (vel) — the paste would silently take the
  -- pitch branch and blow away the target note.
  {
    name = 'duplicateDown with 1x1 vel-kind sel copies vel to target-row note',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 300, chan = 1, pitch = 60, vel = 77,
              detune = 0, delay = 0 },
            { ppq = 300, endppq = 360, chan = 1, pitch = 62, vel = 100,
              detune = 0, delay = 0 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 3)  -- vel stop on the row-4 note
      degenerateSel(h)
      h.cmgr.commands.duplicateDown()

      -- Target is row 5 (ppq=300) — the second note. Its vel should
      -- now carry the source vel (77), not its own (100).
      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'no new note created by vel paste')
      local src, dst
      for _, n in ipairs(notes) do
        if     n.ppq == 240 then src = n
        elseif n.ppq == 300 then dst = n end
      end
      t.truthy(src and dst, 'both notes present')
      t.eq(src.vel, 77,  'source note vel unchanged')
      t.eq(dst.vel, 77,  'target note vel copied from source')
      t.eq(dst.pitch, 62, 'target note pitch untouched (vel-only paste)')
    end,
  },

  -- 5a. adjustPosition (nudgeForward) with no sel moves the cursor-row
  -- note's ppq forward by rowPerBeat-unit, and the cursor follows so a
  -- repeated keypress keeps targeting the same note (cursorNoteBefore
  -- would otherwise lose it once the note's ppq passed the cursor row).
  {
    name = 'nudgeForward with no sel advances cursor-row note by 1 row and cursor follows',
    run = function(harness)
      local h = mkNoteHarness(harness)  -- note at ppq 240..360 (rows 4..6)
      h.ec:setPos(4, 1, 1)
      h.cmgr.commands.nudgeForward()

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    300, 'note.ppq advanced by 1 row (60 ppq)')
      t.eq(n.endppq - n.ppq, 120, 'note duration preserved')
      t.eq(h.ec:row(), 5, 'cursor follows note forward by one row')
    end,
  },

  -- 5a-i. Length-preservation against a hard wall. With prev.endppq on the
  -- cursor-note's onset row, nudgeBack has nowhere to go without
  -- shortening the note. The pre-fix code shrank the note to fit; the
  -- contract now is all-or-nothing — refuse the move outright.
  {
    name = 'nudgeBack against adjacent prev refuses move; length preserved',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 120, endppq = 240, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)  -- on note B's onset row
      h.cmgr.commands.nudgeBack()

      local notes = h.fm:dump().notes
      local b
      for _, n in ipairs(notes) do if n.pitch == 62 then b = n end end
      t.truthy(b, 'second note still present')
      t.eq(b.ppq,    120, 'note B onset unchanged (move refused)')
      t.eq(b.endppq, 240, 'note B endppq unchanged (length preserved)')
      t.eq(h.ec:row(), 2, 'cursor stays put when move refused')
    end,
  },

  -- 5a-ii. Off-grid bound. Prev.endppq sits between rows; pre-fix code
  -- clamped to the fractional row and landed the moved note off-grid.
  -- The new comparison is candidate-ppq vs bound-ppq, so a sub-row
  -- collision blocks the whole move rather than producing an off-grid
  -- onset.
  {
    name = 'nudgeBack with off-grid prev.endppq does not land note off grid',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        -- prev ends at ppq 50 — between row 0 (ppq 0) and row 1 (ppq 60)
        { ppq = 0,  endppq = 50,  chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)  -- on note B's onset row
      h.cmgr.commands.nudgeBack()

      local b
      for _, n in ipairs(h.fm:dump().notes) do if n.pitch == 62 then b = n end end
      t.eq(b.ppq,    60,  'note B onset unchanged (move refused — would-be ppq 0 < bound 50)')
      t.eq(b.endppq, 120, 'note B endppq unchanged')
      -- Critical: ppq is on a row, never the off-grid bound (50).
      t.truthy(b.ppq % 60 == 0, 'note B ppq is grid-aligned')
    end,
  },

  -- 5a-ii-bis. Item-start guard. ctx:rowToPPQ clamps row -1 to ppq 0, so
  -- a candidate-ppq check would pass for a note already at ppq 0 and
  -- we'd author at row -1, shrinking the note. Bounds in row space
  -- (ceil(minRow) = 0) catch newStart = -1 cleanly.
  {
    name = 'nudgeBack on a note at ppq 0 refuses move; length preserved',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr.commands.nudgeBack()

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    0,   'ppq stays at 0')
      t.eq(n.endppq, 120, 'endppq unchanged (length not shrunk)')
      t.eq(h.ec:row(), 0, 'cursor stays at row 0')
    end,
  },

  -- 5a-iii. Cursor-follow guard. When the row the cursor would advance
  -- into already holds a different note, leave the cursor where it is
  -- so a follow-up nudge doesn't silently retarget the neighbour.
  {
    name = 'nudgeForward leaves cursor put when destination row holds another note',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 60,  endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 180, endppq = 240, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)  -- on A's endRow; cursorNoteBefore picks A
      h.cmgr.commands.nudgeForward()

      local a, b
      for _, n in ipairs(h.fm:dump().notes) do
        if     n.pitch == 60 then a = n
        elseif n.pitch == 62 then b = n end
      end
      t.eq(a.ppq,    120, 'note A advanced by one row')
      t.eq(a.endppq, 180, 'note A endppq advanced; just touches B')
      t.eq(b.ppq,    180, 'note B unmoved')
      t.eq(h.ec:row(), 2, 'cursor stays — row 3 is occupied by B')
    end,
  },

  -- 5b. nudgeFineUp with no sel on a pitch-stop cursor raises pitch by 1
  -- (untuned: pitchStep(coarse=false) = 1 semitone).
  {
    name = 'nudgeFineUp with no sel on pitch stop raises pitch by 1',
    run = function(harness)
      local h = mkNoteHarness(harness)  -- pitch = 60
      h.ec:setPos(4, 1, 1)
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
      h.ec:setPos(5, 1, 1)  -- inside note span, pitch stop
      h.cmgr.commands.noteOff()

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    240, 'ppq unchanged')
      t.eq(n.endppq, 300, 'endppq truncated to cursor row ppq')
    end,
  },

  -- 6. ec:eachSelectedCol — iterator pins. Seeds three chans so the grid
  -- has multiple note cols; tests no-sel / 1×1 / multi-col behaviour.
  {
    name = 'eachSelectedCol with no selection yields the cursor col as a 1x1 fallback',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setPos(0, 2)
      local got = {}
      for col, ci in h.ec:eachSelectedCol() do
        got[#got + 1] = { ci = ci, chan = col.midiChan }
      end
      t.eq(#got, 1,        'exactly the cursor col is yielded')
      t.eq(got[1].ci, 2,   'yielded ci is the cursor col')
    end,
  },

  {
    name = 'eachSelectedCol yields (col, ci) for each column in the selection',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq=0, endppq=60, chan=1, pitch=60, vel=100 },
          { ppq=0, endppq=60, chan=2, pitch=60, vel=100 },
          { ppq=0, endppq=60, chan=3, pitch=60, vel=100 },
        }},
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=3, kind1='pitch', kind2='pitch' }

      local got = {}
      for col, ci in h.ec:eachSelectedCol() do
        got[#got + 1] = { ci = ci, chan = col.midiChan }
      end
      t.eq(#got, 3, 'three cols yielded for a 3-col selection')
      t.eq(got[1].ci, 1,   'first ci = col1')
      t.eq(got[3].ci, 3,   'last ci = col2')
      t.eq(got[1].chan, 1, 'first col is chan 1')
      t.eq(got[3].chan, 3, 'last col is chan 3')
    end,
  },

  -- vm:showDelay routed through the iterator: enabling delay via a
  -- selection flips exactly the selected note cols, not the grid at large.
  {
    name = 'vm:showDelay enables delay on every note col in the selection',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq=0, endppq=60, chan=1, pitch=60, vel=100 },
          { ppq=0, endppq=60, chan=2, pitch=60, vel=100 },
          { ppq=0, endppq=60, chan=3, pitch=60, vel=100 },
        }},
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=2, kind1='pitch', kind2='pitch' }  -- chans 1..2

      h.vm:showDelay()
      local nd = h.cm:get('noteDelay')

      t.truthy(nd[1] and nd[1][1], 'delay enabled on chan 1 lane 1')
      t.truthy(nd[2] and nd[2][1], 'delay enabled on chan 2 lane 1')
      t.falsy (nd[3] and nd[3][1], 'delay untouched on unselected chan 3')
    end,
  },

  -- Pins ec:extendTo's two-mode contract: with no sel, anchors at the
  -- current cursor and grows to the target; with sel, leaves the anchor
  -- alone and just moves the moving end. Both rm shift-click and drag
  -- ride this verb.
  {
    name = 'ec:extendTo with no sel anchors at cursor and grows to target',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setPos(2, 1, 1)
      h.ec:extendTo(5, 1, 1)
      t.truthy(h.ec:hasSelection(), 'sel created')
      local r1, r2 = h.ec:region()
      t.eq(r1, 2, 'sel anchored at original cursor row')
      t.eq(r2, 5, 'sel grown to target row')
    end,
  },

  {
    name = 'ec:extendTo with active sel preserves anchor, moves the loose end',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setPos(2, 1, 1)
      h.ec:extendTo(5, 1, 1)   -- anchor=2, end=5
      h.ec:extendTo(7, 1, 1)   -- second extend should keep anchor=2
      local r1, r2 = h.ec:region()
      t.eq(r1, 2, 'anchor preserved across second extend')
      t.eq(r2, 7, 'loose end advanced')
    end,
  },

  -- ec:pos returns the cursor triple in setPos order, so a setPos →
  -- pos round-trip is the identity. Guards against a future drift in
  -- the pair convention (e.g. swapping col/stop, or returning a record).
  {
    name = 'ec:pos round-trips ec:setPos in (row, col, stop) order',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setPos(7, 1, 3)
      local r, c, s = h.ec:pos()
      t.eq(r, 7, 'row')
      t.eq(c, 1, 'col')
      t.eq(s, 3, 'stop')
    end,
  },

  -- Pins the public-boundary contract: ec:region speaks kinds, not
  -- selgroups. setSelection round-trips a vel-kind sel through region
  -- and out the other side as kind='vel' (selgrp 2). A regression that
  -- leaks selgrp through region would surface as kind1=2 here.
  {
    name = 'setSelection / region round-trip preserves kind',
    run = function(harness)
      local h = mkNoteHarness(harness)
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=1, kind1='vel', kind2='vel' }
      local r1, r2, c1, c2, k1, k2 = h.ec:region()
      t.eq(r1, 0,     'row1')
      t.eq(r2, 0,     'row2')
      t.eq(c1, 1,     'col1')
      t.eq(c2, 1,     'col2')
      t.eq(k1, 'vel', 'kind1 emerges as kind, not selgrp')
      t.eq(k2, 'vel', 'kind2 emerges as kind, not selgrp')
    end,
  },
}
