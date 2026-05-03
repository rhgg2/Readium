-- Pin commit 2a of the sampler-integration plan: enabling trackerMode
-- inserts a `sample` part into note cells, hides the PC col, and routes
-- sample-stop edits onto note.sample. tm doesn't yet act on the field
-- (synthesis lands in 2b) — these specs cover only the vm-side wiring.

local t = require('support')

return {

  ----- PC col visibility

  {
    name = 'trackerMode off: pc events surface as a pc col',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 0, msgType = 'pc', chan = 1, val = 7 } },
        },
      }
      h.vm:setGridSize(80, 40)
      local pcCol
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'pc' then pcCol = c end
      end
      t.truthy(pcCol, 'pc col present when trackerMode=false')
    end,
  },

  {
    name = 'trackerMode on: pc col is hidden',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 0, msgType = 'pc', chan = 1, val = 7 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)
      for _, c in ipairs(h.vm.grid.cols) do
        t.falsy(c.type == 'pc',
          'pc col must not appear in grid when trackerMode=true')
      end
    end,
  },

  ----- Note col gains a `sample` part under trackerMode

  {
    name = 'trackerMode on: note col carries sample part',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)
      local lane1
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then lane1 = c end
      end
      t.truthy(lane1, 'lane-1 note col exists')
      t.deepEq(lane1.parts, {'pitch','sample','vel'}, 'parts include sample')
      t.eq(lane1.width, 9, 'cell width grew to 9')
    end,
  },

  ----- Sample-stop editing writes note.sample

  {
    name = 'editing sample stops on an existing note: high then low nibble = 0x55',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, sample = 0 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)

      -- After every commit the grid is rebuilt and col/evt refs go stale,
      -- so look them up afresh the way the renderer would.
      local function chan1Lane1()
        for _, c in ipairs(h.vm.grid.cols) do
          if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return c end
        end
      end

      local col = chan1Lane1()
      t.eq(col.partAt[3], 'sample', 'stop 3 is sample (high nibble)')
      t.eq(col.partAt[4], 'sample', 'stop 4 is sample (low nibble)')

      -- 0x55 = 85, comfortably under the 0..127 PC range. Picked because
      -- 0xA5 would clamp at 0x7F and obscure what we're actually pinning.
      h.ec:setPos(0, 1, 3)
      h.vm:editEvent(col, col.events[1], 3, string.byte('5'), false)
      col = chan1Lane1()
      h.vm:editEvent(col, col.events[1], 4, string.byte('5'), false)

      t.eq(h.fm:dump().notes[1].sample, 0x55,
           'note.sample composed from the two nibble edits')
    end,
  },

  {
    name = 'sample value clamps to 0..127 (PC byte range)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, sample = 0 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)
      local col
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then col = c end
      end
      -- 'F' on the high nibble would set 0xF0 = 240 — must clamp to 0x7F.
      h.vm:editEvent(col, col.events[1], 3, string.byte('F'), false)
      t.eq(h.fm:dump().notes[1].sample, 0x7F, 'high nibble F clamps to 127')
    end,
  },

  {
    name = 'sample edits work on lane-2 notes too (no lane gating in 2a)',
    run = function(harness)
      -- Two overlapping pitches force a lane-2 col on chan 1.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 0 },
            { ppq = 0, endppq = 480, chan = 1, pitch = 64, vel = 90,  detune = 0, delay = 0, sample = 0 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)

      local function chan1Lane2()
        for _, c in ipairs(h.vm.grid.cols) do
          if c.midiChan == 1 and c.type == 'note' and c.lane == 2 then return c end
        end
      end

      local col = chan1Lane2()
      t.truthy(col, 'lane-2 note col exists')
      local targetPitch = col.events[1].pitch

      h.ec:setPos(0, 2, 3)
      h.vm:editEvent(col, col.events[1], 3, string.byte('4'), false)
      col = chan1Lane2()
      h.vm:editEvent(col, col.events[1], 4, string.byte('2'), false)

      local note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == targetPitch then note = n end
      end
      t.eq(note.sample, 0x42, 'lane-2 sample edit writes through')
    end,
  },

  ----- placeNewNote stamps cm:get('currentSample')

  {
    name = 'placing a new note in trackerMode stamps note.sample = currentSample',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {} },
        config = {
          transient = { trackerMode = true },
          take      = { currentSample = 0x12, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      local col
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then col = c end
      end
      h.ec:setPos(0, 1, 1)
      -- 'z' on colemak is C; pitch C-4 with currentOctave=4.
      h.vm:editEvent(col, nil, 1, string.byte('z'), false)

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'one note placed')
      t.eq(notes[1].sample, 0x12, 'new note stamped with currentSample')
    end,
  },

  {
    name = 'placing a new note with trackerMode off does not stamp sample',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {} },
        config = { take = { currentSample = 0x12, currentOctave = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local col
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then col = c end
      end
      h.ec:setPos(0, 1, 1)
      h.vm:editEvent(col, nil, 1, string.byte('z'), false)

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'one note placed')
      t.falsy(notes[1].sample, 'no sample field stamped when trackerMode off')
    end,
  },

  ----- inputSampleUp / inputSampleDown commands
  -- Step ±1 across the full 0..127 range. Empty slots are reachable —
  -- the user may want to author a sample value before the sampler has
  -- loaded that slot.

  {
    name = 'inputSampleUp increments by 1 even into empty slots',
    run = function(harness)
      local h = harness.mk{ config = {
        take      = { currentSample = 5 },
        transient = { samplerNames = { [3] = 'a', [10] = 'b' } },
      } }
      h.cmgr.commands.inputSampleUp()
      t.eq(h.cm:get('currentSample'), 6, 'stepped to empty slot 6')
    end,
  },

  {
    name = 'inputSampleDown decrements by 1 even into empty slots',
    run = function(harness)
      local h = harness.mk{ config = { take = { currentSample = 5 } } }
      h.cmgr.commands.inputSampleDown()
      t.eq(h.cm:get('currentSample'), 4)
    end,
  },

  {
    name = 'inputSampleUp clamps at 127',
    run = function(harness)
      local h = harness.mk{ config = { take = { currentSample = 127 } } }
      h.cmgr.commands.inputSampleUp()
      t.eq(h.cm:get('currentSample'), 127)
    end,
  },

  {
    name = 'inputSampleDown clamps at 0',
    run = function(harness)
      local h = harness.mk{ config = { take = { currentSample = 0 } } }
      h.cmgr.commands.inputSampleDown()
      t.eq(h.cm:get('currentSample'), 0)
    end,
  },

  ----- Editing a sample stop also updates currentSample
  -- The intent: the value you just typed becomes the value future
  -- new notes will be stamped with.

  {
    name = 'editing a sample stop sets currentSample to the new value',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, sample = 0 } },
        },
        config = {
          transient = { trackerMode = true },
          take      = { currentSample = 0 },
        },
      }
      h.vm:setGridSize(80, 40)
      local function lane1()
        for _, c in ipairs(h.vm.grid.cols) do
          if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return c end
        end
      end
      local col = lane1()
      h.ec:setPos(0, 1, 3)
      h.vm:editEvent(col, col.events[1], 3, string.byte('5'), false)
      col = lane1()
      h.vm:editEvent(col, col.events[1], 4, string.byte('5'), false)
      t.eq(h.cm:get('currentSample'), 0x55,
           'currentSample tracks the most recent sample-stop edit')
    end,
  },

  ----- Sample part is inert on PA cells (typing and delete)

  {
    name = 'typing into sample part of a PA cell does nothing',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, sample = 0x33 } },
          ccs   = { { ppq = 240, msgType = 'pa', chan = 1, pitch = 60, val = 80 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)
      local function lane1()
        for _, c in ipairs(h.vm.grid.cols) do
          if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return c end
        end
      end
      local col = lane1()
      local paRow
      for r, evt in pairs(col.cells) do
        if evt.type == 'pa' then paRow = r end
      end
      t.truthy(paRow, 'PA cell is on the grid')
      h.ec:setPos(paRow, 1, 3)
      h.vm:editEvent(col, col.cells[paRow], 3, string.byte('A'), false)
      local paDump
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pa' then paDump = c end
      end
      t.falsy(paDump.sample, 'PA was not tagged with sample')
      t.eq(h.fm:dump().notes[1].sample, 0x33, 'host note sample untouched')
    end,
  },

  {
    name = 'delete on sample part of a PA cell does nothing',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, sample = 0 } },
          ccs   = { { ppq = 240, msgType = 'pa', chan = 1, pitch = 60, val = 80 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.vm:setGridSize(80, 40)
      local col
      for _, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then col = c end
      end
      local paRow
      for r, evt in pairs(col.cells) do
        if evt.type == 'pa' then paRow = r end
      end
      h.ec:setPos(paRow, 1, 3)
      h.cmgr.commands.delete()    -- must not crash and must not delete the PA
      local stillPA = false
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pa' and c.ppq == 240 then stillPA = true end
      end
      t.truthy(stillPA, 'PA event survived delete on sample part')
    end,
  },
}
