--------------------
-- newTrackerManager
--
-- Factory that attaches to a midiManager, parses its MIDI data into a
-- tracker-style data structure with channels and typed columns, and
-- rebuilds automatically whenever the underlying MIDI data changes.
--
-- CONSTRUCTION
--   local tm = newTrackerManager(mm)   -- attach to midiManager mm
--   local tm = newTrackerManager(nil)  -- create empty, call tm:attach(mm) later
--
-- LIFECYCLE
--   tm:attach(mm)     -- attach to a midiManager; triggers an immediate rebuild
--   tm:detach()       -- remove callback from the attached midiManager
--   tm:rebuild(changed) -- manually trigger a full rebuild
--
-- MESSAGING
--   tm:addCallback(fn)                -- register a callback
--   tm:removeCallback(fn)             -- unregister a callback
--     On rebuild, registered callbacks are called with the signature
--     fn(changed, tm), where changed is a table of the form
--     { take = bool, data = bool } forwarded from the midiManager.
--
-- CHANNEL DATA
--   tm:getChannel(chan)               -- returns the channel table for chan (1..16)
--   tm:channels()                     -- iterator: for chan, channel in tm:channels()
--
--   Each channel table contains:
--     chan    : number (1..16)
--     columns : array of column tables
--
--   Each column table contains:
--     type   : string ('note', 'cc', 'pb', 'at', 'pa', 'pc')
--     events : array of event tables, sorted by ppq
--     cc     : cc columns only — the CC number.
--
--   Note columns carry no identity beyond their position among note
--   columns in the channel. A note's "lane" is that position, persisted
--   per note under the 'lane' key. Lane counts are stable across
--   rebuilds: cfg.noteColumns[chan] stores a per-channel count, tm grows
--   it when allocation needs more lanes, and lanes only shrink via
--   explicit user action in viewManager.
--
--   Note column lanes are stable across rebuilds: the cfg key
--   'noteColumns' stores a per-channel count, and tm grows it when
--   allocation needs more lanes. Lanes only shrink via explicit user
--   action in viewManager.
--
-- GLOBAL DATA
--   tm:length()       -- take length in PPQ (delegated to midiManager)
--   tm:resolution()   -- PPQ per quarter note (delegated to midiManager)
--   tm:editCursor()   -- edit cursor position in PPQ relative to the take start
--------------------

loadModule('util')
loadModule('midiManager')
loadModule('timing')

local function print(...)
  return util:print(...)
end

-- Canonical order of column kinds within a channel. The reading is a
-- performance timeline: program change sets up the sound, pitch bend
-- establishes a baseline, notes carry pitch, aftertouch adds expression,
-- cc carries modulation.
columnKindOrder = { 'pc', 'pb', 'note', 'at', 'cc' }

-- Canonicalise a column list: pc → pb → notes (preserving creation
-- order, i.e. lane order) → at → cc (by cc number). Returns a new list.
-- Exposed so viewManager can reuse the same rule on its grid-column slice.
function canonicaliseColumns(cols)
  local buckets = {}
  for _, t in ipairs(columnKindOrder) do buckets[t] = {} end
  for _, col in ipairs(cols) do
    local b = buckets[col.type]
    if b then util:add(b, col) end
  end
  table.sort(buckets.cc, function(a, b) return (a.cc or 0) < (b.cc or 0) end)
  local out = {}
  for _, t in ipairs(columnKindOrder) do
    for _, col in ipairs(buckets[t]) do util:add(out, col) end
  end
  return out
end

--------------------

