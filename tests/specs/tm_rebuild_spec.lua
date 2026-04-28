-- Exercises tm:rebuild against seeded mm state.

local t = require('support')

return {
  {
    name = 'empty take has 16 channels each with one empty lane',
    run = function(harness)
      local h = harness.mk()
      for chan = 1, 16 do
        local ch = h.tm:getChannel(chan)
        t.truthy(ch, 'channel exists')
        t.eq(#ch.columns.notes, 1, 'one note lane by default')
        t.eq(#ch.columns.notes[1].events, 0, 'lane is empty')
      end
      t.eq(h.tm:resolution(), 240)
      t.eq(h.tm:length(), 3840)
    end,
  },

  {
    name = 'a single note surfaces as one lane-1 event',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 1, 'one note column')
      local col = ch.columns.notes[1]
      -- tm strips `chan` and `lane` from column events — channel is
      -- implied by the column's position in the grid.
      t.eventsMatch(col.events, { { ppq = 0, endppq = 240, pitch = 60, vel = 100 } })
    end,
  },

  {
    name = 'tm seeds detune and delay metadata on rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 0, 'detune seeded to 0')
      t.eq(note.delay,  0, 'delay seeded to 0')
    end,
  },

  {
    name = 'existing detune/delay survive rebuild (defaults do not clobber)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 37, delay = -15 },
          },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 37, 'existing detune preserved')
      t.eq(note.delay, -15, 'existing delay preserved')
    end,
  },

  {
    name = 'partial metadata: only the missing field is defaulted',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 25 },  -- delay missing
          },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 25, 'detune preserved')
      t.eq(note.delay, 0, 'missing delay defaulted to 0')
    end,
  },

  {
    name = 'a second rebuild after seeding is a no-op on metadata',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      -- First rebuild (driven by seed) has already populated defaults. A
      -- manual second rebuild must leave them stable.
      h.tm:rebuild()
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 0)
      t.eq(note.delay, 0)
    end,
  },

  {
    name = 'rebuild from a seeded detuned note + matching fake pb keeps pb hidden',
    run = function(harness)
      -- Cents-to-raw under default pbRange=2 semitones: 50¢ → raw 2048.
      local rawFor50 = 2048
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 0 },
          },
          ccs = {
            { ppq = 0, chan = 1, msgType = 'pb', val = rawFor50, fake = true },
          },
        },
      }
      -- pb column hidden because the only pb is the absorber.
      local ch = h.tm:getChannel(1)
      t.falsy(ch.columns.pb, 'pb column hidden for fake-only pb')
      -- Note still visible in col-1 with its detune intact.
      t.eq(ch.columns.notes[1].events[1].detune, 50)
    end,
  },

  {
    name = 'fake pb inherits delay from its host note (travels into intent frame)',
    run = function(harness)
      -- Host note: intent ppq=0, delay=500 → at resolution 240 the realised
      -- shift is 120 PPQ, so mm stores the note and its absorber at ppq=120.
      -- After rebuild, both must surface at intent ppq=0.
      local rawFor50 = 2048
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 500 },
          },
          ccs = {
            { ppq = 120, chan = 1, msgType = 'pb', val = rawFor50, fake = true },
            -- A visible pb later on so the pb column surfaces at all.
            { ppq = 480, chan = 1, msgType = 'pb', val = 0 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(ch.columns.notes[1].events[1].ppq, 0,
        'note sits at intent ppq=0 after delay strip')

      t.truthy(ch.columns.pb, 'pb column surfaces (visible pb present)')
      local fakeDisp
      for _, e in ipairs(ch.columns.pb.events) do
        if e.hidden then fakeDisp = e end
      end
      t.truthy(fakeDisp, 'fake pb display event present in column')
      t.eq(fakeDisp.ppq, 0,
        'fake pb display event co-located with its host note')
    end,
  },

  {
    name = 'overlapping notes on the same pitch/channel are truncated',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 480, chan = 1, pitch = 60, vel = 100 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100 },
          },
        },
      }
      local notes = h.fm:dump().notes
      -- First note should now end at 240 (start of the second).
      local first = notes[1].ppq < notes[2].ppq and notes[1] or notes[2]
      t.eq(first.endppq, 240, 'first note truncated at successor start')
    end,
  },

  {
    name = 'distinct pitches on same ppq share a channel in separate lanes',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 2, 'two lanes allocated for coincident notes')
    end,
  },

  {
    name = 'a pb event populates the pb column with logical cents',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = 4096 } },
        },
      }
      local ch = h.tm:getChannel(1)
      t.truthy(ch.columns.pb, 'pb column exists')
      -- Default pbRange = 2 semitones = 200 cents. val 4096 / 8192 * 200 = 100.
      t.eventsMatch(ch.columns.pb.events, { { ppq = 0, val = 100 } })
    end,
  },

  {
    name = 'tm:addEvent + flush round-trips through mm',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'one note persisted to mm')
      t.eventsMatch(dump.notes, { { ppq = 0, endppq = 240, pitch = 60, vel = 100 } })

      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes[1].events, 1, 'tm sees the new note on rebuild')
    end,
  },

  {
    name = 'delete-then-add in a single flush leaves one note at new ppq',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local before = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:deleteEvent('note', before)
      h.tm:addEvent('note', { ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 90, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'one note after flush')
      t.eventsMatch(dump.notes, { { ppq = 480, endppq = 720, pitch = 62, vel = 90 } })
    end,
  },
}
