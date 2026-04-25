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

  local function resolveSlot(name, libOverride)
    local composite = libOverride and libOverride[name]
                   or timing.findShape(name, cm:get('swings'))
    if timing.isIdentity(composite) then return nil end
    local ppqPerQN = mm:resolution()
    local factors = {}
    for i, f in ipairs(composite) do
      local atom = timing.atoms[f.atom]
      if not atom then error('timing: unknown atom ' .. tostring(f.atom)) end
      factors[i] = { S = atom(f.amount), T = ppqPerQN * timing.periodQN(f.period) }
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

    local function forcePb(chan, P)
      if pbAt(chan, P) then return false end
      addLowlevel('pb', { ppq = P, chan = chan, val = rawAt(chan, P) })
      return true
    end

    local function markFake(n)
      local pb = pbAt(n.chan, n.ppq)
      if pb then assignLowlevel('pb', pb, { fake = true }) end
      assignLowlevel('note', n, { fakePb = true })
    end

    local function unmarkFake(chan, P)
      local pb = pbAt(chan, P)
      if not (pb and pb.fake) then return end
      assignLowlevel('pb', pb, { fake = util.REMOVE })
      local o = owner(chan, P)
      if o then assignLowlevel('note', o, { fakePb = util.REMOVE }) end
    end

    ----- High-level ops

    local function addPb(pb)
      local chan, P, L = pb.chan, pb.ppq, pb.val or 0
      local delta = L - logicalAt(chan, P)
      if not forcePb(chan, P) then unmarkFake(chan, P) end
      retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
    end

    local function deletePb(pb)
      local chan, P = pb.chan, pb.ppq
      retuneLowlevel(chan, P, nextRealChange(chan, P), logicalBefore(chan, P) - logicalAt(chan, P))
      if detuneAt(chan, P) == detuneBefore(chan, P) then
        deleteLowlevel('pb', pb)
      else
        local o = owner(chan, P)
        if o then markFake(o) end
      end
    end

    local function assignPb(pb, update)
      if update.ppq and update.ppq ~= pb.ppq then
        local chan   = pb.chan
        local newVal = update.val or logicalAt(chan, pb.ppq)
        deletePb(pb)
        addPb({ chan = chan, ppq = update.ppq, val = newVal })
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
        local C = detuneAt(n.chan, n.ppq)
        if D ~= C and forcePb(n.chan, n.ppq) then markFake(n) end
        retuneLowlevel(n.chan, n.ppq, nextNotePPQ(n.chan, n.ppq), D - C)
      end
      addLowlevel('note', util.assign(n, { detune = D }))
    end

    local function deleteNote(n, keepPAs)
      if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel('pa', evt) end) end
      local D1, D2 = detuneBefore(n.chan, n.ppq), detuneAt(n.chan, n.ppq)
      local pb = pbAt(n.chan, n.ppq)
      if pb and pb.fake then deleteLowlevel('pb', pb) end
      deleteLowlevel('note', n)
      retuneLowlevel(n.chan, n.ppq, nextNotePPQ(n.chan, n.ppq), D1 - D2)
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
      local oldPpq = n.ppq
      local D   = n.detune
      local L   = logicalAt(n.chan, P1)
      local C1  = detuneBefore(n.chan, oldPpq)
      local NP1 = nextNotePPQ(n.chan, oldPpq)
      local oldPb = pbAt(n.chan, oldPpq)

      assignLowlevel('note', n, { ppq = P1, endppq = P2 })

      if oldPb and oldPb.fake then
        deleteLowlevel('pb', oldPb)
        assignLowlevel('note', n, { fakePb = util.REMOVE })
      end
      retuneLowlevel(n.chan, oldPpq, NP1, C1 - D)

      -- New seat: real pb wins over fake; pre-existing pb wins over both.
      local C2 = detuneBefore(n.chan, P1)
      if L ~= logicalBefore(n.chan, P1) then
        forcePb(n.chan, P1)
      elseif D ~= C2 and forcePb(n.chan, P1) then
        markFake(n)
      end
      retuneLowlevel(n.chan, P1, nextNotePPQ(n.chan, P1), D - C2)
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
        if forcePb(n.chan, n.ppq) then markFake(n) end
        retuneLowlevel(n.chan, n.ppq, nextNotePPQ(n.chan, n.ppq), update.detune - n.detune)
        -- Boundary became redundant (detune matches prior, no raw step) — drop it.
        if update.detune == detuneBefore(n.chan, n.ppq)
           and rawAt(n.chan, n.ppq) == rawBefore(n.chan, n.ppq) then
          local pb = pbAt(n.chan, n.ppq)
          if pb then
            deleteLowlevel('pb', pb)
            if n.fakePb then assignLowlevel('note', n, { fakePb = util.REMOVE }) end
          end
        end
      end
      if next(update) then assignLowlevel('note', n, update) end
    end

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

    -- A delay change with no ppq update pins intent and shifts realised
    -- by the delay delta.
    local function realiseNoteUpdate(evt, update)
      local dOld = delayToPPQ(evt.delay)
      local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
      if update.ppq ~= nil then
        update.ppq = update.ppq + dNew
      elseif dNew ~= dOld then
        update.ppq = evt.ppq + (dNew - dOld)
      end
      if update.endppq ~= nil then
        update.endppq = update.endppq + dNew
      elseif dNew ~= dOld and evt.endppq then
        update.endppq = evt.endppq + (dNew - dOld)
      end
    end

    function um:assignEvent(evtType, evtOrLoc, update)
      local loc = type(evtOrLoc) == 'table' and evtOrLoc.loc or evtOrLoc
      if not loc then return end
      local evt = evtType == 'note' and notesByLoc[loc] or ccsByLoc[loc]

      if evtType == 'note' then
        if evt then
          realiseNoteUpdate(evt, update)
          if update.pitch ~= nil or update.ppq ~= nil or update.endppq ~= nil then
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
        local d = delayToPPQ(evt.delay)
        if d ~= 0 then
          evt.ppq = evt.ppq + d
          if evt.endppq then evt.endppq = evt.endppq + d end
        end
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
          evt = { ppq = cc.ppq, chan = cc.chan, val = rawToCents(cc.val), loc = loc,
                  shape = cc.shape, tension = cc.tension }
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
          if n.fakePb then
            local pb = pbAt(n.chan, n.ppq)
            if pb then pb.fake = true end
          end
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

  local function noteColumnAccepts(col, notePpq, noteEndPpq)
    local overlapThreshold = cm:get('overlapOffset') * mm:resolution()
    local dominated = 0
    for _, evt in ipairs(col.events) do
      if notePpq == evt.ppq then return false end
      if notePpq < evt.endppq and evt.ppq < noteEndPpq then
        local overlapAmount = math.min(evt.endppq, noteEndPpq) - math.max(evt.ppq, notePpq)
        if overlapAmount > overlapThreshold then
          return false
        end
        dominated = dominated + 1
      end
    end
    return dominated < 2
  end

  local function allocateNoteColumn(channel, note)
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col and noteColumnAccepts(col, note.ppq, note.endppq) then
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
      if noteColumnAccepts(col, note.ppq, note.endppq) then return col, i end
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

  function tm:rebuild(changed)
    if rebuilding then return end
    rebuilding = true

    changed = changed or { take = false, data = true }

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
        local key = note.chan .. '|' .. note.pitch
        groups[key] = groups[key] or {}
        util.add(groups[key], { loc = loc, ppq = note.ppq, endppq = note.endppq })
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
          -- One scan over col-1 resolves both detune context (latest note
          -- at-or-before cc.ppq) and fakePb host (note exactly at cc.ppq).
          local col1      = channel.columns.notes[1]
          local notes     = (col1 and col1.events) or {}
          local fakeNote, prevailing
          for _, n in ipairs(notes) do
            if n.ppq == cc.ppq and n.fakePb then fakeNote = n end
            if n.ppq <= cc.ppq and (not prevailing or n.ppq > prevailing.ppq) then
              prevailing = n
            end
          end
          local detune = (prevailing and prevailing.detune) or 0
          local hidden = fakeNote and (cc.shape == nil or cc.shape == 'step')

          local pb = pbByChan[cc.chan] or { events = {}, anyVisible = false }
          pbByChan[cc.chan] = pb
          pb.anyVisible = pb.anyVisible or not hidden
          util.add(pb.events, {
            loc     = loc,
            ppq     = cc.ppq,
            val     = util.round(rawToCents(cc.val) - detune),
            detune  = detune,
            hidden  = hidden,
            shape   = cc.shape,
            tension = cc.tension,
            -- fake pbs inherit host delay so tidyCol shifts both into intent together
            delay   = fakeNote and fakeNote.delay or nil,
          })

        elseif cc.msgType == 'pa' then
          local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
          if noteCol then
            util.add(noteCol.events, {
              ppq = cc.ppq, type = 'pa', pitch = cc.pitch, vel = cc.val, loc = loc
            })
          end

        elseif cc.msgType == 'cc' then
          local col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
          channel.columns.ccs[cc.cc] = col
          util.add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc, shape = cc.shape, tension = cc.tension })

        elseif cc.msgType == 'at' or cc.msgType == 'pc' then
          local col = channel.columns[cc.msgType] or { events = {} }
          channel.columns[cc.msgType] = col
          util.add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc, shape = cc.shape, tension = cc.tension })
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

    -- 5) Shift into intent frame and sort by intent ppq.
    local function tidyCol(col)
      for _, evt in ipairs(col.events) do
        local d = delayToPPQ(evt.delay)
        if d ~= 0 then
          evt.ppq = evt.ppq - d
          if evt.endppq then evt.endppq = evt.endppq - d end
        end
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

    fire(changed, tm)
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

  -- E_c: column is inner, global is outer (see design/swing.md).
  function tm:swingSnapshot(override)
    local global, column = nil, {}
    if mm then
      local gSrc, cSrc, libO
      if override then gSrc, cSrc, libO = override.swing, override.colSwing, override.libOverride
      else             gSrc, cSrc       = cm:get('swing'), cm:get('colSwing')
      end
      global = resolveSlot(gSrc, libO)
      if cSrc then
        for chan, name in pairs(cSrc) do column[chan] = resolveSlot(name, libO) end
      end
    end
    return {
      global = global,
      column = column,
      apply = function(chan, ppq)
        local c = column[chan]
        if c      then ppq = timing.applyFactors(c, ppq) end
        if global then ppq = timing.applyFactors(global, ppq) end
        return ppq
      end,
      unapply = function(chan, ppq)
        if global then ppq = timing.unapplyFactors(global, ppq) end
        local c = column[chan]
        if c      then ppq = timing.unapplyFactors(c, ppq) end
        return ppq
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
  function tm:assignEvent(type, evt, update) um:assignEvent(type, evt, update) end
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

  local callback = function(changed, _mm)
    if changed.data or changed.take then
      tm:rebuild(changed)
    end
  end

  local vmOnlyKeys = { mutedChannels = true, soloedChannels = true }

  local configCallback = function(changed, _cm)
    if changed.config and not vmOnlyKeys[changed.key] then
      tm:rebuild({ take = false, data = true })
    end
  end

  mm:addCallback(callback)
  cm:addCallback(configCallback)
  tm:rebuild({ take = true, data = true })
  return tm
end
