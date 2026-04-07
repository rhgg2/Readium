--------------------
-- newTakeParser(takeManager, opts)
--
-- Factory that attaches to a TakeManager, parses its MIDI data into
-- the channel/column data structure, and rebuilds on any change.
--
-- opts:
--   overlapThreshold  (number) max overlap in quarter notes before
--                     a note is pushed to a new column. Default: 0
--   trackOpts         (table)  optional trackOpts to attach
--
-- Returns a parser object with:
--   parser.take        -- the built take data structure
--   parser:rebuild()   -- manually trigger a rebuild
--   parser:detach()    -- remove callback from the manager
--------------------

loadModule('util')
loadModule('takeManager')

local function print(...)
  return util:print(...)
end

--------------------

function newTakeParser(mgr, opts)
  opts = opts or {}
  local parser = {}

  local res = mgr:reso()
  local overlapThreshold = math.floor((opts.overlapThreshold or 0) * res)
  local trackOpts = opts.trackOpts or { pitchbendRange = 2, microtuningMode = 'pitchbend' }

  parser.take = nil

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

  local function noteColumnAccepts(col, notePpq, noteEndPpq)
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
          for _, cc in mgr:ccs() do
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
      mgr:modify(function()
          for _, ins in ipairs(needsInsert) do
            mgr:addCC(ins)
          end
      end)
    end
  end
  
  --------------------
  -- Core rebuild
  --------------------

  local rebuilding = false

  function parser:rebuild()
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
    for loc, note in mgr:notes() do
      if not note.detune then
        mgr:assignNote(loc, { detune = 0 })
      end
    end

    -- 2) Assign notes to note columns
    for loc, note in mgr:notes() do
      local channel = channels[note.chan]
      local col  = allocateNoteColumn(channel, note)
      if not note.colID or note.colID ~= col.id then
        mgr:assignNote(loc, { colID = col.id })
      end
      util:assign(note, {loc = loc, chan = util.REMOVE, colID = util.REMOVE })
      col.events[#col.events + 1] = note
    end
    
    -- 3) Pitchbend: build logical pitchbend lane per channel
    --    Note lane 1 is used 
    local pbRange = trackOpts.pitchbendRange or 2

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
        for loc, cc in mgr:ccs() do
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
    for loc, cc in mgr:ccs() do
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
    for loc, sx in mgr:sysexes() do
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
    self.take = {
      opts     = trackOpts,
      channels = channels,
      ppq      = ppq,
      swing    = {},
      timeSig  = {},
    }

    rebuilding = false
  end

  --------------------
  -- Callback wiring
  --------------------

  local function onChange(changes, _mgr)
    if changes.data or changes.take then
      parser:rebuild()
    end
  end

  mgr:addCallback(onChange)
  parser._callback = onChange

  function parser:detach()
    mgr:removeCallback(self._callback)
  end

  -- Initial build
  if mgr.take then
    parser:rebuild()
  end

  return parser
end
