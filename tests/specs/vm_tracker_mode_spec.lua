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
        config = { track = { trackerMode = true } },
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
        config = { track = { trackerMode = true } },
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
        config = { track = { trackerMode = true } },
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
        config = { track = { trackerMode = true } },
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
        config = { track = { trackerMode = true } },
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
          track = { trackerMode = true },
          take  = { currentSample = 0x12, currentOctave = 4 },
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
}
