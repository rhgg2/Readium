-- Exercises tm's detune/pb realisation. Invariants:
--   - view layer speaks intent (note.detune); tm realises via raw pb.
--   - a col-1 note with non-zero detune seats a "fake" pb absorbing the step.
--   - clearing detune back to prevailing cleans up the fake pb.
--   - at every seat P: logicalAt(P) = rawAt(P) - detuneAt(P), and a fake
--     pb carries `fake=true` (persisted as cc metadata).

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
    name = 'clearing detune back to 0 removes the fake pb',
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

  -- Regression: chans[chan].notes is sorted by ppq for util.seek, but
  -- assignLowlevel mutates ppq in place. If a note's new ppq leapfrogs
  -- a same-channel neighbour, the channel index goes out of order;
  -- without a re-sort, post-mutation lookups inside resizeNote
  -- (detuneBefore / logicalBefore) misidentify the prevailing note,
  -- the L != logicalBefore branch fires spuriously, and a REAL pb gets
  -- seated where a fake one belongs. This was the source of the
  -- "wiggle the swing slider, get loads of pitchbends" symptom under
  -- reswing's non-monotone mutation order.
  {
    name = 'mutating a note past a same-channel neighbour keeps fake pbs fake',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 120, endppq = 150, chan = 1, pitch = 60, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 180, endppq = 240, chan = 1, pitch = 64, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      -- Two fake pbs seated at the two onsets.
      local pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pbs[#pbs + 1] = c end
      end
      t.eq(#pbs, 2, 'one fake pb per detuned note')

      -- Move A past B in ppq. With the sort fix in assignLowlevel,
      -- detuneBefore(A.new) correctly returns B's detune; without it,
      -- it returns 0 and L != logicalBefore seats a real pb at A.new.
      local A = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', A, { ppq = 200, endppq = 230 })
      h.tm:flush()

      pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pbs[#pbs + 1] = c end
      end
      t.eq(#pbs, 2, 'still exactly two pbs after the move')
      for _, p in ipairs(pbs) do
        t.eq(p.fake, true, 'pb stays fake — no spurious real pb seated')
      end
    end,
  },

  {
    name = 'pb.fake survives a rebuild (persisted as cc metadata)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      -- Confirm the seated pb has metadata (uuid) and fake=true after flush.
      local pbs = pbsAt(h.fm:dump(), 0)
      t.eq(#pbs, 1, 'pb seated')
      t.eq(pbs[1].fake, true, 'fake flag persisted on cc')
      t.truthy(pbs[1].uuid, 'cc has a uuid (metadata sidecar allocated)')

      -- A rebuild reads from mm and must reconstruct the in-memory fake flag.
      h.tm:rebuild()
      local ch = h.tm:getChannel(1)
      t.falsy(ch.columns.pb, 'pb column still hidden after rebuild (fake-only)')
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

      -- Logical pb (raw - detune) should read as the originally-authored 100
      -- plus the delta introduced by the new note's detune above prior (0).
      -- That is: raw was 100¢ → 25¢ delta added → new raw is 125¢.
      t.eq(pbs[1].val, cents2raw(125),
        'raw advanced by detune delta so logical is preserved')
      t.eq(findNote(dump, 60).detune, 25)
    end,
  },

  -- Regression: in a non-12 temper, three rows A, A, B (A and B with
  -- different detunes) seat one fake pb at row 1 and one at row 3. If
  -- the user overwrites the second A with a B (assignNote with new
  -- pitch+detune), the fake pb at row 3 becomes redundant — detune
  -- now matches across that boundary — and must be removed. Bug was
  -- that retuneLowlevel propagated up to but excluding the next note,
  -- and the now-redundant fake pb at row 3 was left in place.
  {
    name = 'overwriting middle of A A B with B (different detunes) drops the now-redundant fake pb',
    run = function(harness)
      local h = harness.mk()
      -- Three notes back to back at ppqs 0, 240, 480, two different
      -- pitches and detunes (mimicking a 19EDO Eb2 Eb2 D-2 sequence).
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 50, vel = 100,
        detune = -30, delay = 0, lane = 1,
      })
      h.tm:flush()

      -- Sanity: two pbs at rows 1 and 3.
      local function allPbs()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then out[#out + 1] = c end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end
      local pbs = allPbs()
      t.eq(#pbs, 2, 'baseline: one pb at each detune jump')
      t.eq(pbs[1].ppq, 0)
      t.eq(pbs[2].ppq, 480)

      -- Overwrite the second A with B (same detune as the third note).
      local middle = h.tm:getChannel(1).columns.notes[1].events[2]
      h.tm:assignEvent('note', middle, { pitch = 50, detune = -30 })
      h.tm:flush()

      pbs = allPbs()
      t.eq(#pbs, 2, 'still two pbs after overwrite — boundary at row 3 collapsed')
      t.eq(pbs[1].ppq, 0,   'first pb at row 1 unchanged')
      t.eq(pbs[2].ppq, 240, 'second pb moved to row 2 (the new detune jump)')
      t.eq(pbs[2].val, cents2raw(-30), 'second pb carries B detune')
    end,
  },

  -- Companion: A . B (gap at row 2, detunes differ). Filling the gap
  -- with a B-pitch note leaves no detune jump at row 3, so the fake
  -- pb originally seated by B at row 3 is now redundant.
  {
    name = 'inserting B between A and B drops the now-redundant fake pb at the existing B',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 50, vel = 100,
        detune = -30, delay = 0, lane = 1,
      })
      h.tm:flush()

      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 50, vel = 100,
        detune = -30, delay = 0, lane = 1,
      })
      h.tm:flush()

      local pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pbs[#pbs + 1] = c end
      end
      table.sort(pbs, function(a, b) return a.ppq < b.ppq end)
      t.eq(#pbs, 2, 'two pbs — row 1 (A) and row 2 (B); row 3 boundary collapsed')
      t.eq(pbs[1].ppq, 0)
      t.eq(pbs[2].ppq, 240)
    end,
  },

  -- Cascade regression: A A A, then overwrite first → B A A, then
  -- overwrite second → B B A. Each step must seat fake pbs to absorb
  -- whatever detune jumps result, including the new jump that appears
  -- at the *next* note's seat when the carry shifts.
  {
    name = 'A A A then B A A then B B A keeps the fake-pb invariant at every note seat',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:flush()

      local function pbsByppq()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then out[#out + 1] = c end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end

      local pbs = pbsByppq()
      t.eq(#pbs, 1, 'AAA: single fake pb at row 1 absorbs A')
      t.eq(pbs[1].ppq, 0)
      t.eq(pbs[1].val, cents2raw(30))

      -- AAA → BAA: overwrite first A.
      local first = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', first, { pitch = 50, detune = -30 })
      h.tm:flush()

      pbs = pbsByppq()
      t.eq(#pbs, 2, 'BAA: pb at row 1 (B) and a new pb at row 2 absorbing the now-different A')
      t.eq(pbs[1].ppq, 0)
      t.eq(pbs[1].val, cents2raw(-30))
      t.eq(pbs[2].ppq, 240)
      t.eq(pbs[2].val, cents2raw(30))

      -- BAA → BBA: overwrite second A.
      local second = h.tm:getChannel(1).columns.notes[1].events[2]
      h.tm:assignEvent('note', second, { pitch = 50, detune = -30 })
      h.tm:flush()

      pbs = pbsByppq()
      t.eq(#pbs, 2, 'BBA: pb at row 1 (B) and pb at row 3 absorbing the trailing A')
      t.eq(pbs[1].ppq, 0)
      t.eq(pbs[1].val, cents2raw(-30))
      t.eq(pbs[2].ppq, 480)
      t.eq(pbs[2].val, cents2raw(30))
    end,
  },

  -- Resize regression: when a note that was bridging two same-detune
  -- notes is moved away, the trailing note's detune (previously masked
  -- by the bridge's carry) becomes a real jump from the new prior. The
  -- absorber has to be seated at that boundary; without it, the
  -- trailing note plays unabsorbed.
  --
  -- Setup A(d=0) B(d=10) C(d=10): only B seats a fake pb (C inherits B's
  -- carry, no pb). Move B past C: now A is C's prior, so C wants its
  -- own absorber.
  {
    name = 'moving a detuned note past a same-detune neighbour seats absorber at the unmasked seat',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 100,
        detune = 10, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 65, vel = 100,
        detune = 10, delay = 0, lane = 1,
      })
      h.tm:flush()

      local function pbsByppq()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then out[#out + 1] = c end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end

      local pbs = pbsByppq()
      t.eq(#pbs, 1, "baseline: only B seats a fake pb (C masked by B's carry)")
      t.eq(pbs[1].ppq, 240)
      t.eq(pbs[1].val, cents2raw(10))

      -- Move B past C. B sits at ppq=600 now; C's prior is A (detune 0).
      local B = h.tm:getChannel(1).columns.notes[1].events[2]
      h.tm:assignEvent('note', B, { ppq = 600, endppq = 840 })
      h.tm:flush()

      pbs = pbsByppq()
      t.eq(#pbs, 1, "one fake pb — at C's seat, absorbing the now-exposed jump")
      t.eq(pbs[1].ppq, 480, "absorber sits at C, not at B (B's carry already matches B)")
      t.eq(pbs[1].val, cents2raw(10), 'C absorbs +10 from carry 0')
      t.eq(pbs[1].fake, true)
    end,
  },

  -- Companion: A B A — deleting the middle B leaves A then A, no
  -- detune jump anywhere past the prior A. The fake pb at row 3 (A)
  -- becomes redundant once the B is gone.
  {
    name = 'deleting middle B in A B A drops the now-redundant fake pb at row 3',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 50, vel = 100,
        detune = -30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 51, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:flush()

      local middle = h.tm:getChannel(1).columns.notes[1].events[2]
      h.tm:deleteEvent('note', middle)
      h.tm:flush()

      local pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pbs[#pbs + 1] = c end
      end
      t.eq(#pbs, 1, 'only the A pb at row 1 remains')
      t.eq(pbs[1].ppq, 0)
    end,
  },

  -- I3 (lane-1 monopoly): a lane-2 detuned note carries metadata only —
  -- pb realisation is driven by lane 1.
  {
    name = 'lane-2 detuned note seats no pb (lane-1 monopoly on realisation)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100,
        detune = 50, delay = 0, lane = 2,
      })
      h.tm:flush()

      local pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pbs[#pbs + 1] = c end
      end
      t.eq(#pbs, 0, 'lane-2 detune does not seat a pb')

      local lane2Note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 64 then lane2Note = n end
      end
      t.eq(lane2Note.detune, 50, 'lane-2 detune still persists as note metadata')
    end,
  },

  -- I3 (lane-1 monopoly), regression: deleting a lane-2 note must not
  -- touch any pb — even one that happens to share the lane-2 note's
  -- ppq because a lane-1 sibling seats its absorber there.
  {
    name = 'deleting a lane-2 note at a lane-1 fake-pb seat leaves the absorber intact',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100,
        detune = 0, delay = 0, lane = 2,
      })
      h.tm:flush()

      local function pbCount()
        local n = 0
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then n = n + 1 end
        end
        return n
      end
      t.eq(pbCount(), 1, 'baseline: lane-1 fake pb seated at ppq=0')

      -- Find the lane-2 note via tm's channel structure.
      local lane2Col = h.tm:getChannel(1).columns.notes[2]
      t.truthy(lane2Col, 'lane-2 column exists')
      local lane2Evt = lane2Col.events[1]
      t.eq(lane2Evt.pitch, 64, 'lane-2 holds the pitch-64 note')

      h.tm:deleteEvent('note', lane2Evt)
      h.tm:flush()

      t.eq(pbCount(), 1, "lane-1's absorber survives unrelated lane-2 deletion")
      local pb
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' then pb = c end
      end
      t.eq(pb.fake, true, 'absorber still flagged fake')
      t.eq(pb.val, cents2raw(50), 'absorber value unchanged')
    end,
  },

  -- I7: a pure delay change on a detuned lane-1 note shifts the
  -- absorber along with the host. Count and value are preserved; only
  -- the realised ppq moves.
  {
    name = 'pure delay change shifts the fake pb with its host (count and value preserved)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:flush()

      local function pbs()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then out[#out + 1] = c end
        end
        return out
      end
      local before = pbs()
      t.eq(#before, 1, 'baseline: one fake pb at the seat')
      t.eq(before[1].ppq, 120)

      -- Nudge the note's delay only. delayToPPQ(500, res=240) = 120,
      -- so the note's realised ppq shifts 0 → 120 added → 240.
      local note = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', note, { delay = 500 })
      h.tm:flush()

      local after = pbs()
      t.eq(#after, 1, 'still exactly one pb after delay nudge')
      t.eq(after[1].fake, true, 'still fake')
      t.eq(after[1].val, cents2raw(50), 'value unchanged')

      local newNoteP
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 60 then newNoteP = n.ppq end
      end
      t.eq(newNoteP, 240, 'note shifted to realised ppq = intent + delayToPPQ(500)')
      t.eq(after[1].ppq, newNoteP, 'absorber follows the host to the new realised ppq')
    end,
  },

  -- I4 (orthogonality): editing a pb's logical value adjusts the raw
  -- stream but never retro-mutates a note's detune.
  {
    name = 'editing a real pb does not retro-mutate any note detune',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = cents2raw(0) } },
        },
      }
      -- Add a detuned note on top: the pre-existing real pb stays real,
      -- its raw advances by the detune delta (existing-test territory).
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 20, delay = 0, lane = 1,
      })
      h.tm:flush()

      local pbCol = h.tm:getChannel(1).columns.pb
      t.truthy(pbCol, 'pb column visible (real pb present)')
      local pbEvt
      for _, e in ipairs(pbCol.events) do
        if e.ppq == 0 then pbEvt = e end
      end
      t.truthy(pbEvt, 'real pb at ppq=0 in the pb column')

      -- User authors a new logical value at the seat.
      h.tm:assignEvent('pb', pbEvt, { val = 75 })
      h.tm:flush()

      local note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 60 then note = n end
      end
      t.eq(note.detune, 20, 'note detune is unchanged by the pb edit')
    end,
  },

  -- I4 (orthogonality), other direction: detune update on a note
  -- sitting on top of a real pb does not demote the pb to fake.
  {
    name = 'detune update on a note seated atop a real pb leaves it real',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = cents2raw(40) } },
        },
      }
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:flush()

      local function realPbAtZero()
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' and c.ppq == 0 then return c end
        end
      end
      t.falsy(realPbAtZero().fake, 'baseline: real pb stays real with detune=0')

      local note = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', note, { detune = 20 })
      h.tm:flush()

      local pb = realPbAtZero()
      t.truthy(pb, 'pb still present at seat')
      t.falsy(pb.fake, 'detune update on the host did not demote pb to fake')
      -- Logical preserved: was 40, still 40. Raw advanced by detune delta
      -- (0 → 20) so raw is now 60c, logical = 60 - 20 = 40.
      t.eq(pb.val, cents2raw(60), 'raw advanced by detune delta to preserve logical')
    end,
  },

  -- I8: round-trip stability. A flush followed by rebuild + flush
  -- produces an identical pb dump (no growth, no reordering, fake flag
  -- preserved).
  {
    name = 'flush + rebuild + flush is idempotent on the pb dump',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 30, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100,
        detune = -20, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100,
        detune = 10, delay = 0, lane = 1,
      })
      h.tm:flush()

      local function snap()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then
            out[#out + 1] = { ppq = c.ppq, val = c.val, fake = c.fake or false }
          end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end
      local before = snap()

      h.tm:rebuild()
      h.tm:flush()
      local after = snap()

      t.eq(#after, #before, 'pb count unchanged across rebuild')
      for i, p in ipairs(before) do
        t.eq(after[i].ppq,  p.ppq,  'pb '..i..' ppq unchanged')
        t.eq(after[i].val,  p.val,  'pb '..i..' val unchanged')
        t.eq(after[i].fake, p.fake, 'pb '..i..' fake-flag unchanged')
      end
    end,
  },

  -- I3 (lane-1 monopoly): editing a lane-2 note's detune does nothing
  -- to the pb stream.
  {
    name = 'editing a lane-2 note detune does not seat or move any pb',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100,
        detune = 0, delay = 0, lane = 2,
      })
      h.tm:flush()

      local function pbCount()
        local n = 0
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.msgType == 'pb' then n = n + 1 end
        end
        return n
      end
      t.eq(pbCount(), 0, 'baseline: no pbs (both detunes 0)')

      local lane2 = h.tm:getChannel(1).columns.notes[2].events[1]
      h.tm:assignEvent('note', lane2, { detune = 75 })
      h.tm:flush()

      t.eq(pbCount(), 0, 'lane-2 detune update does not author a pb')
      local note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 64 then note = n end
      end
      t.eq(note.detune, 75, 'lane-2 detune metadata updated')
    end,
  },
}
