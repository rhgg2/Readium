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
--     label   : string ("Channel 1", etc.)
--     columns : array of column tables
--
--   Each column table contains:
--     order  : number (position within the channel after sorting)
--     type   : string ("note", "cc", "pb", "at", "pa", "pc")
--     id     : number or nil (note columns: 1, 2, ...; cc columns: CC number)
--     label  : string ("Note", "Note 2", "CC74", "PB", etc.)
--     events : array of event tables, sorted by ppq
--
-- GLOBAL DATA
--   tm:length()       -- take length in PPQ (delegated to midiManager)
--   tm:reso()         -- PPQ per quarter note (delegated to midiManager)
--   tm:editCursor()   -- edit cursor position in PPQ relative to the take start
--------------------

loadModule('util')
loadModule('midiManager')

local function print(...)
  return util:print(...)
end

--------------------

function newTrackerManager(mm, cm)

  ---------- PRIVATE DATA & FUNCTIONS

  local channels = {}

  local callbacks = {}

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  --------------------
  -- Column ID scheme:
  --   note columns: 1, 2, ...
  --   CC columns: the CC number
  --   everything else: no ID
  --------------------

  local function addColumn(channel, type, id)
    local colLabels = {
      note = id and id > 1 and ("Note " .. id) or " Note",
      cc   = "CC" .. (id or ""),
      pb   = " PB",
      at   = "AT",
      pa   = "PA",
      pc   = "PC",
    }

    return util:add(channel.columns, {
      order  = #channel.columns + 1,
      type   = type,
      id     = id,
      label  = colLabels[type] or "",
      events = {},
    })
  end
  
  local function addNoteColumn(channel)
    local maxId = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' and col.id > maxId then maxId = col.id end
    end
    return addColumn(channel, "note", maxId + 1)
  end

  local function getOrCreateTypedColumn(channel, colType, colId, extra)
    local returnCol
    for _, col in ipairs(channel.columns) do
      if col.type == colType and col.id == colId then
        returnCol = col
        break
      end
    end
    returnCol = returnCol or addColumn(channel, colType, colId)
    if extra then util:assign(returnCol, extra) end
    return returnCol
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
    local overlapThreshold = cfg("overlapOffset", 0) * mm:reso()
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
    if note.colID then
      local needsRealloc = false
      for _, col in ipairs(channel.columns) do
        if col.id == note.colID then
          -- found matching note column
          if noteColumnAccepts(col, note.ppq, note.endppq) then
            -- accepts the note, so just return the column
            return col
          else
            -- we will need to find a new home for the note
            needsRealloc = true
            break
          end
        end
      end
      if not needsRealloc then
        -- didn't find a matching note column, so create one
        return addColumn(channel, "note", note.colID)
      end
    end
    -- didn't match existing note colID, or matched and didn't fit
    for _, col in ipairs(channel.columns) do
      if col.type == "note" and noteColumnAccepts(col, note.ppq, note.endppq) then
        return col
      end
    end
    return addNoteColumn(channel)
  end

  --------------------
  -- Poly aftertouch: find the note column containing the target pitch
  --------------------

  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    for _, col in ipairs(channel.columns) do
      if col.type == "note" then
        for _, evt in ipairs(col.events) do
          if evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
            return col
          end
        end
      end
    end
    for _, col in ipairs(channel.columns) do
      if col.type == "note" then
        for _, evt in ipairs(col.events) do
          if evt.pitch == pitch then return col end
        end
      end
    end
    return nil
  end

  --------------------
  -- Tuning: add missing pitchbend events for "pitchbend" mode
  -- Precondition: all events have a "detune" parameter
  --------------------

  local function addMissingPitchbends()
    local pbRange = cfg("pbRange", 2)

    local toInsert = {}
    
    for chan, channel in ipairs(channels) do
      for _, col in ipairs(channel.columns) do
        
        -- pitchbend data is keyed to the first note column;
        -- microtuning and secondary note columns shouldn't be mixed
        
        if col.type == "note" and col.id == 1 then
          local currentRaw = 4096
          local currentCents = 0
          local currentLogical = 0
          local loc = 1
          local nextNote
      
          -- Iterate over raw pb messages for this channel
          for _, cc in mm:ccs() do
            if cc.chan == chan and cc.msgType == "pb" then
              -- iterate over all notes up to this pitchbend message
              nextNote = col.events[loc]
              while nextNote and nextNote.ppq < cc.ppq do
                local newLogical = currentCents - nextNote.detune
                if newLogical ~= currentLogical then
                  currentLogical = newLogical
                  toInsert[#toInsert + 1] = {
                    ppq = nextNote.ppq,
                    chan = chan,
                    msgType = "pb",
                    val = currentRaw,  -- whatever pb is already in effect
                  }
                end
                loc = loc + 1
                nextNote = col.events[loc]
              end
              -- now update currentRaw and currentCents
              currentRaw = cc.val
              currentCents = (cc.val / 8192) * pbRange * 100
            end
          end

          -- handle notes after last pitchbend
          while nextNote do
            local newLogical = currentCents - nextNote.detune
            if newLogical ~= currentLogical then
              currentLogical = newLogical
              toInsert[#toInsert + 1] = {
                ppq = nextNote.ppq,
                chan = chan,
                msgType = "pb",
                val = currentRaw,  -- whatever pb is already in effect
              }
            end
            loc = loc + 1
            nextNote = col.events[loc]
          end
        end
      end
    end
    
    if #toInsert > 0 then
      mm:modify(function()
          for _, ins in ipairs(toInsert) do
            mm:addCC(ins)
          end
      end)
    end
  end

  --------------------
  -- PUBLIC FUNCTIONS
  --------------------

  local tm = {}

  --------------------
  -- Core rebuild
  --------------------

  local rebuilding = false

  -- argument tracks whether take and/or underlying data have changed
  function tm:rebuild(changed)
    if rebuilding then return end
    rebuilding = true

    changed = changed or { take = false, data = true }

    -- All 16 channels always exist, always contain a note column
    channels = {}
    for i = 1, 16 do
      channels[i] = {
        chan = i,
        label = 'Ch ' .. i,
        columns = { },
      }
      addNoteColumn(channels[i])
    end

    -- 1) Assign missing metadata to notes
    for loc, note in mm:notes() do
      if not note.detune then
        mm:assignNote(loc, { detune = 0 })
      end
    end

    -- 2) Assign notes to note columns
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col  = allocateNoteColumn(channel, note)
      if not note.colID or note.colID ~= col.id then
        mm:assignNote(loc, { colID = col.id })
      end
      util:assign(note, {loc = loc, chan = util.REMOVE, colID = util.REMOVE })
      col.events[#col.events + 1] = note
    end
    
    -- 2b) Compact note columns: remove empties, close gaps in IDs
    for _, channel in ipairs(channels) do
      local kept = {}
      for _, col in ipairs(channel.columns) do
        if col.type ~= "note" or #col.events > 0 then
          kept[#kept + 1] = col
        end
      end
      channel.columns = kept

      local newId = 0
      for _, col in ipairs(channel.columns) do
        if col.type == "note" then
          newId = newId + 1
          if col.id ~= newId then
            col.id = newId
            col.label = newId > 1 and ("Note " .. newId) or " Note"
            for _, evt in ipairs(col.events) do
              mm:assignNote(evt.loc, { colID = newId })
            end
          end
        end
      end
    end

    -- 3) Pitchbend: build logical pitchbend lane per channel
    --    Note lane 1 is used

    local pbRange = cfg("pbRange", 2)
    addMissingPitchbends()

    for chan = 1, 16 do
      local notes = nil
      local col = nil
      local currentDetune = 0
      local currentCents = 0
      local noteIdx = 1
      local channel = channels[chan]

      for _, c in ipairs(channel.columns) do
        if c.id == 1 then
          notes = c.events
          break
        end
      end

      if notes then
        for loc, cc in mm:ccs() do
          if cc.chan == chan and cc.msgType == "pb" then
            if not col then
              col = getOrCreateTypedColumn(channel, "pb")
            end

            -- Find detune just before this ppq
            while noteIdx <= #notes and notes[noteIdx].ppq < cc.ppq do
              currentDetune = notes[noteIdx].detune
              noteIdx = noteIdx + 1
            end
            local lastLogicalCents = currentCents - currentDetune
            
            -- Now AT this ppq
            while noteIdx <= #notes and notes[noteIdx].ppq <= cc.ppq do
              currentDetune = notes[noteIdx].detune
              noteIdx = noteIdx + 1
            end
            
            currentCents = (cc.val / 8192) * pbRange * 100
            local logicalCents = currentCents - currentDetune

            util:add(col.events, {
              loc      = loc,
              ppq      = cc.ppq,
              val      = logicalCents,
              rawVal   = cc.val,
              detune   = currentDetune,
              hidden   = (logicalCents == lastLogicalCents),
            })
          end
        end
      end
    end

    -- 4) CCs, aftertouch, program change
    for loc, cc in mm:ccs() do
      local channel = channels[cc.chan]

      if cc.msgType == "pa" then
        -- Poly AT → attach to the note column owning that pitch
        local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
        if noteCol then
          util:add(noteCol.events,{
            ppq = cc.ppq, type = "pa", pitch = cc.pitch, vel = cc.val, loc = loc
          })
        else
          -- Orphaned poly AT → dedicated column
          local col = getOrCreateTypedColumn(channel, "pa")
          util:add(col.events, {
            ppq = cc.ppq, pitch = cc.pitch, vel = cc.val,
          })
        end
      elseif cc.msgType == "cc" or cc.msgType == "at" or cc.msgType == "pc" then
        local col = getOrCreateTypedColumn(channel, "cc", cc.cc)
        util:add(col.events, {
          ppq = cc.ppq, val = cc.val, loc = loc,
        })
      end
    end


    -- 5) Sort every column's events by ppq
    for _, chan in ipairs(channels) do
      for _, col in ipairs(chan.columns) do
        table.sort(col.events, function(a, b) return a.ppq < b.ppq end)
      end
    end

    -- 6) Reorder columns: notes first, then everything else
    for _, chan in ipairs(channels) do
      table.sort(chan.columns, function(a, b)
        local aNote = a.type == "note" and 0 or 1
        local bNote = b.type == "note" and 0 or 1
        if aNote ~= bNote then return aNote < bNote end
        return a.order < b.order
      end)
      -- Reassign order to reflect final positions
      for i, col in ipairs(chan.columns) do
        col.order = i
      end
    end
    
    rebuilding = false
    
    -- callbacks
    for fn,_ in pairs(callbacks) do
      fn(changed, tm)
    end
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

  function tm:reso()
    return mm and mm:reso()
  end

  function tm:timeSigs()
    return mm and mm:timeSigs() or {}
  end

  -- EDITING

  function tm:deleteEvent(type, evt)
    mm:modify(function ()
      if type == 'note' then mm:deleteNote(evt.loc)
      else mm:deleteCC(evt.loc) end
    end)
  end

  function tm:addEvent(type, evt)
    mm:modify(function ()
      if type == 'note' then mm:addNote(evt)
      else mm:addCC(evt) end
    end)
  end

  function tm:assignEvent(type, evt, update)
    mm:modify(function ()
      if type == 'note' then mm:assignNote(evt.loc, update)
      else mm:assignCC(evt.loc, update) end
    end)
  end
  
  function tm:editCell(type, evt, field, value)
    print("editCell", type, "at", evt.loc or 0, "time", evt.ppq, field .. "=" .. value)
  end

  function tm:addEvents(type, evts)
    mm:modify(function()
      for _, evt in ipairs(evts) do
        if type == 'note' then mm:addNote(evt)
        else mm:addCC(evt) end
      end
    end)
  end

  function tm:assignEvents(type, evts)
    mm:modify(function()
      for _, pair in ipairs(evts) do
        local evt, update = pair[1], pair[2]
        if update.loc == util.REMOVE then
          if type == 'note' then mm:deleteNote(evt.loc)
          else mm:deleteCC(evt.loc) end
        else
          if type == 'note' then mm:assignNote(evt.loc, update)
          else mm:assignCC(evt.loc, update) end
        end
      end
    end)
  end

  function tm:deleteEvents(type, evts)
    mm:modify(function()
      for _, evt in ipairs(evts) do
        if type == 'note' then mm:deleteNote(evt.loc)
        else mm:deleteCC(evt.loc) end
      end
    end)
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

  --- MESSAGING

    -- Add callback function
  function tm:addCallback(fn)
    callbacks[fn] = true
  end

  -- Remove callback function
  function tm:removeCallback(fn)
    callbacks[fn] = nil
  end

  -- FACTORY BODY
  
  if mm and cm then tm:attach(mm, cm) end
  return tm
end
