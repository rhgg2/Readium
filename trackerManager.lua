--------------------
-- newTrackerManager(midiManager, opts)
--
-- Factory that attaches to a MIDIManager, parses its MIDI data into
-- a tracker data structure, and provides functionality for updating
-- that data. Reparses automatically on any mutation of the MIDI data.
--
-- CONSTRUCTION
--   local tm = newTrackerManager(mm)
--     attach to MIDIManger mm
--   local tm = newTrackerManager(nil)
--     create empty, call tm:attach(mm) later
--
-- LIFECYCLE
--   tm:rebuild()    -- manually trigger a rebuild
--   tm:detach()     -- remove callback from the manager
--   tm:attach(mm)   -- attach to new MIDI manager mm
--
-- MESSAGING
--   tm:addCallback(fn)                -- add a callback function
--     On any mutation or reload, the manager will call 'fn' with the
--     signature fn(changes, tm), where tm is a reference to the manager,
--     and changes is a table of the form { take = false, data = true }
--     where the boolean values indicate whether the underlying take and/or
--     the take data (notes, cc, sysex) have changed.
--   tm:removeCallback(fn)             -- remove a callback function
--
-- PUBLIC DATA
--   tm:state()         -- the built tracker state table

--------------------

loadModule('util')
loadModule('midiManager')

local function print(...)
  return util:print(...)
end

--------------------

-- mm = midiManager to attach

function newTrackerManager(mm)

  ---------- PUBLIC DATA

  local tm = {}

  ---------- PRIVATE DATA & FUNCTIONS

  local state = {}

  --------------------
  -- Column ID scheme:
  --   note columns: 1, 2, ...
  --   CC columns: the CC number
  --   everything else: no ID
  --------------------

  local function addColumn(channel, type, id)
    if type == "note" then
      if id > 1 then label = ("Note " .. id)
      else label = "Note"
      end
    elseif type == "cc" then
      label = "CC" .. (id or "")
    elseif type == "pb" then
        label = "PB"
    elseif type == "at" then
      label = "AT"
    elseif type == "pa" then
      label = "PA"
    elseif colDef.type == "pc" then
      label = "PC"
    else
      label = ""
    end

    local col = {
      order  = #channel.columns + 1,
      type   = type,
      id     = id,
      label  = label,
      events = {},
    }
    channel.columns[#channel.columns + 1] = col
    return col
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

  local function noteColumnAccepts(col, notePpq, noteEndPpq, overlapThreshold)
    overlapThreshold = overlapThreshold or 0
    local dominated = 0
    for _, evt in ipairs(col.events) do
      if notePpq == evt.ppq then return false end
      if notePpq < evt.endppq and evt.ppq < noteEndPpq then
        local overlapAmount = math.min(evt.endppq, noteEndPpq)
          - math.max(evt.ppq, notePpq)
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

  local function addMissingPitchbends(channels, pbRange)
    pbRange = pbRange or 2

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
          for _, ins in ipairs(needsInsert) do
            mm:addCC(ins)
          end
      end)
    end
  end

  --------------------
  -- Core rebuild
  --------------------

  local rebuilding = false

  function tm:rebuild()
    if rebuilding then return end
    rebuilding = true

    -- All 16 channels always exist, always contain a note column
    local channels = {}
    for i = 1, 16 do
      channels[i] = {
        chan = i,
        label = 'Channel ' .. i,
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
    
    -- 3) Pitchbend: build logical pitchbend lane per channel
    --    Note lane 1 is used 
    local pbRange = 2

    addMissingPitchbends(channels, pbRange)

    for chan = 1, 16 do
      local notes = nil
      local col = nil
      local currentDetune = 0
      local currentCents = 0
      local noteIdx = 1
      local channel = channels[chan]

      for _, c in ipairs(channel.columns) do
        if c.id == "note:1" then
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

            col.events[#col.events + 1] = {
              ppq      = cc.ppq,
              val      = logicalCents,
              rawVal   = cc.val,
              detune   = currentDetune,
              hidden   = (logicalCents == lastLogicalCents),
            }
          end
        end
      end
    end

        -- 3) CCs, aftertouch, program change
    for loc, cc in mm:ccs() do
      local channel = channels[cc.chan]

      if cc.msgType == "pa" then
        -- Poly AT → attach to the note column owning that pitch
        local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
        if noteCol then
          noteCol.events[#noteCol.events + 1] = {
            ppq = cc.ppq, type = "pa", pitch = cc.pitch, val = cc.val, loc = loc,
          }
        else
          -- Orphaned poly AT → dedicated column
          local col = getOrCreateTypedColumn(channel, "pa")
          col.events[#col.events + 1] = {
            ppq = cc.ppq, pitch = cc.pitch, val = cc.val,
          }
        end

      elseif cc.msgType == "cc" then
        local col = getOrCreateTypedColumn(channel, "cc", cc.cc)
        col.events[#col.events + 1] = {
          ppq = cc.ppq, val = cc.val, loc = loc,
        }

      elseif cc.msgType == "at" then
        local col = getOrCreateTypedColumn(channel, "at")
        col.events[#col.events + 1] = {
          ppq = cc.ppq, val = cc.val, loc = loc,
        }

      elseif cc.msgType == "pc" then
        local col = getOrCreateTypedColumn(channel, "pc")
        col.events[#col.events + 1] = {
          ppq = cc.ppq, val = cc.val, loc = loc,
        }
      end
    end


    -- 4) Sysex / text events
    for loc, sx in mm:sysexes() do
      local midiChan = (sx.chan or 0) + 1
      local chan = channels[midiChan]
      local col = getOrCreateTypedColumn(chan, "sx")
      col.events[#col.events + 1] = {
        ppq     = sx.ppq,
        msgType = sx.msgType,
        val     = sx.val,
        loc     = loc,
      }
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
    
    -- 7) Assemble the take structure
    state = {
      channels = channels,
      ppq      = ppq,
      reso     = mm:reso(),
      length   = mm:length(),
    }

    rebuilding = false
  end

  -- Attach to/detach from midiManager
  
  function tm:attach(mm)
    if not mm then return end
  
    -- local overlapThreshold = 0 -- math.floor((opts.overlapThreshold or 0) * res)
    -- local trackOpts = opts.trackOpts or { pitchbendRange = 2, microtuningMode = 'pitchbend' }

    local function onChange(changes, _mm)
      if changes.data or changes.take then
        tm:rebuild()
      end
    end

    tm:detach()
    mm:addCallback(onChange)
    tm._callback = onChange
    tm:rebuild()
  end

  function tm:detach()
    if self._callback then mm:removeCallback(self._callback) end
    self._callback = nil
  end

  --- STATE DATA

  function tm:state()
    return state
  end

  -- edit cursor position in PPQ from start of take
  function tm:editCursor()
    if not mm:take() then return end
    local editCursorTime = reaper.GetCursorPosition()
    return reaper.MIDI_GetPPQPosFromProjTime(mm:take(), editCursorTime)
  end

  -- FACTORY BODY
  
  if mm then tm:attach(mm) end
  return tm
end
