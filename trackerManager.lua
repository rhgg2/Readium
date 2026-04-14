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

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  -- Deferred operation queue. Call deleteEvent/assignEvent/addEvent to
  -- collect mutations, then flush() to execute them all in one modify call.

  local queue = {}

  function deleteEvent(evtType, evtOrLoc)
    evt = type(evtOrLoc) == 'table' and evtOrLoc or { loc = evtOrLoc }
    util:add(queue, { op = 'delete', type = evtType, evt = evt })
  end

  function assignEvent(evtType, evtOrLoc, update)
    evt = type(evtOrLoc) == 'table' and evtOrLoc or { loc = evtOrLoc }
    util:add(queue, { op = 'assign', type = evtType, evt = evt, update = update })
  end

  function addEvent(evtType, evt)
    if evtType ~= 'note' then evt.msgType = evtType end
    util:add(queue, { op = 'add', type = evtType, evt = evt })
  end

  --------------------
  -- Cascade: PAs and (col-1) pbs ride along with their host note when
  -- the host's interval changes, is deleted, or is repitched.
  --
  --   PA is attached to its host by (chan, pitch) within the host's
  --       closed interval [ppq, endppq].
  --   pb  is attached to a col-1 host by "later-starting wins": among
  --       col-1 notes on the same channel that cover pb.ppq, the one
  --       with the greatest ppq owns it. Deleting that host takes the
  --       pb with it — pbs do not revert to an earlier note.
  --
  --   pb's interval is half-open [ppq, endppq); PA's is closed. The two
  --   cascade rules diverge only at the endppq boundary.
  --
  -- Cascades run at the start of flush() and re-enter the queue via
  -- deleteEvent/assignEvent, so the main classification loop picks them
  -- up uniformly.
  --------------------

  local function firstNoteCol(channel)
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then return col end
    end
  end

  local function pbOwnedBy(host, ppq)
    if not (host.ppq <= ppq and ppq < host.endppq) then return false end
    local channel = channels[host.chan]; if not channel then return false end
    local col = firstNoteCol(channel); if not col then return false end
    for _, n in ipairs(col.events) do
      if n.loc ~= host.loc and n.ppq > host.ppq
         and n.ppq <= ppq and n.endppq > ppq then
        return false  -- a later-starting lane-1 note covers this pb
      end
    end
    return true
  end

  -- Returns 'pa' / 'pb' / nil — the attachment type, if any.
  local function attachedTo(host, cc)
    if cc.chan ~= host.chan then return nil end
    if cc.msgType == 'pa' and cc.pitch == host.pitch
       and cc.ppq >= host.ppq and cc.ppq <= host.endppq then return 'pa' end
    if host.lane == 1 and cc.msgType == 'pb' and pbOwnedBy(host, cc.ppq) then return 'pb' end
    return nil
  end

  local function forEachAttached(host, fn)
    for loc, cc in mm:ccs() do
      local t = attachedTo(host, cc)
      if t then fn(t, loc, cc) end
    end
  end

  -- Host deleted: every attached event goes.
  local function cascadeDelete(host)
    forEachAttached(host, function(t, loc) deleteEvent(t, loc) end)
  end

  -- Host's interval becomes [newPpq, newEnd]. If both endpoints shift by
  -- the same delta it's a pure translation and attached events shift
  -- with it; otherwise the host is being resized (shrink, grow, delay)
  -- and events stay put. In either case, anything that no longer lies
  -- inside the new interval is deleted.
  local function cascadeInterval(host, newPpq, newEnd)
    local dPpq  = newPpq - host.ppq
    local shift = (dPpq == newEnd - host.endppq) and dPpq or 0
    forEachAttached(host, function(t, loc, cc)
      local newCCPpq = cc.ppq + shift
      local inRange
      if t == 'pa' then inRange = newCCPpq >= newPpq and newCCPpq <= newEnd
      else              inRange = newCCPpq >= newPpq and newCCPpq <  newEnd end
      if not inRange then    deleteEvent(t, loc)
      elseif shift ~= 0 then assignEvent(t, loc, { ppq = newCCPpq })
      end
    end)
  end

  -- Host repitched: attached PAs rewrite to the new pitch. pbs don't care.
  local function cascadeRepitch(host, newPitch)
    forEachAttached(host, function(t, loc)
      if t == 'pa' then assignEvent('pa', loc, { pitch = newPitch }) end
    end)
  end

  -- Dispatch queued note ops to their cascades. Snapshot the queue
  -- length so cascade-appended ops (which are never 'note') aren't
  -- reconsidered.
  local function cascadeNoteOps()
    for i = 1, #queue do
      local o = queue[i]
      if o.type == 'note' then
        local host = mm:getNote(o.evt.loc)
        if host then
          host.loc = o.evt.loc
          if o.op == 'delete' then
            cascadeDelete(host)
          elseif o.op == 'assign' then
            local u = o.update
            if u.ppq or u.endppq then
              cascadeInterval(host, u.ppq or host.ppq, u.endppq or host.endppq)
            end
            if u.pitch and u.pitch ~= host.pitch then
              cascadeRepitch(host, u.pitch)
            end
          end
        end
      end
    end
  end

  function flush()
    if #queue == 0 then return end
    cascadeNoteOps()
    local ops = queue
    queue = {}

    local deletes = {}
    for _, o in ipairs(ops) do
      if o.op == 'delete' then util:add(deletes, o) end
    end
    table.sort(deletes, function(a, b) return a.evt.loc > b.evt.loc end)

    mm:modify(function()
      for _, o in ipairs(ops) do
        if o.op == 'assign' then
          if o.type == 'note' then mm:assignNote(o.evt.loc, o.update)
          else mm:assignCC(o.evt.loc, o.update) end
        end
      end
      for _, o in ipairs(deletes) do
        if o.type == 'note' then mm:deleteNote(o.evt.loc)
        else mm:deleteCC(o.evt.loc) end
      end
      for _, o in ipairs(ops) do
        if o.op == 'add' then
          if o.type == 'note' then mm:addNote(o.evt)
          else mm:addCC(o.evt) end
        end
      end
    end)
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
          if evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
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
    return nil
  end

  --------------------
  -- Detune walker: streams through column-1 notes in ppq order, tracking the
  -- currently-active detune value. Cheap to use inline in a rebuild pass
  -- (O(N) total) and safe for one-shot ad-hoc lookups via detuneAt.
  --------------------

  local function newDetuneWalker(chan)
    local channel = channels[chan]
    local col1 = channel and firstNoteCol(channel)
    local notes = col1 and col1.events or {}
    local idx   = 1
    local w = { detune = 0 }
    function w:advanceToBefore(ppq)
      while idx <= #notes and notes[idx].ppq < ppq do
        self.detune = notes[idx].detune or 0
        idx = idx + 1
      end
      return self.detune
    end
    function w:advanceTo(ppq)
      while idx <= #notes and notes[idx].ppq <= ppq do
        self.detune = notes[idx].detune or 0
        idx = idx + 1
      end
      return self.detune
    end
    return w
  end

  local function detuneAt(chan, ppq)
    return newDetuneWalker(chan):advanceTo(ppq)
  end

  --------------------
  -- Tuning: add missing pitchbend events for 'pitchbend' mode
  -- Precondition: all events have a 'detune' parameter
  --------------------

  local function addMissingPitchbends()
    local pbRange = cfg('pbRange', 2)
    
    -- pitchbend data is keyed to the first note column per channel;
    -- microtuning and secondary note columns shouldn't be mixed.
    for chan, channel in ipairs(channels) do
      local col = firstNoteCol(channel)
      if col then
        local currentRaw = 0
        local currentCents = 0
        local currentLogical = 0
        local loc = 1
        local nextNote

        -- Iterate over raw pb messages for this channel
        for _, cc in mm:ccs() do
          if cc.chan == chan and cc.msgType == 'pb' then
            -- iterate over all notes strictly before this pitchbend
            nextNote = col.events[loc]
            while nextNote and nextNote.ppq < cc.ppq do
              local newLogical = currentCents - nextNote.detune
              if newLogical ~= currentLogical then
                currentLogical = newLogical
                addEvent('pb', {
                  ppq = nextNote.ppq,
                  chan = chan,
                  msgType = 'pb',
                  val = currentRaw,
                })
              end
              loc = loc + 1
              nextNote = col.events[loc]
            end
            -- adopt this pb's value
            currentRaw = cc.val
            currentCents = (cc.val / 8192) * pbRange * 100
            -- a note sitting exactly on this pb is already covered by it;
            -- consume it and sync currentLogical so later comparisons are correct
            if nextNote and nextNote.ppq == cc.ppq then
              currentLogical = currentCents - nextNote.detune
              loc = loc + 1
              nextNote = col.events[loc]
            end
          end
        end

        -- handle notes after last pitchbend
        while nextNote do
          local newLogical = currentCents - nextNote.detune
          if newLogical ~= currentLogical then
            currentLogical = newLogical
            addEvent('pb', {
              ppq = nextNote.ppq,
              chan = chan,
              msgType = 'pb',
              val = currentRaw,  -- whatever pb is already in effect
            })
          end
          loc = loc + 1
          nextNote = col.events[loc]
        end
      end
    end
    flush()
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

    -- Seed each channel with the configured number of note columns. The
    -- allocator may grow this further when a lane-less note can't fit;
    -- we persist any growth back to cfg at the end of rebuild so the
    -- column count is stable across future rebuilds.
    local noteColsCfg = cfg('noteColumns', {}) or {}
    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = {} }
      for _ = 1, math.max(noteColsCfg[i] or 1, 1) do
        addColumn(channels[i], 'note')
      end
    end

    -- 1) Truncate overlapping notes on the same channel and pitch.
    --      The earlier note is clipped to end where the later one begins.
    do
      local groups = {}
      for loc, note in mm:notes() do
        local key = note.chan .. '|' .. note.pitch
        if not groups[key] then groups[key] = {} end
        util:add(groups[key], { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.ppq < b.ppq end)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            assignEvent('note', group[i].loc,  { endppq = group[i + 1].ppq })
          end
        end
      end
    end
    flush()

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

    -- 3) Pitchbend: build logical pitchbend lane per channel
    --    Note lane 1 is used

    local pbRange = cfg('pbRange', 2)
    addMissingPitchbends()

    for chan = 1, 16 do
      local channel      = channels[chan]
      local col          = nil
      local currentCents = 0
      local w            = newDetuneWalker(chan)

      for loc, cc in mm:ccs() do
        if cc.chan == chan and cc.msgType == 'pb' then
          if not col then col = getOrCreateSingletonColumn(channel, 'pb') end

          local lastLogicalCents = math.floor(currentCents - w:advanceToBefore(cc.ppq) + 0.5)
          local currentDetune    = w:advanceTo(cc.ppq)
          currentCents           = (cc.val / 8192) * pbRange * 100
          local logicalCents     = math.floor(currentCents - currentDetune + 0.5)

          util:add(col.events, {
            loc    = loc,
            ppq    = cc.ppq,
            val    = logicalCents,
            rawVal = cc.val,
            detune = currentDetune,
            hidden = (logicalCents == lastLogicalCents),
          })
        end
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
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc })
      elseif cc.msgType == 'at' or cc.msgType == 'pc' then
        local col = getOrCreateSingletonColumn(channel, cc.msgType)
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc })
      end
    end


    -- 5) Sort every column's events by ppq
    for _, chan in ipairs(channels) do
      for _, col in ipairs(chan.columns) do
        table.sort(col.events, function(a, b) return a.ppq < b.ppq end)
      end
    end

    -- 6) Canonicalise column order within each channel.
    for _, chan in ipairs(channels) do
      chan.columns = canonicaliseColumns(chan.columns)
    end
    
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

  -- DEFERRED QUEUE EXTERNAL INTERFACE

  -- pb events surface `val` in logical cents (raw pb cents minus the col-1
  -- detune active at that ppq); the MIDI layer wants raw 14-bit, so invert.
  local function centsToRaw(cents, chan, ppq)
    local lim = cfg('pbRange', 2) * 100
    local rawCents = cents + detuneAt(chan, ppq)
    return util:clamp(math.floor(rawCents * 8192 / lim + 0.5), -8192, 8191)
  end

  function tm:deleteEvent(type, evt)
    deleteEvent(type, evt)
  end

  function tm:addEvent(type, evt)
    if type == 'pb' and evt.val then
      evt = util:clone(evt); evt.val = centsToRaw(evt.val, evt.chan, evt.ppq)
    end
    addEvent(type, evt)
  end

  function tm:assignEvent(type, evt, update)
    if type == 'pb' and update.val then
      update = util:clone(update); update.val = centsToRaw(update.val, evt.chan, evt.ppq)
    end
    assignEvent(type, evt, update)
  end

  function tm:flush()
    flush()
  end

  -- LIFECYCLE

  local callback = function(changed, _mm)
    if changed.data or changed.take then
      tm:rebuild(changed)
    end
  end

  local configCallback = function(changed, _cm)
    if changed.config then
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
