-- Exercises tm's detune/pb realisation. Invariants:
--   - view layer speaks intent (note.detune); tm realises via raw pb.
--   - a col-1 note with non-zero detune seats a "fake" pb absorbing the step.
--   - clearing detune back to prevailing cleans up the fake pb.
--   - at every seat P: logicalAt(P) = rawAt(P) - detuneAt(P), and a fake
--     pb carries `fake=true` while its host note carries `fakePb=true`.

local t = require('support')

-- pbRange default = 2 semitones = 200 cents total. So cents 50 → raw 2048.
local function cents2raw(c) return math.floor(c * 8192 / 200 + 0.5) end

local function findNote(dump, pitch)
  for _, n in ipairs(dump.notes) do
    if n.pitch == pitch then return n end
  end
end

local function pbsAt(dump, ppq)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.msgType == 'pb' and c.ppq == ppq then out[#out + 1] = c end
  end
  return out
end

return {
  {
    name = 'adding a note with detune seats a fake pb at the note',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      local dump = h.fm:dump()
      local n = findNote(dump, 60)
      t.truthy(n, 'note persisted')
      t.eq(n.detune, 50, 'detune preserved on the note')
      t.eq(n.fakePb, true, 'note tagged with fakePb')

      local pbs = pbsAt(dump, 0)
      t.eq(#pbs, 1, 'exactly one pb seated at ppq=0')
      t.eq(pbs[1].val, cents2raw(50), 'pb carries raw equivalent of detune')
      t.eq(pbs[1].fake, true, 'pb tagged as fake')
    end,
  },

  {
    name = 'logical pb at the note seat is zero (detune absorbs the raw step)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      -- Fake-only pb columns stay hidden — tm.channel.columns.pb should
      -- be absent when the only pb present is the absorber.
      local ch = h.tm:getChannel(1)
      t.falsy(ch.columns.pb, 'pb column hidden when only fake pbs exist')

      -- And the note column still shows the note at ppq=0.
      t.eq(#ch.columns.notes[1].events, 1)
      t.eq(ch.columns.notes[1].events[1].detune, 50)
    end,
  },

  {
    name = 'clearing detune back to 0 removes the fake pb and the fakePb tag',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      -- Retune to 0 via tm's intent-speaking API.
      local note = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', note, { detune = 0 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#pbsAt(dump, 0), 0, 'fake pb was cleaned up')

      local n = findNote(dump, 60)
      t.eq(n.detune, 0, 'detune zeroed')
      t.falsy(n.fakePb, 'fakePb tag removed')
    end,
  },

  {
    name = 'two notes with different detunes produce stepwise pbs between them',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 25, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100,
        detune = -30, delay = 0, lane = 1,
      })
      h.tm:flush()

      local dump = h.fm:dump()
      -- A fake pb at each note seat.
      local at0   = pbsAt(dump, 0)
      local at240 = pbsAt(dump, 240)
      t.eq(#at0,   1, 'pb at ppq=0')
      t.eq(#at240, 1, 'pb at ppq=240')
      t.eq(at0[1].val,   cents2raw(25),  'first seat carries +25 cents raw')
      t.eq(at240[1].val, cents2raw(-30), 'second seat carries -30 cents raw')
      t.eq(at0[1].fake,   true)
      t.eq(at240[1].fake, true)
    end,
  },

  {
    name = 'deleting a detuned note cleans up its fake pb',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()
      t.eq(#pbsAt(h.fm:dump(), 0), 1, 'pb seated')

      local note = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:deleteEvent('note', note)
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 0, 'note gone')
      t.eq(#pbsAt(dump, 0), 0, 'fake pb cleaned up with the note')
    end,
  },

  {
    name = 'a real (user-authored) pb at a note seat suppresses fake-pb bookkeeping',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = cents2raw(100) } },
        },
      }
      -- Now add a detuned note at the same seat. The existing real pb
      -- carries the logical value; detune is expressed on top.
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 25, delay = 0, lane = 1,
      })
      h.tm:flush()

      local dump = h.fm:dump()
      local pbs = pbsAt(dump, 0)
      t.eq(#pbs, 1, 'still a single pb at the seat')
      t.falsy(pbs[1].fake, 'existing real pb stays real')

      local n = findNote(dump, 60)
      t.falsy(n.fakePb, 'note not marked as having a fake pb')

      -- Logical pb (raw - detune) should read as the originally-authored 100
      -- plus the delta introduced by the new note's detune above prior (0).
      -- That is: raw was 100¢ → 25¢ delta added → new raw is 125¢.
      t.eq(pbs[1].val, cents2raw(125),
        'raw advanced by detune delta so logical is preserved')
      t.eq(n.detune, 25)
    end,
  },
}
