-- See docs/trackerManager.md for the model and API reference.

loadModule('util')
loadModule('midiManager')
loadModule('timing')

local function print(...)
  return util.print(...)
end

function newTrackerManager(mm, cm)

  ---------- PRIVATE

  local channels = {}
  local fire  -- installed below, once tm exists
  local um    -- update manager; set by tm:rebuild
  local lastMuteSet = {}  -- { [chan] = true }, pushed by vm via tm:setMutedChannels

  local function sortByPPQ(tbl)
    table.sort(tbl, function(a, b) return a.ppq < b.ppq end)
  end

  local function centsToRaw(cents)
    local lim = cm:get('pbRange') * 100
    return util.clamp(util.round(cents * 8192 / lim), -8192, 8191)
  end

  local function rawToCents(raw)
    local lim = cm:get('pbRange') * 100
    return util.round(raw / 8192 * lim)
  end

  local function delayToPPQ(d) return timing.delayToPPQ(d, mm:resolution()) end

  ----- Swing

  local function resolveSlot(name)
    local composite = timing.findShape(name, cm:get('swings'))
    if timing.isIdentity(composite) then return nil end
    local ppqPerQN = mm:resolution()
    local factors = {}
    for i, f in ipairs(composite) do
      local atom = timing.atoms[f.atom]
      if not atom then error('timing: unknown atom ' .. tostring(f.atom)) end
      local tileQN = timing.atomTilePeriod(f)
      factors[i] = { S = atom(f.shift / tileQN), T = ppqPerQN * tileQN }
    end
    return factors
  end

  ----- Update manager

  local function createUpdateManager()
    local adds = {}
    local assigns = {}
    local deletes = {}
    local chans = {}
    local notesByLoc = {}
    local ccsByLoc = {}

    ----- Accessors

    local function owner(chan, P)
      return util.seek(chans[chan].notes, 'at-or-before', P, function(n) return n.endppq > P end)
    end

    local function detuneAt(chan, P)
      local n = util.seek(chans[chan].notes, 'at-or-before', P)
      return (n and n.detune) or 0
    end

    local function detuneBefore(chan, P)
      local n = util.seek(chans[chan].notes, 'before', P)
      return (n and n.detune) or 0
    end

    local function rawAt(chan, P)
      local pb = util.seek(chans[chan].pbs, 'at-or-before', P)
      return pb and pb.val or 0
    end

    local function rawBefore(chan, P)
      local pb = util.seek(chans[chan].pbs, 'before', P)
      return pb and pb.val or 0
    end

    local function pbAt(chan, P)
      local pb = util.seek(chans[chan].pbs, 'at-or-before', P)
      return pb and pb.ppq == P and pb or nil
    end

    local function logicalAt(chan, P)
      return rawAt(chan, P) - detuneAt(chan, P)
    end

    local function logicalBefore(chan, P)
      return rawBefore(chan, P) - detuneBefore(chan, P)
    end

    local function nextLogicalChange(chan, P)
      local currentLogical = logicalAt(chan, P)
      local pb = util.seek(chans[chan].pbs, 'after', P, function(e) return logicalAt(chan, e.ppq) ~= currentLogical end)
      return (pb and pb.ppq) or math.huge
    end

    local function nextRealChange(chan, P)
      local pb = util.seek(chans[chan].pbs, 'after', P, function(e) return not e.fake end)
      return (pb and pb.ppq) or math.huge
    end

    local function nextNotePPQ(chan, P)
      local n = util.seek(chans[chan].notes, 'after', P)
      return (n and n.ppq) or math.huge
    end

    local function forEachAttachedPA(host, fn)
      for _, cc in pairs(ccsByLoc) do
        if cc.msgType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch
          and cc.ppq >= host.ppq and cc.ppq < host.endppq then
          fn(cc)
        end
      end
    end

    ----- Low-level mutation

    local function addLowlevel(evtType, evt)
      if evtType == 'note' then
        local col1 = evt.lane == 1
        if col1 then
          local tbl = chans[evt.chan].notes
          util.add(tbl, evt)
          sortByPPQ(tbl)
        end
      elseif evtType == 'pb' then
        local tbl = chans[evt.chan].pbs
        evt.msgType = 'pb'
        util.add(tbl, evt)
        sortByPPQ(tbl)
      else
        evt.msgType = evtType
      end
      util.add(adds, { type = evtType, evt = evt })
    end

    local function assignLowlevel(evtType, evt, update)
      util.assign(evt, update)
      -- Note ppq mutates in place here; resort the channel index so
      -- subsequent util.seek calls (detuneAt / pbAt / nextNotePPQ /
      -- logicalBefore — all key off chans[chan].notes sorted by ppq)
      -- stay correct even when callers like reswing process notes in
      -- non-monotone order.
      if evtType == 'note' and update.ppq ~= nil and evt.lane == 1 then
        sortByPPQ(chans[evt.chan].notes)
      end
      if not evt.loc then return end
      for _, e in ipairs(assigns) do
        if e.loc == evt.loc and e.type == evtType then
          util.assign(e.update, update)
          return
        end
      end
      util.add(assigns, { type = evtType, loc = evt.loc, update = update })
    end

    local function deleteLowlevel(evtType, evt)
      local tbl
      local locTbl = ccsByLoc
      if evtType == 'note' then
        tbl = chans[evt.chan].notes
        locTbl = notesByLoc
      elseif evtType == 'pb' then
        tbl = chans[evt.chan].pbs
      end

      if tbl then
        for i, item in ipairs(tbl) do
          if item == evt then
            table.remove(tbl, i)
            break
          end
        end
      end

      local loc = evt.loc

      if loc then
        locTbl[loc] = nil
        util.add(deletes, { type = evtType, loc = loc })
        for j = #assigns, 1, -1 do
          local e = assigns[j]
          if e.loc == loc and e.type == evtType then table.remove(assigns, j) end
        end
      else
        for j = #adds, 1, -1 do
          if adds[j].evt == evt then table.remove(adds, j); break end
        end
      end
    end

    local function retuneLowlevel(chan, P1, P2, delta)
      if delta == 0 then return end
      for _, pb in ipairs(chans[chan].pbs) do
        if pb.ppq >= P1 and pb.ppq < P2 then
          assignLowlevel('pb', pb, { val = pb.val + delta })
        end
      end
    end

    local function forcePb(chan, P, extras)
      if pbAt(chan, P) then return false end
      addLowlevel('pb', util.assign({ ppq = P, chan = chan, val = rawAt(chan, P) }, extras))
      return true
    end

    local function markFake(chan, P)
      local pb = pbAt(chan, P)
      if pb then assignLowlevel('pb', pb, { fake = true }) end
    end

    local function unmarkFake(chan, P)
      local pb = pbAt(chan, P)
      if not (pb and pb.fake) then return end
      assignLowlevel('pb', pb, { fake = util.REMOVE })
    end

    -- Restore the fake-pb invariant at note seat P after a detune
    -- change has shifted the carry across it: if the note's detune
    -- jumps over the carry, a fake pb must absorb the jump; if not,
    -- any redundant fake pb is just noise. Callers invoke this in
    -- the post-mutation frame (note edits committed) so detuneAt/
    -- Before see live values. Real (user-authored) pbs are left
    -- alone — only fake absorbers are managed.
    local function reconcileBoundary(chan, P)
      if P >= math.huge then return end
      local D, C = detuneAt(chan, P), detuneBefore(chan, P)
      local pb   = pbAt(chan, P)
      if D == C then
        if pb and pb.fake and rawAt(chan, P) == rawBefore(chan, P) then
          deleteLowlevel('pb', pb)
        end
      elseif not pb then
        forcePb(chan, P)               -- val = rawAt = rawBefore (no pb yet)
        markFake(chan, P)
        pb = pbAt(chan, P)
        assignLowlevel('pb', pb, { val = pb.val + (D - C) })
      end
    end

    ----- High-level ops

    local function addPb(pb)
      local chan, P, L = pb.chan, pb.ppq, pb.val or 0
      local delta  = L - logicalAt(chan, P)
      local extras = util.pick(pb, 'ppqL frame')
      if not next(extras) then extras = nil end
      if not forcePb(chan, P, extras) then
        if extras then assignLowlevel('pb', pbAt(chan, P), extras) end
        unmarkFake(chan, P)
      end
      retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
    end

    local function deletePb(pb)
      local chan, P = pb.chan, pb.ppq
      retuneLowlevel(chan, P, nextRealChange(chan, P), logicalBefore(chan, P) - logicalAt(chan, P))
      if detuneAt(chan, P) == detuneBefore(chan, P) then
        deleteLowlevel('pb', pb)
      else
        if owner(chan, P) then markFake(chan, P) end
      end
    end

    local function assignPb(pb, update)
      if update.ppq and update.ppq ~= pb.ppq then
        local chan   = pb.chan
        local newVal = update.val or logicalAt(chan, pb.ppq)
        -- delete-and-readd is identity-preserving for the pb's stamp;
        -- carry the existing pb's extras forward, with `update`
        -- overriding any overlapping fields.
        local extras = util.assign(util.pick(pb,     'ppqL frame'),
                                   util.pick(update, 'ppqL frame'))
        deletePb(pb)
        addPb(util.assign({ chan = chan, ppq = update.ppq, val = newVal }, extras))
        return
      end
      if update.val then
        local chan, P = pb.chan, pb.ppq
        local delta = update.val - logicalAt(chan, P)
        unmarkFake(chan, P)
        retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
      end
      local rest = util.clone(update, { val = true, ppq = true })
      if next(rest) then assignLowlevel('pb', pb, rest) end
    end

    local function addNote(n)
      local D = n.detune
      if lastMuteSet[n.chan] then n.muted = true end
      if n.lane == 1 then
        local C     = detuneAt(n.chan, n.ppq)
        local nextP = nextNotePPQ(n.chan, n.ppq)
        if D ~= C and forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
        retuneLowlevel(n.chan, n.ppq, nextP, D - C)
        addLowlevel('note', util.assign(n, { detune = D }))
        reconcileBoundary(n.chan, nextP)
      else
        addLowlevel('note', util.assign(n, { detune = D }))
      end
    end

    local function deleteNote(n, keepPAs)
      if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel('pa', evt) end) end
      if n.lane ~= 1 then deleteLowlevel('note', n); return end
      local D1, D2 = detuneBefore(n.chan, n.ppq), detuneAt(n.chan, n.ppq)
      local nextP  = nextNotePPQ(n.chan, n.ppq)
      local pb     = pbAt(n.chan, n.ppq)
      if pb and pb.fake then deleteLowlevel('pb', pb) end
      deleteLowlevel('note', n)
      retuneLowlevel(n.chan, n.ppq, nextP, D1 - D2)
      reconcileBoundary(n.chan, nextP)
    end

    local function resizeNote(n, P1, P2)
      local col1  = n.lane == 1
      local shift = P1 - n.ppq
      if shift ~= 0 and P2 - n.endppq == shift then
        forEachAttachedPA(n, function(evt)
          assignLowlevel('pa', evt, { ppq = evt.ppq + shift })
        end)
      else
        local lastPA
        forEachAttachedPA(n, function(evt)
          if evt.ppq <= P1 or evt.ppq >= P2 then
            if evt.ppq <= P1 and (not lastPA or evt.ppq > lastPA.ppq) then lastPA = evt end
            deleteLowlevel('pa', evt)
          end
        end)
        if lastPA then assignLowlevel('note', n, { vel = lastPA.val }) end
      end

      if not col1 then
        assignLowlevel('note', n, { ppq = P1, endppq = P2 })
        return
      end

      -- col-1: withdraw detune at old seat, move, reapply at new. L is the
      -- logical pb the user authored at P1 *before* the move — if it
      -- differs from prevailing logical there we seat a real pb to carry it.
      local oldppq = n.ppq
      local D   = n.detune
      local L   = logicalAt(n.chan, P1)
      local C1  = detuneBefore(n.chan, oldppq)
      local NP1 = nextNotePPQ(n.chan, oldppq)
      local oldPb = pbAt(n.chan, oldppq)

      assignLowlevel('note', n, { ppq = P1, endppq = P2 })

      if oldPb and oldPb.fake then
        deleteLowlevel('pb', oldPb)
      end
      retuneLowlevel(n.chan, oldppq, NP1, C1 - D)
      -- The carry into NP1 has shifted from D to C1 (n no longer
      -- bridges); a previously-masked jump may now need its own
      -- absorber, or a previously-needed one may have collapsed.
      reconcileBoundary(n.chan, NP1)

      -- New seat: real pb wins over fake; pre-existing pb wins over
      -- both. logicalBefore(P1) is read after the boundary at NP1
      -- has been reconciled — placing the absorber there can change
      -- rawBefore at P1 in leapfrog moves.
      local C2 = detuneBefore(n.chan, P1)
      if L ~= logicalBefore(n.chan, P1) then
        forcePb(n.chan, P1)
      elseif D ~= C2 and forcePb(n.chan, P1) then
        markFake(n.chan, P1)
      end
      local NP2 = nextNotePPQ(n.chan, P1)
      retuneLowlevel(n.chan, P1, NP2, D - C2)
      reconcileBoundary(n.chan, NP2)
    end

    local function assignNote(n, update)
      if update.chan then print('um: not allowed to change channel of notes'); return end
      if update.lane then print('um: not allowed to change lane of notes'); return end

      if update.ppq ~= nil or update.endppq ~= nil then
        resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq)
        update.ppq, update.endppq = nil, nil
      end
      if update.pitch then
        forEachAttachedPA(n, function(e) assignLowlevel('pa', e, { pitch = update.pitch }) end)
      end
      if n.lane == 1 and update.detune ~= nil and update.detune ~= n.detune then
        local nextP = nextNotePPQ(n.chan, n.ppq)
        if forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
        retuneLowlevel(n.chan, n.ppq, nextP, update.detune - n.detune)
        -- Commit detune now so the boundary reconciliations below read
        -- post-update state. Our own seat may collapse (detune now
        -- matches prior); the next note's seat may flip either way —
        -- a previously-absorbed jump may erase, or a previously-absent
        -- jump may appear because the carry has shifted.
        assignLowlevel('note', n, { detune = update.detune })
        update.detune = nil
        reconcileBoundary(n.chan, n.ppq)
        reconcileBoundary(n.chan, nextP)
      end
      if next(update) then assignLowlevel('note', n, update) end
    end

    -- Same-(chan, pitch) overlap reconciliation in REALISED space. MIDI
    -- gives one voice per (chan, pitch); a sibling whose realised onset
    -- collides with ours must truncate or shorten regardless of intent
    -- geometry, so onsets are compared in n.ppq (realised). The truncate
    -- target lands in `endppq` — endppq stays intent in the sense that
    -- it's "the moment we intend to end" — but that intended end is now
    -- forced by the voice collision, hence a realised value. vm-side
    -- `delayRange` is the user-facing gate that prevents legitimate edits
    -- from creating these collisions in the first place.
    local function clearSameKeyRange(chan, pitch, P, Pend, selfEvt)
      local clampEnd = Pend
      local toDelete, toTruncate = {}, {}
      for _, n in pairs(notesByLoc) do
        if n ~= selfEvt and n.chan == chan and n.pitch == pitch then
          if n.ppq <= P and n.endppq > P then
            if n.ppq == P then util.add(toDelete, n)
            else util.add(toTruncate, n) end
          elseif clampEnd and n.ppq > P and n.ppq < clampEnd then
            clampEnd = n.ppq
          end
        end
      end
      for _, n in ipairs(toDelete)   do deleteNote(n) end
      for _, n in ipairs(toTruncate) do assignNote(n, { endppq = P }) end
      return clampEnd
    end

    ----- Public interface

    local um = {}

    function um:deleteEvent(evtType, evtOrLoc)
      local loc = type(evtOrLoc) == 'table' and evtOrLoc.loc or evtOrLoc
      if not loc then return end
      local evt = evtType == 'note' and notesByLoc[loc] or ccsByLoc[loc]

      if evtType == 'note' then
        if evt then deleteNote(evt) end
      elseif evtType == 'pb' then
        if evt then deletePb(evt) end
      else
        deleteLowlevel(evtType, evt or { loc = loc })
      end
    end

    -- Delay shifts only the note-on; endppq is intent and never carries
    -- the delay offset. A delay change with no ppq update pins intent
    -- and shifts realised onset by the delta.
    local function realiseNoteUpdate(evt, update)
      local dOld = delayToPPQ(evt.delay)
      local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
      if update.ppq ~= nil then
        update.ppq = update.ppq + dNew
      elseif dNew ~= dOld then
        update.ppq = evt.ppq + (dNew - dOld)
      end
    end

    -- opts.trustGeometry: caller asserts the batch is internally
    -- consistent (no new same-key overlaps introduced). Skips the
    -- per-write clamp; rebuild's group-by-pitch normalisation is the
    -- backstop. Used by reswing, whose monotone reparameterisation
    -- can't create overlaps that didn't exist in the source frame.
    function um:assignEvent(evtType, evtOrLoc, update, opts)
      local loc = type(evtOrLoc) == 'table' and evtOrLoc.loc or evtOrLoc
      if not loc then return end
      local evt = evtType == 'note' and notesByLoc[loc] or ccsByLoc[loc]

      if evtType == 'note' then
        if evt then
          realiseNoteUpdate(evt, update)
          if not (opts and opts.trustGeometry)
             and (update.pitch ~= nil or update.ppq ~= nil or update.endppq ~= nil) then
            local P     = update.ppq    or evt.ppq
            local Pend  = update.endppq or evt.endppq
            local pitch = update.pitch  or evt.pitch
            local clamped = clearSameKeyRange(evt.chan, pitch, P, Pend, evt)
            if clamped ~= Pend then update.endppq = clamped end
          end
          assignNote(evt, update)
        end
      elseif evtType == 'pb' then
        if evt then assignPb(evt, update) end
      else
        assignLowlevel(evtType, evt or { loc = loc }, update)
      end
    end

    function um:addEvent(evtType, evt)
      if evtType == 'note' then
        evt.detune = evt.detune or 0
        evt.delay  = evt.delay  or 0
        evt.lane   = evt.lane   or 1
        -- ppq shifts into realised so CSK can compare in realised space;
        -- endppq stays intent (delay is a realisation-level shift only).
        evt.ppq = evt.ppq + delayToPPQ(evt.delay)
        evt.endppq = clearSameKeyRange(evt.chan, evt.pitch, evt.ppq, evt.endppq, evt)
        addNote(evt)
      elseif evtType == 'pb' then
        addPb(evt)
      else
        addLowlevel(evtType, evt)
      end
    end

    ----- Flush: commit accumulated ops to mm.

    local flushing = false

    function um:flush()
      if #adds == 0 and #assigns == 0 and #deletes == 0 then return end

      -- Snapshot+clear before mm:modify: its callbacks can re-enter this
      -- um (rebuild → setMutedChannels → flush) and we mustn't re-emit.
      local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
      adds, assigns, deletes = {}, {}, {}

      for _, e in ipairs(flushAssigns) do
        if e.type == 'pb' and e.update.val ~= nil then
          e.update.val = centsToRaw(e.update.val)
        end
      end
      for _, a in ipairs(flushAdds) do
        if a.type == 'pb' then
          a.evt.val = centsToRaw(a.evt.val)
        end
      end
      table.sort(flushDeletes, function(a, b) return a.loc > b.loc end)

      mm:modify(function()
        for _, o in ipairs(flushAssigns) do
          if o.type == 'note' then mm:assignNote(o.loc, o.update)
          else mm:assignCC(o.loc, o.update) end
        end
        for _, o in ipairs(flushDeletes) do
          if o.type == 'note' then mm:deleteNote(o.loc)
          else mm:deleteCC(o.loc) end
        end
        for _, o in ipairs(flushAdds) do
          if o.type == 'note' then mm:addNote(o.evt)
          else mm:addCC(o.evt) end
        end
      end)
    end

    ----- Init: load local cache from mm.

    local function init()
      for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

      for loc, cc in mm:ccs() do
        local evt
        if cc.msgType == 'pb' then
          evt = util.pick(cc, 'ppq ppqL chan shape tension fake frame',
                          { val = rawToCents(cc.val), loc = loc })
          util.add(chans[evt.chan].pbs, evt)
        else
          evt = util.assign(cc, { loc = loc })
        end
        ccsByLoc[loc] = evt
      end
      for i = 1, 16 do sortByPPQ(chans[i].pbs) end

      for loc, n in mm:notes() do
        local evt = util.assign(n, { loc = loc })
        notesByLoc[loc] = evt
        if n.lane == 1 then
          util.add(chans[n.chan].notes, evt)
        end
      end
      for i = 1, 16 do sortByPPQ(chans[i].notes) end
    end

    init()
    return um
  end

  ----- Column allocation

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util.add(notes, { events = {} }), #notes
  end

  -- Overlap is judged in intent space: delay is a realisation-level
  -- shift and shouldn't affect which notes can share a column. endppq
  -- is already intent in storage, so only the note-on inverts delay.
  -- Same-pitch comparisons get a hard zero threshold — MIDI allows
  -- only one voice per (chan, pitch). Cross-column same-pitch
  -- non-overlap is held by the truncation pass and clearSameKeyRange;
  -- the per-pair threshold here is defence in depth.
  local function noteColumnAccepts(col, note)
    local lenient = cm:get('overlapOffset') * mm:resolution()
    local noteppqI    = note.ppq - delayToPPQ(note.delay or 0)
    local noteEndppqI = note.endppq
    local dominated = 0
    for _, evt in ipairs(col.events) do
      local evtppqI = evt.ppq - delayToPPQ(evt.delay or 0)
      if noteppqI == evtppqI then return false end
      if noteppqI < evt.endppq and evtppqI < noteEndppqI then
        local threshold = (evt.pitch == note.pitch) and 0 or lenient
        local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
        if overlapAmount > threshold then return false end
        dominated = dominated + 1
      end
    end
    return dominated < 2
  end

  local function allocateNoteColumn(channel, note)
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col and noteColumnAccepts(col, note) then
        return col, note.lane
      end
      if not col then
        -- Preferred lane doesn't exist yet — grow until it does.
        while #notes < note.lane do pushNoteCol(channel) end
        return notes[note.lane], note.lane
      end
      -- Exists but won't fit; fall through to first-fit / spill.
    end
    for i, col in ipairs(notes) do
      if noteColumnAccepts(col, note) then return col, i end
    end
    return pushNoteCol(channel)
  end

  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    local notes = channel.columns.notes
    for _, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.endppq and evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
          return col
        end
      end
    end
    for _, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.pitch == pitch then return col end
      end
    end
  end

  ---------- PUBLIC

  local tm = {}
  fire = util.installHooks(tm)

  ----- Rebuild

  local rebuilding = false

  function tm:rebuild(takeChanged)
    if rebuilding then return end
    rebuilding = true
    takeChanged = takeChanged or false

    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
    end

    -- 1) Seed detune/delay defaults (metadata-only write bypasses the lock)
    --    and truncate same-key overlaps so later passes see clean intervals.
    do
      local groups, work = {}, {}
      for loc, note in mm:notes() do
        if note.detune == nil or note.delay == nil then
          mm:assignNote(loc, { detune = note.detune or 0, delay = note.delay or 0 })
        end
        util.bucket(groups, note.chan .. '|' .. note.pitch,
                    { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        sortByPPQ(group)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            util.add(work, { loc = group[i].loc, endppq = group[i + 1].ppq })
          end
        end
      end
      if #work > 0 then
        mm:modify(function()
          for _, w in ipairs(work) do mm:assignNote(w.loc, { endppq = w.endppq }) end
        end)
      end
    end

    -- 2) Allocate note columns.
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      if note.lane ~= lane then
        mm:assignNote(loc, { lane = lane })
      end
      util.assign(note, { loc = loc, chan = util.REMOVE, lane = util.REMOVE })
      util.add(col.events, note)
    end

    -- 3) Single CC walk: pb, pa, cc, at, pc distribution. Pb accumulates
    --    per channel so column install can be gated on anyVisible.
    do
      local pbByChan = {}
      for loc, cc in mm:ccs() do
        local channel = channels[cc.chan]

        if cc.msgType == 'pb' then
          -- Prevailing col-1 note at-or-before cc.ppq supplies detune
          -- context; if it sits exactly at cc.ppq and cc.fake is set, it
          -- is also the host that lends its delay.
          local col1       = channel.columns.notes[1]
          local prevailing = col1 and util.seek(col1.events, 'at-or-before', cc.ppq) or nil
          local detune     = (prevailing and prevailing.detune) or 0
          local hostNote   = (cc.fake and prevailing and prevailing.ppq == cc.ppq) and prevailing or nil
          local hidden     = cc.fake and (cc.shape == nil or cc.shape == 'step')

          local pb = pbByChan[cc.chan] or { events = {}, anyVisible = false }
          pbByChan[cc.chan] = pb
          pb.anyVisible = pb.anyVisible or not hidden
          -- fake pbs inherit host delay so tidyCol shifts both into intent together
          util.add(pb.events, util.pick(cc, 'ppq ppqL shape tension frame', {
            loc    = loc,
            val    = util.round(rawToCents(cc.val) - detune),
            detune = detune,
            hidden = hidden,
            delay  = hostNote and hostNote.delay or nil,
          }))

        elseif cc.msgType == 'pa' then
          local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
          if noteCol then
            util.add(noteCol.events, util.pick(cc, 'ppq ppqL pitch frame', {
              type = 'pa', vel = cc.val, loc = loc,
            }))
          end

        elseif cc.msgType == 'cc' or cc.msgType == 'at' or cc.msgType == 'pc' then
          local col
          if cc.msgType == 'cc' then
            col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
            channel.columns.ccs[cc.cc] = col
          else
            col = channel.columns[cc.msgType] or { events = {} }
            channel.columns[cc.msgType] = col
          end
          util.add(col.events, util.pick(cc, 'ppq ppqL val shape tension frame', { loc = loc }))
        end
      end

      for chan, pb in pairs(pbByChan) do
        if pb.anyVisible then
          channels[chan].columns.pb = { events = pb.events }
        end
      end
    end

    -- 4) Reconcile with user-opened extras (high-water lane count, padding,
    --    empty materialisation).
    do
      local extras = cm:get('extraColumns')
      local grew   = false
      for i = 1, 16 do
        local c    = channels[i].columns
        local want = extras[i] or { notes = 1 }
        local n    = #c.notes
        if n > want.notes then
          want.notes = n
          extras[i] = want
          grew = true
        end
        while #c.notes < want.notes do pushNoteCol(channels[i]) end
        if want.pc then c.pc = c.pc or { events = {} } end
        if want.pb then c.pb = c.pb or { events = {} } end
        if want.at then c.at = c.at or { events = {} } end
        for ccNum in pairs(want.ccs or {}) do
          c.ccs[ccNum] = c.ccs[ccNum] or { cc = ccNum, events = {} }
        end
      end
      if grew then cm:set('take', 'extraColumns', extras) end
    end

    -- 5) Shift into intent frame and sort by intent ppq. Endppq is
    -- intent in storage too — only the note-on (or fake-pb anchor)
    -- carries the delay offset.
    local function tidyCol(col)
      for _, evt in ipairs(col.events) do
        local d = delayToPPQ(evt.delay)
        if d ~= 0 then evt.ppq = evt.ppq - d end
      end
      sortByPPQ(col.events)
    end
    for _, chan in ipairs(channels) do
      local c = chan.columns
      if c.pc then tidyCol(c.pc) end
      if c.pb then tidyCol(c.pb) end
      for _, col in ipairs(c.notes) do tidyCol(col) end
      if c.at then tidyCol(c.at) end
      for _, col in pairs(c.ccs) do tidyCol(col) end
    end

    um = createUpdateManager()
    rebuilding = false

    fire('rebuild', nil)
  end

  ----- Accessors

  function tm:getChannel(chan)
    return channels and channels[chan]
  end

  function tm:channels()
    local i = 0
    return function()
      i = i + 1
      local channel = channels[i]
      if channel then
        return i, channel
      end
    end
  end

  function tm:editCursor()
    if not (mm and mm:take()) then return end
    local editCursorTime = reaper.GetCursorPosition()
    return reaper.MIDI_GetPPQPosFromProjTime(mm:take(), editCursorTime)
  end

  function tm:length()
    return mm and mm:length()
  end

  function tm:resolution()
    return mm and mm:resolution()
  end

  function tm:timeSigs()
    return mm and mm:timeSigs() or {}
  end

  function tm:interpolate(A, B, ppq)
    return mm and mm:interpolate(A, B, ppq)
  end

  -- E_c: column is inner, global is outer (see docs/timing.md).
  function tm:swingSnapshot(override)
    local global, column = nil, {}
    if mm then
      local gSrc, cSrc
      if override then gSrc, cSrc = override.swing, override.colSwing
      else             gSrc, cSrc = cm:get('swing'), cm:get('colSwing')
      end
      global = resolveSlot(gSrc)
      if cSrc then
        for chan, name in pairs(cSrc) do column[chan] = resolveSlot(name) end
      end
    end
    return {
      global = global,
      column = column,
      fromLogical = function(chan, ppqL)
        local ppqI = ppqL
        local c = column[chan]
        if c      then ppqI = timing.applyFactors(c, ppqI) end
        if global then ppqI = timing.applyFactors(global, ppqI) end
        return ppqI
      end,
      toLogical = function(chan, ppqI)
        local ppqL = ppqI
        if global then ppqL = timing.unapplyFactors(global, ppqL) end
        local c = column[chan]
        if c      then ppqL = timing.unapplyFactors(c, ppqL) end
        return ppqL
      end,
    }
  end

  ----- Transport

  function tm:playFrom(ppq)
    if not (mm and mm:take()) then return end
    reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(mm:take(), ppq), false, false)
    reaper.Main_OnCommand(1007, 0)
  end

  function tm:play() reaper.Main_OnCommand(1007, 0) end
  function tm:stop() reaper.Main_OnCommand(1016, 0) end
  function tm:playPause() reaper.Main_OnCommand(40073, 0) end

  ----- Mutation

  function tm:deleteEvent(type, evt) um:deleteEvent(type, evt) end
  function tm:addEvent(type, evt) um:addEvent(type, evt) end
  function tm:assignEvent(type, evt, update, opts) um:assignEvent(type, evt, update, opts) end
  function tm:flush() um:flush() end

  ----- Mute

  function tm:setMutedChannels(set)
    lastMuteSet = util.clone(set or {})
    if not um then return end
    for _, ch in ipairs(channels) do
      local want = lastMuteSet[ch.chan] == true
      for _, col in ipairs(ch.columns.notes) do
        for _, n in ipairs(col.events) do
          if (n.muted == true) ~= want then
            um:assignEvent('note', n, { muted = want })
          end
        end
      end
    end
    um:flush()
  end

  ----- Lifecycle

  local vmOnlyKeys = { mutedChannels = true, soloedChannels = true }

  -- Forward reconciliation signals so subscribers above tm needn't reach into mm.
  -- takeSwapped is also captured into a transient flag and consumed by the next
  -- reload; mm guarantees the takeSwapped→reload firing order.
  local pendingTakeSwap = false
  tm:forward('notesDeduped',    mm)
  tm:forward('uuidsReassigned', mm)
  tm:forward('takeSwapped',     mm)
  mm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
  mm:subscribe('reload', function()
    tm:rebuild(pendingTakeSwap)
    pendingTakeSwap = false
  end)
  cm:subscribe('configChanged', function(change)
    if not vmOnlyKeys[change.key] then tm:rebuild(false) end
  end)
  tm:rebuild(true)
  return tm
end
