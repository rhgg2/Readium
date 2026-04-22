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
--     columns : dict keyed by kind —
--       pc, pb, at : singleton column or nil
--       notes      : dense array of note columns (index = lane)
--       ccs        : sparse dict of cc columns keyed by CC number
--
--   Each column table contains:
--     events : array of event tables, sorted by ppq
--     cc     : cc columns only — the CC number.
--
--   tm imposes no ordering on columns — that's a presentation concern
--   owned by vm.
--
--   Note columns carry no identity beyond their position among note
--   columns in the channel. A note's "lane" is that position, persisted
--   per note under the 'lane' key. Lane counts are stable across
--   rebuilds: cfg.extraColumns[chan].notes stores a per-channel
--   high-water lane count, tm grows it when allocation needs more
--   lanes, and lanes only shrink via explicit user action in vm.
--
--   cfg.extraColumns is the single source of "columns the user has
--   opened per channel", with shape:
--     { [chan] = { notes = <count>, pc = true, pb = true, at = true,
--                  ccs = { [ccNum] = true } } }
--   tm reconciles this with live MIDI during rebuild: any column
--   present in extras but not backed by events is materialised as
--   empty, so consumers see a uniform channel.columns irrespective of
--   whether a column is data-driven or user-opened.
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

function newTrackerManager(mm, cm)

  ---------- PRIVATE DATA & FUNCTIONS

  local channels = {}
  local fire  -- installed below, once tm exists
  local um    -- update manager; set by tm:rebuild
  local lastMuteSet = {}  -- { [chan] = true }, pushed by vm via tm:setMutedChannels

  local function sortByPPQ(tbl)
    table.sort(tbl, function(a, b) return a.ppq < b.ppq end)
  end

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  local function setcfg(lev, key, val)
    if cm then cm:set(lev, key, val) end
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
  -- A slot stores a name (string) — cfg.swing and cfg.colSwing[c] hold
  -- the name directly, no wrapper. The name resolves against cfg.swings
  -- (the project's composite library) to an ordered array of factors,
  -- each {atom, amount, period}. Missing name / identity composite ⇒
  -- nil, treated as passthrough by applySwing / unapplySwing.
  --
  -- Period (per factor) and delay are in QN units. Period is a QN
  -- scalar or {num, den}; delay is signed milli-QN (1000 = one QN
  -- late). QN is preferred over "beat" because "beat" is time-sig-
  -- denominator-dependent — a jig feel is period = {3,2} (dotted
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

  -- Round at source so the map is an integer bijection: every arithmetic
  -- use (intent ± delayToPPQ(d)) stays in ℤ, and realise/strip round-trip
  -- is algebraic rather than approximate.
  local function delayToPPQ(d) return mm and math.floor(mm:resolution() * (d or 0) / 1000 + 0.5) or 0 end

  -- Resolve a slot name to an array of realised factors {S, T} in PPQ,
  -- or nil for identity. S is the atom evaluated at its amount; T is
  -- the factor's period converted to PPQ against the current resolution.
  -- `libOverride`, if given, shadows cfg('swings') for named lookups —
  -- callers pass {[name]=composite} to realise a hypothetical library
  -- state (used during preset edits, where the authoring and target
  -- composites for the same name must be resolved side-by-side).
  local function resolveSlot(name, libOverride)
    local composite = libOverride and libOverride[name]
                   or timing.findShape(name, cfg('swings'))
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

  local function applyFactors(factors, ppq)
    for _, f in ipairs(factors) do ppq = timing.tile(f.S, f.T, ppq) end
    return ppq
  end

  local function unapplyFactors(factors, ppq)
    for i = #factors, 1, -1 do
      local f = factors[i]
      ppq = timing.tileInverse(f.S, f.T, ppq)
    end
    return ppq
  end

  --------------------
  -- Update manager
  --
  -- Working model for col-1 notes and pb events. Public methods apply
  -- edits to local state and accumulate mm-facing ops; flush() commits
  -- them in one mm:modify call. pb.val is stored as logical cents
  -- throughout; conversion to raw happens at flush time.
  --
  -- Re-created once per tm:rebuild so its view of mm matches tm's.
  --------------------

  local function createUpdateManager()
    local adds = {}
    local assigns = {}
    local deletes = {}
    local chans = {}
    local notesByLoc = {}
    local ccsByLoc = {}

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
        local col1 = evt.lane == 1
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
      local D = n.detune
      if lastMuteSet[n.chan] then n.muted = true end
      if n.lane == 1 then
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
        evt.detune = evt.detune or 0
        evt.delay  = evt.delay  or 0
        evt.lane   = evt.lane   or 1
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

      -- Snapshot and clear up front: mm:modify fires callbacks that can
      -- reach back into the same um (e.g. tm:rebuild → setMutedChannels →
      -- um:flush). Clearing before the modify stops the re-entrant flush
      -- from re-emitting ops already in flight.
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
        if n.lane == 1 then
          util:add(chans[n.chan].notes, evt)
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

  --------------------
  -- Column creation
  --
  -- Singletons (pc, pb, at) live at channel.columns[kind]; notes form a
  -- dense array at channel.columns.notes (index = lane); ccs a sparse
  -- dict at channel.columns.ccs keyed by CC number. All columns carry
  -- `events`; cc columns additionally carry `cc` (the CC number).
  --------------------

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util:add(notes, { events = {} }), #notes
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

  -- Returns (col, lane) where lane is the 1-indexed position in
  -- channel.columns.notes.
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
      -- Exists but won't fit. Fall through to first-fit / spill.
    end
    for i, col in ipairs(notes) do
      if noteColumnAccepts(col, note.ppq, note.endppq) then return col, i end
    end
    return pushNoteCol(channel)
  end

  --------------------
  -- Poly aftertouch: find the note column containing the target pitch
  --------------------

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

    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
    end

    -- 0) Seed default detune/delay on any note missing them. Metadata-only
    --    writes bypass the mm:modify lock and don't fire callbacks.
    for loc, n in mm:notes() do
      if n.detune == nil or n.delay == nil then
        mm:assignNote(loc, { detune = n.detune or 0, delay = n.delay or 0 })
      end
    end

    -- 1) Truncate overlapping notes on the same channel and pitch.
    do
      local groups, work = {}, {}
      for loc, note in mm:notes() do
        local key = note.chan .. '|' .. note.pitch
        groups[key] = groups[key] or {}
        util:add(groups[key], { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        sortByPPQ(group)
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

    -- 2) Assign notes to note columns, moving where necessary.
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      if note.lane ~= lane then
        mm:assignNote(loc, { lane = lane })
      end
      util:assign(note, { loc = loc, chan = util.REMOVE, lane = util.REMOVE })
      util:add(col.events, note)
    end

    -- 3) Pitchbend display column: expose logical (raw - detune) for col-1
    --    anchors, hiding pure detune-absorbers unless an interp shape pulls
    --    them back into view.
    for chan = 1, 16 do
      local channel = channels[chan]
      local col1    = channel.columns.notes[1]
      local notes   = (col1 and col1.events) or {}

      -- Detune prevailing at P: latest-starting note at or before P wins.
      -- `notes` is unsorted at this stage, so an O(n) scan rather than seek.
      local function detuneAtP(P)
        local best
        for _, n in ipairs(notes) do
          if n.ppq <= P and (not best or n.ppq > best.ppq) then best = n end
        end
        return (best and best.detune) or 0
      end

      local events, anyVisible = {}, false
      for loc, cc in mm:ccs() do
        if cc.chan == chan and cc.msgType == 'pb' then
          -- A col-1 note starting at cc.ppq with fakePb means this pb is
          -- the detune-boundary absorber for that note: inherit its delay
          -- so the display event travels with the note into intent frame.
          -- Hide unless interp shape pulls it back into view as a ramp anchor.
          local fakeNote
          for _, n in ipairs(notes) do
            if n.ppq == cc.ppq and n.fakePb then fakeNote = n; break end
          end
          local detune = detuneAtP(cc.ppq)
          local hidden = fakeNote and (cc.shape == nil or cc.shape == 'step')
          anyVisible = anyVisible or not hidden

          util:add(events, {
            loc     = loc,
            ppq     = cc.ppq,
            val     = util:round(rawToCents(cc.val) - detune),
            detune  = detune,
            hidden  = hidden,
            shape   = cc.shape,
            tension = cc.tension,
            delay   = fakeNote and fakeNote.delay or nil,
          })
        end
      end
      if anyVisible then
        channel.columns.pb = channel.columns.pb or { events = {} }
        for _, e in ipairs(events) do util:add(channel.columns.pb.events, e) end
      end
    end

    -- 4) CCs, aftertouch, program change
    for loc, cc in mm:ccs() do
      local channel = channels[cc.chan]

      if cc.msgType == 'pa' then
        -- attach to the note column owning that pitch
        local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
        if noteCol then
          util:add(noteCol.events,{
            ppq = cc.ppq, type = 'pa', pitch = cc.pitch, vel = cc.val, loc = loc
          })
        end
      elseif cc.msgType == 'cc' then
        local col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
        channel.columns.ccs[cc.cc] = col
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc, shape = cc.shape, tension = cc.tension })
      elseif cc.msgType == 'at' or cc.msgType == 'pc' then
        local col = channel.columns[cc.msgType] or { events = {} }
        channel.columns[cc.msgType] = col
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc, shape = cc.shape, tension = cc.tension })
      end
    end

    -- 4b) Reconcile with user-intent extras. Grow `extras[chan].notes`
    --     if live allocation exceeded it (high-water mark), then pad
    --     empty note lanes and seed singletons/ccs that the user has
    --     opened but that carry no events yet.
    do
      local extras = cfg('extraColumns') or {}
      local grew   = false
      for i = 1, 16 do
        local c    = channels[i].columns
        local want = extras[i] or { notes = 0 }
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
      if grew then setcfg('take', 'extraColumns', extras) end
    end

    -- 5) Strip delay (so vm sees intent-frame PPQs) and sort each
    --    column's events by (intent) ppq.
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
    if c then ppq = applyFactors(c, ppq) end
    local g = self:swingGlobal()
    if g then ppq = applyFactors(g, ppq) end
    return ppq
  end

  -- E_c inverse: realised PPQ → straight PPQ.
  function tm:unapplySwing(chan, ppq)
    local g = self:swingGlobal()
    if g then ppq = unapplyFactors(g, ppq) end
    local c = self:swingColumn(chan)
    if c then ppq = unapplyFactors(c, ppq) end
    return ppq
  end

  -- Snapshot of all slots resolved once, with atom PWLs and T_ppq baked
  -- in. Use this in hot loops (rebuilds, renders) to avoid the per-call
  -- cfg reads and composite materialisation in applySwing/unapplySwing.
  -- Always returns a valid pass-through struct when there's no context
  -- or no slots — callers needn't nil-check.
  function tm:swingSnapshot(override)
    local global, column = nil, {}
    if mm then
      local gSrc, cSrc, libO
      if override then gSrc, cSrc, libO = override.swing, override.colSwing, override.libOverride
      else             gSrc, cSrc       = cfg('swing'),   cfg('colSwing')
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
        if c      then ppq = applyFactors(c, ppq) end
        if global then ppq = applyFactors(global, ppq) end
        return ppq
      end,
      unapply = function(chan, ppq)
        if global then ppq = unapplyFactors(global, ppq) end
        local c = column[chan]
        if c      then ppq = unapplyFactors(c, ppq) end
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