function newTrackerManager(mm, cm)

  ---------- PRIVATE DATA & FUNCTIONS

  local channels = {}
  local fire  -- installed below, once tm exists
  local um    -- update manager; set by tm:rebuild
  local lastMuteSet = {}  -- { [chan] = true }, pushed by vm via tm:setMutedChannels

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  --------------------
  -- PB <-> cents conversion
  --------------------

  local function centsToRaw(cents)
    local lim = cfg('pbRange', 2) * 100
    return util:clamp(math.floor(cents * 8192 / lim + 0.5), -8192, 8191)
  end

  local function rawToCents(raw)
    local lim = cfg('pbRange', 2) * 100
    return math.floor(raw / 8192 * lim + 0.5)
  end

  --------------------
  -- Swing and delay
  --
  -- Slot schema is { name, period }, resolved against the swing registry
  -- (timing.presets + cfg.swings). Identity or missing slot ⇒ nil, which
  -- applySwing / unapplySwing treat as passthrough.
  --
  -- Both period and delay are in QN units (quarter notes), matching
  -- REAPER's native PPQ coordinate. Period is a QN scalar; delay is
  -- stored in signed milli-QN (1000 = one QN late). QN is preferred
  -- over "beat" because "beat" is time-sig-denominator-dependent and
  -- ambiguous in 6/8, 12/8, etc — a jig feel is period = {3,2} (dotted
  -- quarter) regardless of the denom.
  --
  -- Delay metadata lives on notes (defaulted to 0 by midiManager on
  -- load). Intent PPQ is the event's desired position; realised PPQ
  -- is what midiManager stores. The invariant
  --
  --     e.ppq = intentPPQ(e) + delayToPPQ(delay(e))
  --
  -- is maintained at the vm boundary: tm:rebuild strips delay from
  -- col.events before exposing them; um:addEvent / um:assignEvent
  -- add it back before routing writes to mm.
  --------------------

  local function delayToPPQ(d) return mm and mm:resolution() * (d or 0) / 1000 or 0 end

  local function resolveSlot(slot)
    if not slot then return nil end
    local shape = timing.findShape(slot.name, cfg('swings'))
    if not shape or shape == timing.id then return nil end
    return { shape = shape, period = slot.period }
  end

  local function slotPPQ(slot)
    return mm:resolution() * timing.periodQN(slot.period)
  end

  --------------------
  -- Update manager
  --
  -- Working model for col-1 notes and pb events. Public methods apply
  -- edits to local state and accumulate mm-facing ops; flush() commits
  -- them in one mm:modify call. pb.val is stored as logical cents
  -- throughout; conversion to raw happens at flush time.
  --
  -- Created once per tm:rebuild. The isRebuilding instance runs Stage 1
  -- reconciliation and flushes immediately; the ongoing instance handles
  -- user edits until the next rebuild.
  --------------------

  local function createUpdateManager(isRebuilding)
    local adds = {}
    local assigns = {}
    local deletes = {}
    local chans = {}
    local notesByLoc = {}
    local ccsByLoc = {}

    local function sortByPPQ(tbl)
      table.sort(tbl, function(a, b) return a.ppq < b.ppq end)
    end

    ----- Accessors: raw / logical / detune over the local state.

    local function owner(chan, P)
      return util:seek(chans[chan].notes, 'at-or-before', P, function(n) return n.endppq > P end)
    end

    local function detuneAt(chan, P)
      local n = util:seek(chans[chan].notes, 'at-or-before', P)
      return (n and n.detune) or 0
    end

    local function detuneBefore(chan, P)
      local n = util:seek(chans[chan].notes, 'before', P)
      return (n and n.detune) or 0
    end

    local function rawAt(chan, P)
      local pb = util:seek(chans[chan].pbs, 'at-or-before', P)
      return pb and pb.val or 0
    end

    local function rawBefore(chan, P)
      local pb = util:seek(chans[chan].pbs, 'before', P)
      return pb and pb.val or 0
    end

    local function pbAt(chan, P)
      local pb = util:seek(chans[chan].pbs, 'at-or-before', P)
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
      local pb = util:seek(chans[chan].pbs, 'after', P, function(e) return logicalAt(chan, e.ppq) ~= currentLogical end)
      return (pb and pb.ppq) or math.huge
    end

    local function nextRealChange(chan, P)
      local pb = util:seek(chans[chan].pbs, 'after', P, function(e) return not e.fake end)
      return (pb and pb.ppq) or math.huge
    end

    local function nextNotePPQ(chan, P)
      local n = util:seek(chans[chan].notes, 'after', P)
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
        local col1 = (evt.lane or 1) == 1
        if col1 then
          local tbl = chans[evt.chan].notes
          util:add(tbl, evt)
          sortByPPQ(tbl)
        end
      elseif evtType == 'pb' then
        local tbl = chans[evt.chan].pbs
        evt.msgType = 'pb'
        util:add(tbl, evt)
        sortByPPQ(tbl)
      else
        evt.msgType = evtType
      end
      util:add(adds, { type = evtType, evt = evt })
    end

    local function assignLowlevel(evtType, evt, update)
      util:assign(evt, update)
      if not evt.loc then return end
      for _, e in ipairs(assigns) do
        if e.loc == evt.loc and e.type == evtType then
          util:assign(e.update, update)
          return
        end
      end
      util:add(assigns, { type = evtType, loc = evt.loc, update = update })
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
        util:add(deletes, { type = evtType, loc = loc })
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

    -- Fake-pb housekeeping: a pb at a note boundary is "fake" iff it
    -- exists solely to absorb the raw step from the owner note's detune.
    -- forcePb seats a pb if none exists; markFake/unmarkFake keep the pb
    -- and the owner note's tag in sync.

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
      -- Pass any remaining fields (e.g. shape/tension) through to mm.
      local rest = util:clone(update, { val = true, ppq = true })
      if next(rest) then assignLowlevel('pb', pb, rest) end
    end

    local function addNote(n)
      local D = n.detune or 0
      if lastMuteSet[n.chan] then n.muted = true end
      if (n.lane or 1) == 1 then
        local C = detuneAt(n.chan, n.ppq)
        if D ~= C and forcePb(n.chan, n.ppq) then markFake(n) end
        retuneLowlevel(n.chan, n.ppq, nextNotePPQ(n.chan, n.ppq), D - C)
      end
      addLowlevel('note', util:assign(n, { detune = D }))
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
      local col1  = (n.lane or 1) == 1
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

      -- col-1 microtuning: withdraw n's detune at the old seat, move the
      -- note, then apply at the new seat. L is the logical pb the user
      -- authored at P1 *before* the move — if it differs from prevailing
      -- logical there we seat a real pb to carry it.
      local oldPpq = n.ppq
      local D   = n.detune
      local L   = logicalAt(n.chan, P1)
      local C1  = detuneBefore(n.chan, oldPpq)
      local NP1 = nextNotePPQ(n.chan, oldPpq)
      local oldPb = pbAt(n.chan, oldPpq)

      assignLowlevel('note', n, { ppq = P1, endppq = P2 })

      -- Withdraw at old seat.
      if oldPb and oldPb.fake then
        deleteLowlevel('pb', oldPb)
        assignLowlevel('note', n, { fakePb = util.REMOVE })
      end
      retuneLowlevel(n.chan, oldPpq, NP1, C1 - D)

      -- Apply at new seat. Real pb wins over fake; pre-existing pb wins over both.
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
      if (n.lane or 1) == 1 and update.detune ~= nil and update.detune ~= (n.detune or 0) then
        if forcePb(n.chan, n.ppq) then markFake(n) end
        retuneLowlevel(n.chan, n.ppq, nextNotePPQ(n.chan, n.ppq), update.detune - (n.detune or 0))
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

    -- vm speaks intent; tm internals (and mm) speak realised. Realise
    -- note ppq/endppq at the boundary. A delay change with no ppq update
    -- pins intent and shifts realised by the delay delta.
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
        local d = delayToPPQ(evt.delay)
        if d ~= 0 then
          evt.ppq = evt.ppq + d
          if evt.endppq then evt.endppq = evt.endppq + d end
        end
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

      for _, e in ipairs(assigns) do
        if e.type == 'pb' and e.update.val ~= nil then
          e.update.val = centsToRaw(e.update.val)
        end
      end
      for _, a in ipairs(adds) do
        if a.type == 'pb' then
          a.evt.val = centsToRaw(a.evt.val)
        end
      end
      table.sort(deletes, function(a, b) return a.loc > b.loc end)

      mm:modify(function()
        for _, o in ipairs(assigns) do
          if o.type == 'note' then mm:assignNote(o.loc, o.update)
          else mm:assignCC(o.loc, o.update) end
        end
        for _, o in ipairs(deletes) do
          if o.type == 'note' then mm:deleteNote(o.loc)
          else mm:deleteCC(o.loc) end
        end
        for _, o in ipairs(adds) do
          if o.type == 'note' then mm:addNote(o.evt)
          else mm:addCC(o.evt) end
        end
      end)
    end

    ----- Init: load state from mm; run Stage 1 if rebuilding.

    local function init()
      for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

      for loc, cc in mm:ccs() do
        local evt
        if cc.msgType == 'pb' then
          evt = { ppq = cc.ppq, chan = cc.chan, val = rawToCents(cc.val), loc = loc,
                  shape = cc.shape, tension = cc.tension }
          util:add(chans[evt.chan].pbs, evt)
        else
          evt = util:assign(cc, { loc = loc })
        end
        ccsByLoc[loc] = evt
      end
      for i = 1, 16 do sortByPPQ(chans[i].pbs) end

      for loc, n in mm:notes() do
        local evt = util:assign(n, { loc = loc })
        notesByLoc[loc] = evt
        if (n.lane or 1) == 1 then
          util:add(chans[n.chan].notes, evt)
          if n.fakePb then
            local pb = pbAt(n.chan, n.ppq)
            if pb then pb.fake = true end
          end
        end
      end
      for i = 1, 16 do sortByPPQ(chans[i].notes) end

      if isRebuilding then
        for c = 1, 16 do
          for _, n in ipairs(chans[c].notes) do
            if n.detune == nil then assignLowlevel('note', n, { detune = 0 }) end
          end
        end
        um:flush()
      end
    end

    init()
    return um
  end

  --------------------
  -- Column creation
  --   note / pb / pc / at : no identifying field.
  --   cc                  : carries .cc = CC number.
  --------------------

  local function addColumn(channel, type, cc)
    return util:add(channel.columns, { type = type, cc = cc, events = {} })
  end

  local function noteColCount(channel)
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then n = n + 1 end
    end
    return n
  end

  -- Singleton columns: pb, pc, at. One per channel.
  local function getOrCreateSingletonColumn(channel, colType)
    for _, col in ipairs(channel.columns) do
      if col.type == colType then return col end
    end
    return addColumn(channel, colType)
  end

  -- CC columns are keyed by cc number.
  local function getOrCreateCCColumn(channel, ccNum)
    for _, col in ipairs(channel.columns) do
      if col.type == 'cc' and col.cc == ccNum then return col end
    end
    return addColumn(channel, 'cc', ccNum)
  end

  --------------------
  -- Note-column allocation
  --
  -- Each note column can hold overlapping notes, but if a new note
  -- overlaps more than overlapThreshold ticks with two or more
  -- existing notes in that column, it spills to a new one.
  -- A second note at the same starting tick as an existing one
  -- will always be spilled.
  --------------------

  local function noteColumnAccepts(col, notePpq, noteEndPpq)
    local overlapThreshold = cfg('overlapOffset', 1/16) * mm:resolution()
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

  local function noteColAt(channel, lane)
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        n = n + 1
        if n == lane then return col end
      end
    end
  end

  -- Returns (col, lane) where lane is the 1-indexed position among the
  -- channel's note columns.
  local function allocateNoteColumn(channel, note)
    if note.lane then
      local col = noteColAt(channel, note.lane)
      if col and noteColumnAccepts(col, note.ppq, note.endppq) then
        return col, note.lane
      end
      if not col then
        -- Preferred lane doesn't exist yet — grow until it does.
        while noteColCount(channel) < note.lane do addColumn(channel, 'note') end
        return noteColAt(channel, note.lane), note.lane
      end
      -- Exists but won't fit. Fall through to first-fit / spill.
    end
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        n = n + 1
        if noteColumnAccepts(col, note.ppq, note.endppq) then return col, n end
      end
    end
    return addColumn(channel, 'note'), n + 1
  end

  --------------------
  -- Poly aftertouch: find the note column containing the target pitch
  --------------------

  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        for _, evt in ipairs(col.events) do
          if evt.endppq and evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
            return col
          end
        end
      end
    end
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        for _, evt in ipairs(col.events) do
          if evt.pitch == pitch then return col end
        end
      end
    end
    return
  end

  local function firstNoteCol(channel)
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then return col end
    end
  end

  --------------------
  -- PUBLIC FUNCTIONS
  --------------------

  local tm = {}
  fire = util:installHooks(tm)

  --------------------
  -- Core rebuild
  --------------------

  local rebuilding = false

  -- argument tracks whether take and/or underlying data have changed
  function tm:rebuild(changed)
    if rebuilding then return end
    rebuilding = true

    changed = changed or { take = false, data = true }

    local noteColsCfg = cfg('noteColumns', {}) or {}
    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = {} }
      for _ = 1, math.max(noteColsCfg[i] or 1, 1) do
        addColumn(channels[i], 'note')
      end
    end

    -- 1) Truncate overlapping notes on the same channel and pitch.
    do
      local groups, work = {}, {}
      for loc, note in mm:notes() do
        local key = note.chan .. '|' .. note.pitch
        if not groups[key] then groups[key] = {} end
        util:add(groups[key], { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.ppq < b.ppq end)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            util:add(work, { loc = group[i].loc, endppq = group[i + 1].ppq })
          end
        end
      end
      if #work > 0 then
        mm:modify(function()
          for _, w in ipairs(work) do mm:assignNote(w.loc, { endppq = w.endppq }) end
        end)
      end
    end

    -- 2) Assign notes to note columns. Rewrite 'lane' on any note whose
    --    persisted preference didn't match where it landed.
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      if note.lane ~= lane then
        mm:assignNote(loc, { lane = lane })
      end
      util:assign(note, { loc = loc, chan = util.REMOVE, lane = util.REMOVE })
      col.events[#col.events + 1] = note
    end

    -- 2b) Persist any growth in per-channel note column counts, so a
    --     later rebuild after notes are deleted doesn't make lanes vanish.
    do
      local grew = false
      for i = 1, 16 do
        local n = noteColCount(channels[i])
        if n > (noteColsCfg[i] or 1) then
          noteColsCfg[i] = n
          grew = true
        end
      end
      if grew and cm then
        cm:set('take', 'noteColumns', noteColsCfg)
      end
    end

    -- 3) Pitchbend: reconcile against the design invariants, then build
    --    the logical pb display lane per channel from the reconciled mm
    --    state. Stage 1 runs three steps (default detunes, reduce, add
    --    boundary pbs) inside the update manager, then flushes to mm;
    --    after flush mm reflects the invariant-satisfying state.
    createUpdateManager(true)

    local pbRange = cfg('pbRange', 2)
    for chan = 1, 16 do
      local channel = channels[chan]
      local col1    = firstNoteCol(channel)
      local notes   = (col1 and col1.events) or {}
      -- Detune prevailing at ppq P: latest-starting-note-wins over the
      -- already-built col-1 notes.
      local function detuneAtP(P)
        local best
        for _, n in ipairs(notes) do
          if n.ppq <= P then
            if not best or n.ppq > best.ppq then best = n end
          end
        end
        return (best and best.detune) or 0
      end

      local events, anyNonZero = {}, false
      for loc, cc in mm:ccs() do
        if cc.chan == chan and cc.msgType == 'pb' then
          local d = detuneAtP(cc.ppq)
          local currentCents = (cc.val / 8192) * pbRange * 100
          local logicalCents = math.floor(currentCents - d + 0.5)
          -- A col-1 note starting at cc.ppq with fakePb means this pb is
          -- the detune-boundary absorber for that note — hide from display.
          local hidden = util:seek(notes, 'at-or-before', cc.ppq,
                                   function(e) return e.ppq == cc.ppq and e.fakePb end) ~= nil
          util:add(events, {
            loc    = loc,
            ppq    = cc.ppq,
            val    = logicalCents,
            rawVal = cc.val,
            detune = d,
            hidden = hidden,
            shape  = cc.shape,
            tension = cc.tension,
          })
          if logicalCents ~= 0 then anyNonZero = true end
        end
      end
      if anyNonZero then
        local col = getOrCreateSingletonColumn(channel, 'pb')
        for _, e in ipairs(events) do util:add(col.events, e) end
      end
    end

    -- 4) CCs, aftertouch, program change
    for loc, cc in mm:ccs() do
      local channel = channels[cc.chan]

      if cc.msgType == 'pa' then
        -- Poly AT → attach to the note column owning that pitch (drop orphans)
        local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
        if noteCol then
          util:add(noteCol.events,{
            ppq = cc.ppq, type = 'pa', pitch = cc.pitch, vel = cc.val, loc = loc
          })
        end
      elseif cc.msgType == 'cc' then
        local col = getOrCreateCCColumn(channel, cc.cc)
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc,
                               shape = cc.shape, tension = cc.tension })
      elseif cc.msgType == 'at' or cc.msgType == 'pc' then
        local col = getOrCreateSingletonColumn(channel, cc.msgType)
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc,
                               shape = cc.shape, tension = cc.tension })
      end
    end


    -- 5) Strip delay from col.events so vm sees intent-frame PPQs.
    --    tm's own mutation state (update manager's chans[c].notes/pbs)
    --    stays in realised frame; only what we expose to vm is shifted.
    --    Realise-on-write in um:addEvent / um:assignEvent closes the loop.
    for _, chan in ipairs(channels) do
      for _, col in ipairs(chan.columns) do
        for _, evt in ipairs(col.events) do
          local d = delayToPPQ(evt.delay)
          if d ~= 0 then
            evt.ppq = evt.ppq - d
            if evt.endppq then evt.endppq = evt.endppq - d end
          end
        end
      end
    end

    -- 6) Sort every column's events by (intent) ppq.
    for _, chan in ipairs(channels) do
      for _, col in ipairs(chan.columns) do
        table.sort(col.events, function(a, b) return a.ppq < b.ppq end)
      end
    end

    -- 7) Canonicalise column order within each channel.
    for _, chan in ipairs(channels) do
      chan.columns = canonicaliseColumns(chan.columns)
    end

    um = createUpdateManager(false)
    rebuilding = false

    fire(changed, tm)
  end

  --- ACCESSORS

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

  -- GLOBAL DATA ACCESSORS

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

  function tm:swingGlobal()     return resolveSlot(cfg('swing')) end
  function tm:swingColumn(chan)
    local cs = cfg('colSwing')
    return cs and resolveSlot(cs[chan])
  end

  -- E_c forward: straight PPQ → realised PPQ on channel chan. Column
  -- inner, global outer (see design/swing.md). Missing slots pass through.
  function tm:applySwing(chan, ppq)
    local c = self:swingColumn(chan)
    if c then ppq = timing.tile(c.shape, slotPPQ(c), ppq) end
    local g = self:swingGlobal()
    if g then ppq = timing.tile(g.shape, slotPPQ(g), ppq) end
    return ppq
  end

  -- E_c inverse: realised PPQ → straight PPQ.
  function tm:unapplySwing(chan, ppq)
    local g = self:swingGlobal()
    if g then ppq = timing.tileInverse(g.shape, slotPPQ(g), ppq) end
    local c = self:swingColumn(chan)
    if c then ppq = timing.tileInverse(c.shape, slotPPQ(c), ppq) end
    return ppq
  end

  -- Snapshot of all slots resolved once, with T_ppq baked in. Use this
  -- in hot loops (rebuilds, renders) to avoid the per-call cfg reads in
  -- applySwing/unapplySwing. Always returns a valid pass-through struct
  -- when there's no context or no slots — callers needn't nil-check.
  function tm:swingSnapshot()
    local global, column
    if mm then
      local function withT(s)
        if s then s.T = slotPPQ(s) end
        return s
      end
      global = withT(resolveSlot(cfg('swing')))
      column = {}
      local cs = cfg('colSwing')
      if cs then
        for chan, slot in pairs(cs) do column[chan] = withT(resolveSlot(slot)) end
      end
    else
      column = {}
    end
    return {
      global = global,
      column = column,
      apply = function(chan, ppq)
        local c = column[chan]
        if c      then ppq = timing.tile(c.shape,      c.T, ppq) end
        if global then ppq = timing.tile(global.shape, global.T, ppq) end
        return ppq
      end,
      unapply = function(chan, ppq)
        if global then ppq = timing.tileInverse(global.shape, global.T, ppq) end
        local c = column[chan]
        if c      then ppq = timing.tileInverse(c.shape,      c.T, ppq) end
        return ppq
      end,
    }
  end

  -- Delay unit is signed milli-QN; 1000 means one QN late.
  function tm:delayToPPQ(d)  return delayToPPQ(d) end
  function tm:ppqToDelay(p)  return mm and 1000 * p / mm:resolution() or 0 end

  function tm:straightPPQ(n)    return n.ppq    - self:delayToPPQ(n.delay) end
  function tm:straightEndPPQ(n) return n.endppq - self:delayToPPQ(n.delay) end

  function tm:playFrom(ppq)
    if not (mm and mm:take()) then return end
    reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(mm:take(), ppq), false, false)
    reaper.Main_OnCommand(1007, 0)  -- Transport: Play
  end

  function tm:play()
    reaper.Main_OnCommand(1007, 0)
  end

  function tm:stop()
    reaper.Main_OnCommand(1016, 0)
  end

  function tm:playPause()
    reaper.Main_OnCommand(40073, 0)
  end

  -- MUTATION INTERFACE

  function tm:deleteEvent(type, evt)         um:deleteEvent(type, evt)         end
  function tm:addEvent(type, evt)            um:addEvent(type, evt)            end
  function tm:assignEvent(type, evt, update) um:assignEvent(type, evt, update) end
  function tm:flush()                        um:flush()                        end

  -- Channel mute: vm is the sole source of truth. It pushes the effective
  -- set (persistent mute ∪ solo-implied mute). tm idempotently syncs the
  -- REAPER-native muted flag on every note to match, and tags any
  -- subsequently-added notes via lastMuteSet in the update manager.
  function tm:setMutedChannels(set)
    lastMuteSet = util:clone(set or {})
    if not um then return end
    for _, ch in ipairs(channels) do
      local want = lastMuteSet[ch.chan] == true
      for _, col in ipairs(ch.columns) do
        if col.type == 'note' then
          for _, n in ipairs(col.events) do
            if (n.muted == true) ~= want then
              um:assignEvent('note', n, { muted = want })
            end
          end
        end
      end
    end
    um:flush()
  end

  --------------------
  -- Microtuning realisation
  --
  -- tm owns the demix between note intent (pitch + detune) and note
  -- realisation (raw pb events on the wire). The view layer speaks
  -- intent; tm keeps realisation in sync inside the update manager —
  -- no caller participates in the invariant.
  --------------------

  function tm:retuneNote(note, update)
    um:assignEvent('note', note, update)
  end

  -- LIFECYCLE

  local callback = function(changed, _mm)
    if changed.data or changed.take then
      tm:rebuild(changed)
    end
  end

  -- Keys owned purely by vm (render-time state) — tm has no structural
  -- dependency on them, so skip the full rebuild when one of these fires.
  local vmOnlyKeys = { mutedChannels = true, soloedChannels = true }

  local configCallback = function(changed, _cm)
    if changed.config and not vmOnlyKeys[changed.key] then
      tm:rebuild({ take = false, data = true })
    end
  end

  function tm:attach(newMM, newCM)
    if not (newMM and newCM) then return end

    self:detach()
    mm = newMM
    cm = newCM
    mm:addCallback(callback)
    cm:addCallback(configCallback)
    self:rebuild({ take = true, data = true })
  end

  function tm:detach()
    if mm then mm:removeCallback(callback) end
    if cm then cm:removeCallback(configCallback) end
  end

  -- FACTORY BODY

  if mm and cm then tm:attach(mm, cm) end
  return tm
end
