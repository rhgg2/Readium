--------------------
-- newMidiManager
--
-- Creates an abstraction layer over REAPER's MIDI take API, providing
-- UUID-based note identity, persistent per-note metadata via take
-- extension data, and a clean read/write interface for notes, CCs,
-- and sysex/text events.
--
-- On load, duplicate MIDI events are removed, every note is assigned
-- a unique UUID (stored as a REAPER notation event), and per-note
-- metadata is restored from the take's extension data.
--
-- CONSTRUCTION
--   local mm = newMidiManager(take)   -- load immediately
--   local mm = newMidiManager(nil)    -- create empty, call mm:load(take) later
--
-- LIFECYCLE
--   mm:load(take)                     -- (re)initialise from a REAPER take
--   mm:reload()                       -- reloads the active take, if present
--
-- MESSAGING
--   mm:addCallback(fn)                -- register a callback
--   mm:removeCallback(fn)             -- unregister a callback
--     On any reload (including after modify()), registered callbacks are
--     called with the signature fn(changed, mm), where changed is a
--     table of the form { take = bool, data = bool }. take is true when
--     a different REAPER take has been loaded; data is always true on
--     reload.
--
-- MUTATION
--   All mutations (assign*, add*, delete*) must be performed inside a
--   mm:modify(fn) call. modify() acquires a lock, disables MIDI sort,
--   calls fn(), re-sorts, and then reloads (which fires callbacks).
--   Calling any mutation function outside of modify() will error.
--
--   Exception: assignNote calls that ONLY set metadata fields (i.e. none
--   of ppq, endppq, pitch, or vel are present in the update table) are
--   permitted outside of modify(). These write directly to extension data
--   via saveMetadatum() and do not trigger a reload or fire callbacks.
--
--   mm:modify(function()
--     mm:addNote({ppq=0, endppq=960, chan=1, pitch=60, vel=100})
--     mm:assignNote(1, {vel=80})
--     mm:deleteCC(3)
--   end)
--
-- CONVENTIONS
--   - Locations are 1-indexed integers assigned in REAPER event order
--   - Location ordering is guaranteed to match REAPER MIDI event ordering
--   - Iterators return events in location order
--   - MIDI channels are 1..16 (offset by +1 from REAPER's 0..15)
--   - Velocity and CC values are 0..127 except where noted
--   - Pitchbend values are -8192..8191 (centred on 0)
--
-- NOTES  (location-based access, identified internally by UUID)
--   mm:getNote(loc)                   -- returns a copy of the note, or nil
--   mm:getNoteByUUID(uuid)            -- returns a copy of the note, or nil
--   mm:notes()                        -- iterator: for loc, note in mm:notes()
--   mm:assignNote(loc, t)             -- update note at location
--     Only provided fields in t are changed. Supports ppq, endppq, chan,
--     pitch, vel, plus any custom metadata fields. If ppq, chan, or pitch
--     change, the associated notation event is updated to match.
--     Assigning util.REMOVE to a metadata field removes it.
--   mm:addNote(t)                     -- insert a new MIDI note
--     t must contain ppq, endppq, chan, pitch, and vel.
--     A UUID is assigned automatically. Returns the new location.
--   mm:deleteNote(loc)                -- delete note and its notation event
--
-- CCs  (location-based access)
--   mm:getCC(loc)                     -- returns a copy of the CC, or nil
--   mm:ccs()                          -- iterator: for loc, cc in mm:ccs()
--   mm:assignCC(loc, t)               -- update CC at location
--     Supports msgType change. val is decoded per type:
--       cc -> t.cc, t.val       pb -> t.val (-8192..8191)
--       pa -> t.pitch, t.val    pc/at -> t.val
--   mm:addCC(t)                       -- insert a new CC event
--     t must contain ppq, chan, and val. Defaults msgType to 'cc'.
--     Returns the new location.
--   mm:deleteCC(loc)                  -- delete CC at location
--
-- SYSEX / TEXT  (location-based access)
--   mm:getSysex(loc)                  -- returns a copy, or nil
--   mm:sysexes()                      -- iterator: for loc, sx in mm:sysexes()
--     NOTE: the sysex iterator currently has a bug — the continuation
--     check reads `if note then` instead of `if sysex then`, so it
--     will never yield results.
--   mm:assignSysex(loc, t)            -- update sysex/text event at location
--   mm:addSysex(t)                    -- insert a new sysex/text event
--     t must contain ppq, msgType, and val.
--     Valid msgType values: sysex, text, copyright, trackname,
--     instrument, lyric, marker, cuepoint, notation.
--     Returns the new location.
--   mm:deleteSysex(loc)               -- delete sysex/text event at location
--
-- TAKE DATA
--   mm:take()                         -- the current REAPER take (read-only)
--   mm:reso()                         -- PPQ per quarter note
--   mm:length()                       -- take length in PPQ (excludes looping)
--
-- ACCESSORS
--   All get* functions and iterators return shallow copies. Modifying a
--   returned table has no effect on internal state — use assign* to
--   write changes back. Iterators must not be interleaved with modify()
--   calls; collect entries first, then mutate inside a single modify().
--
-- METADATA
--   Any fields on a note table beyond the standard event fields
--   (idx, ppq, endppq, chan, pitch, vel, uuid, uuidIdx) are treated as
--   custom metadata and persisted to the take's extension data via
--   util:serialise(). These survive project save/load and are restored
--   on mm:load(). Standard event fields are stripped before saving.
--------------------

loadModule('util')

local function print(...)
  return util:print(...)
end

--------------------

function newMidiManager(take)

  ---------- PRIVATE DATA & FUNCTIONS
 
  local noteTbl   = {}
  local ccTbl     = {}
  local sysexTbl  = {}
  local uuidTbl   = {}
  local maxUUID   = 0
  local maxNote   = 0
  local maxCC     = 0
  local maxSysex  = 0
  local lock      = false
  local callbacks = {}

  local function copyEntry(entry, exceptions)
    if not entry then return end
    local val = util:assign({}, entry)
    if exceptions then
      for k,_ in pairs(exceptions) do
        val[k] = nil
      end
    end
    return val
  end
  
  local function loadMetadata()
    if not take then return end

    local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_keys", "", false)
    if not (ok and keysText and keysText ~= "") then return {} end
    local tbl = {}
    for uuidTxt in keysText:gmatch("[^,]+") do
      local uuid = util:fromBase36(uuidTxt)
      tbl[uuid] = { }

      local entryOk, fields = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. uuidTxt, "", false)
      if entryOk and fields then
        tbl[uuid] = util:unserialise(fields)
      end
    end
    return tbl
  end

  local function saveMetadatum(uuid)
    if not take then return end
    
    local uuidTxt = util:toBase36(uuid)
    local data = uuidTbl[uuid]

    if not data then
      print("Error! uuid not found")
      return nil
    end
    
    -- note-event fields to strip
    local noteEventFields = {
      idx = true, ppq = true, endppq = true, chan = true,
      pitch = true, vel = true, uuid = true, uuidIdx = true,
    }

    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. uuidTxt, util:serialise(data, noteEventFields), true)
  end

  local function saveMetadata()
    if not take then return end
    
    -- Collect the set of uuids we're about to write
    local newKeys = {}
    for uuid, _ in pairs(uuidTbl) do
      local uuidTxt = util:toBase36(uuid)
      newKeys[uuidTxt] = true
      saveMetadatum(uuid)
    end

    -- Delete stale keys that exist in the old key list but not in metadata table
    local ok, oldKeysText = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_keys", "", false)
    if ok and oldKeysText and oldKeysText ~= "" then
      for oldUuidTxt in oldKeysText:gmatch("[^,]+") do
        if not newKeys[oldUuidTxt] then
          -- Writing an empty string effectively removes the extension data
          reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. oldUuidTxt, "", true)
        end
      end
    end

    -- Write the new key list
    local keyList = {}
    for uuidTxt in pairs(newKeys) do
      keyList[#keyList + 1] = uuidTxt
    end
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_keys", table.concat(keyList, ","), true)
  end

  local function removeDuplicateEvents()
    if not take then return end
    
    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return end

    local notesSeen = {}
    local notesToDelete = {}
    
    for i=0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      chan = chan + 1
      if ok then
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        if notesSeen[tag] then
          local last = notesSeen[tag]
          if endppq > last.endppq then
            notesToDelete[#notesToDelete + 1] = last.idx
            notesSeen[tag] = { idx = i, endppq = endppq }
          else
            notesToDelete[#notesToDelete + 1] = i
          end
        else
          notesSeen[tag] = { idx = i, endppq = endppq }
        end
      end
    end

    reaper.MIDI_DisableSort(take)
    for i=#notesToDelete,1,-1 do
      reaper.MIDI_DeleteNote(take, notesToDelete[i])
    end
    reaper.MIDI_Sort(take)

    return #notesToDelete
  end
  
  --- UTILS

  local function nextNote()
    maxNote = maxNote + 1
    return maxNote
  end
  
  local function nextCC()
    maxCC = maxCC + 1
    return maxCC
  end

  local function nextSysex()
    maxSysex = maxSysex + 1
    return maxSysex
  end

  local function assignNewUUID(note)
    maxUUID = maxUUID + 1
    note.uuid = maxUUID
    uuidTbl[maxUUID] = note
    return maxUUID
  end

  ---------- PUBLIC FUNCTIONS

  local mm = {}

  -- Load take and initialise tables
  function mm:load(newTake)
    if not newTake then return end

    local changed = { take = false, data = true }
    if take ~= newTake then
      take = newTake
      changed.take = true
    end

    noteTbl   = {}
    ccTbl     = {}
    sysexTbl  = {}
    uuidTbl   = {}
    maxUUID   = 0
    lock      = false
    maxNote   = 0
    maxCC     = 0
    maxSysex  = 0

    local notesLUT = {}

    -- remove duplicate notes
    local removedCount = removeDuplicateEvents() or 0
    if removedCount > 0 then
      print("Removed " .. removedCount .. " duplicate events!")
    end

    -- get note data
    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return end

    for i = 0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      chan = chan + 1
      if ok then
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        local loc = nextNote()
        noteTbl[loc] = {
          idx    = i,
          ppq    = ppq,
          endppq = endppq,
          chan   = chan,
          pitch  = pitch,
          vel    = vel,
        }
        notesLUT[tag] = noteTbl[loc]
      end
    end

    -- get cc events
    local chanMsgTypes = {
      [0xA0] = 'pa',
      [0xB0] = 'cc',
      [0xC0] = 'pc',
      [0xD0] = 'at',
      [0xE0] = 'pb'
    }

    for i = 0, ccCount-1 do
      local ok, selected, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
      chan = chan + 1
      if ok then
        local msgType = chanMsgTypes[chanmsg] or ("chanmsg_" .. chanmsg)
        local entry = {
          idx     = i,
          ppq     = ppq,
          msgType = msgType,
          chan    = chan,
        }

        if msgType == 'pa' then
          -- poly AT: note (msg2) and velocity (msg3)
          entry.pitch = msg2
          entry.val = msg3
        elseif msgType == 'cc' then
          -- CC: controller (msg2) and value (msg3)
          entry.cc  = msg2
          entry.val = msg3
        elseif msgType == 'pc' or msgType == 'at' then
          -- program change/channel aftertouch: only msg2 is meaningful
          entry.val = msg2
        elseif msgType == 'pb' then
          -- pitch bend: combine LSB (msg2) + MSB (msg3) into 14-bit, centred on 8192
          entry.val = ((msg3 << 7) | msg2) - 8192
        else
          -- just record the data
          entry.val = msg2
          entry.val2 = msg3
        end

        ccTbl[nextCC()] = entry
      end
    end

    -- Scan notation events to obtain UUIDs for notes
    local UUIDCount = {}

    for i = 0, textCount-1 do
      local ok, selected, muted, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local chan, pitch, uuidTxt = msg:match("^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$")
        chan = chan + 1
        if uuidTxt then
          -- one of our UUID identifiers
          local uuid = util:fromBase36(uuidTxt)
          local tag = ppq .. '|' .. chan .. '|' .. pitch
          local note = notesLUT[tag]
          if note then
            note.uuid = uuid
            note.uuidIdx = i
            UUIDCount[uuid] = (UUIDCount[uuid] or 0) + 1
          else
            print("Error! UUID at " .. ppq .. " has no coincident note")
          end
        end
      end
    end

    -- get metadata lookup table
    local metadata = loadMetadata()
    
    for uuid, _ in pairs(metadata) do
      if uuid > maxUUID then maxUUID = uuid end
    end

    -- fix duplicate and missing uuids
    reaper.MIDI_DisableSort(take)
    for _, note in ipairs(noteTbl) do
      local uuid = note.uuid
      if uuid and UUIDCount[uuid] > 1 then
        local oldUUID = uuid
        local newUUID = assignNewUUID(note)
        UUIDCount[oldUUID] = UUIDCount[oldUUID] - 1
        UUIDCount[newUUID] = 1
        metadata[newUUID] = util:assign({}, metadata[oldUUID] or {})
        reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, nil, 15, string.format("NOTE %d %d custom rdm_%s", note.chan - 1, note.pitch, util:toBase36(newUUID)), false)
      elseif not uuid then
        local newUUID = assignNewUUID(note)
        UUIDCount[newUUID] = 1
        metadata[newUUID] = {}
        reaper.MIDI_InsertTextSysexEvt(take, false, false, note.ppq, 15, string.format("NOTE %d %d custom rdm_%s", note.chan - 1, note.pitch, util:toBase36(newUUID)))
      end
    end
    reaper.MIDI_Sort(take)

    -- Now rescan ALL sysex/text events, including updating uuidIdx for notes
    local textMsgTypes = {
      [-1] = "sysex",
      [1]  = "text",
      [2]  = "copyright",
      [3]  = "trackname",
      [4]  = "instrument",
      [5]  = "lyric",
      [6]  = "marker",
      [7]  = "cuepoint",
      [15] = "notation",
    }

    _ , _, _, textCount = reaper.MIDI_CountEvts(take)
    for i = 0, textCount-1 do
      local ok, selected, muted, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local chan, pitch, uuidTxt = msg:match("^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$")
        chan = chan + 1
        if uuidTxt then
          -- one of our UUID identifiers
          local tag = ppq .. '|' .. chan .. '|' .. pitch
          local note = notesLUT[tag]
          if note then
            note.uuidIdx = i
          end
        else
          -- some other notation event
          sysexTbl[nextSysex()] = {
            idx     = i,
            ppq     = ppq,
            msgType = 'notation',
            val     = msg,
          }
        end
      elseif ok then
        -- all other text/sysex events (text meta, sysex, etc.)
        sysexTbl[nextSysex()] = {
            idx     = i,
            ppq     = ppq,
            msgType = textMsgTypes[eventtype] or ("meta_" .. eventtype),
            val     = msg,
        }
      end
    end

    -- add metadata to notes
    for i,note in ipairs(noteTbl) do
      util:assign(note, metadata[note.uuid])
      uuidTbl[note.uuid] = note
    end

    -- save all metadata, built from uuidTbl
    saveMetadata()

    -- callbacks
    for fn,_ in pairs(callbacks) do
      fn(changed, mm)
    end
  end

  function mm:reload()
    if not take then return end
    self:load(take)
  end


  --- LOCKING

  local function checkLock()
    assert(lock, "Error! You must call modification functions via modify()!")
    return true
  end

  function mm:modify(fn)
    if not take then return end
      
    lock = true
    reaper.MIDI_DisableSort(take)
    pcall(fn)
    reaper.MIDI_Sort(take)
    self:reload()
    lock = false
  end

  --- NOTE FUNCTIONS. 

  function mm:getNote(loc)
    local note = noteTbl[loc]
    return copyEntry(note, { idx = true, uuidIdx = true })
  end

  function mm:getNoteByUUID(uuid)
    local note = uuidTbl[uuid]
    return copyEntry(note, { idx = true, uuidIdx = true })
  end

  function mm:notes()
    local i = 0
    return function()
      i = i + 1
      local note = noteTbl[i]
      if note then
        return i, copyEntry(note, { idx = true, uuidIdx = true })
      end
    end
  end

  function mm:deleteNote(loc)
    if not (take and checkLock()) then return end

    local note = loc and noteTbl[loc]
    if not note then return end

    -- remove the notation event first
    reaper.MIDI_DeleteTextSysexEvt(take, note.uuidIdx)
    reaper.MIDI_DeleteNote(take, note.idx)

    -- clean up internal tables
    uuidTbl[note.uuid] = nil
    noteTbl[loc] = nil
  end

  function mm:assignNote(loc, t)
    if not take then return end

    if not (t.ppq or t.endppq or t.pitch or t.vel) then
      -- just metadata, allow without lock
      local note = loc and noteTbl[loc]
      if not note then return end

      util:assign(note, t)

      saveMetadatum(note.uuid)
      return
    end
    
    if not checkLock() then return end

    local note = loc and noteTbl[loc]
    if not note then return end

    local chan
    if t.chan then chan = t.chan - 1 end
      
    -- update the existing note (nil values will do nothing)
    reaper.MIDI_SetNote(take, note.idx, nil, nil, t.ppq, t.endppq, chan, t.pitch, t.vel, true)

    -- merge fields into the note
    util:assign(note, t)

    -- if ppq, chan, or pitch changed, update the notation event to match
    if (t.ppq or t.chan or t.pitch) and note.uuidIdx then
      reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, note.ppq, 15, string.format("NOTE %d %d custom rdm_%s", chan, note.pitch, util:toBase36(note.uuid)), true)
    end

    saveMetadatum(note.uuid)
  end

  function mm:addNote(t)
    if not (take and checkLock()) then return end

    if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
      print('Error! Underspecified new note')
      return nil
    end

    -- create a new note
    reaper.MIDI_InsertNote(take, false, false, t.ppq, t.endppq, t.chan - 1, t.pitch, t.vel, true)
    -- copy table, assign new UUID
    local note = util:assign({ }, t)
    local uuid = assignNewUUID(note)
    -- create notation event for UUID
    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, string.format("NOTE %d %d custom rdm_%s", t.chan - 1, t.pitch, util:toBase36(note.uuid)), true)

    -- copy data to tables
    local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
    note.uuidIdx = sysexCount - 1
    note.idx = noteCount - 1
    noteTbl[nextNote()] = note

    saveMetadatum(note.uuid)

    return maxNote -- location in table
  end

  --- CC FUNCTIONS

  local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

  local eventTypeLUT = {
    sysex      = -1,
    text       = 1,
    copyright  = 2,
    trackname  = 3,
    instrument = 4,
    lyric      = 5,
    marker     = 6,
    cuepoint   = 7,
    notation   = 15,
  }

  function mm:getCC(loc)
    local msg = ccTbl[loc]
    return copyEntry(msg, { idx = true })
  end

  function mm:ccs()
    local i = 0
    return function()
      i = i + 1
      local msg = ccTbl[i]
      if msg then
        return i, copyEntry(msg, { idx = true })
      end
    end
  end

  function mm:deleteCC(loc)
    if not (take and checkLock()) then return end

    local msg = loc and ccTbl[loc]
    if not msg then return end

    reaper.MIDI_DeleteCC(take, msg.idx)
    ccTbl[loc] = nil
  end

  -- reconstruct msg2/msg3 from semantic fields depending on type
  local function reconstruct(tbl)
    local msgType = tbl.msgType
    if not msgType then return end
    
    local msg2, msg3
    if msgType == 'pb' then
      local raw = (tbl.val or 0) + 8192
      msg2 = raw & 0x7F
      msg3 = (raw >> 7) & 0x7F
    elseif msgType == 'pa' then
      msg2 = tbl.pitch or 0
      msg3 = tbl.val   or 0
    elseif msgType == 'pc' or msgType == 'at' then
      msg2 = tbl.val or 0
      msg3 = 0
    else
      msg2 = tbl.cc  or 0
      msg3 = tbl.val or 0
    end
    return msg2, msg3
  end

  function mm:assignCC(loc, t)
    if not (take and checkLock()) then return end

    local msg = loc and ccTbl[loc]
    if not msg then return end

    local msg2 = nil
    local msg3 = nil
    local chanmsg = nil

    if t.msgType then
      if not chanMsgLUT[t.msgType] then
        print('Error! Unspecified message type')
        return nil
      end
      chanmsg = chanMsgLUT[t.msgType]
      msg2, msg3 = reconstruct(t)
    elseif t.val or t.cc or t.pitch then
      local merged = util:assign(util:assign({}, msg), t)
      msg2, msg3 = reconstruct(merged)
    end
    local chan
    if t.chan then chan = t.chan - 1 end
    reaper.MIDI_SetCC(take, msg.idx, nil, nil, t.ppq, chanmsg, chan, msg2, msg3, true)

    -- update the table entry
    util:assign(msg, t)
    if msg.msgType ~= 'cc' then msg.cc = nil end
    if msg.msgType ~= 'pa' then msg.pitch = nil end
  end

  function mm:addCC(t)
    if not (take and checkLock()) then return end

    if t.msgType == nil then t.msgType = 'cc' end

    if t.ppq == nil or t.chan == nil or t.val == nil then
      print('Error! Underspecified new cc event')
      return nil
    end

    local chanmsg = chanMsgLUT[t.msgType]
    local msg2, msg3 = reconstruct(t)
    
    if not chanmsg then
      print('Error! Unspecified message type')
      return nil
    end

    reaper.MIDI_InsertCC(take, false, false, t.ppq, chanmsg, t.chan - 1, msg2, msg3)

    local msg = util:assign({ }, t)

    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    msg.idx = ccCount - 1
    
    ccTbl[nextCC()] = msg

    return maxCC -- location in table
  end


  --- SYSEX FUNCTIONS

  function mm:getSysex(loc)
    local sysex = sysexTbl[loc]
    return copyEntry(sysex, { idx = true })
  end

  function mm:sysexes()
    local i = 0
    return function()
      i = i + 1
      local sysex = sysexTbl[i]
      if sysex then
        return i, copyEntry(sysex, { idx = true })
      end
    end
  end

  function mm:deleteSysex(loc)
    if not (take and checkLock()) then return end

    local sysex = loc and sysexTbl[loc]
    if not sysex then return end

    reaper.MIDI_DeleteTextSysexEvt(take, sysex.idx)
    sysexTbl[loc] = nil
  end

  function mm:assignSysex(loc, t)
    if not (take and checkLock()) then return end

    local sysex = loc and sysexTbl[loc]
    if not sysex then return end

    local eventtype = t.msgType and eventTypeLUT[t.msgType] or eventTypeLUT[sysex.msgType]

    reaper.MIDI_SetTextSysexEvt(take, sysex.idx, nil, nil, t.ppq, eventtype, t.val, true)

    -- update the table entry
    util:assign(sysex, t)
  end

  function mm:addSysex(t)
    if not (take and checkLock()) then return end

    local eventtype = t.msgType and eventTypeLUT[t.msgType]
    if not eventtype then
      print('Error! Unspecified message type')
      return nil
    end
    
    if t.ppq == nil or t.msgType == nil or t.val == nil then
      print('Error! Underspecified new sysex/text event')
      return nil
    end

    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, eventtype, t.val)

    local sysex = util:assign({ }, t)

    local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
    sysex.idx = sysexCount - 1
    
    sysexTbl[nextSysex()] = sysex

    return maxSysex -- location in table
  end

  --- TAKE DATA

  function mm:take()
    return take
  end

  -- resolution in PPQ per QN
  function mm:reso()
    if not take then return end
    return reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  end

  -- length in PPQ (discounting looping)
  function mm:length()
    if not take then return end
    local source = reaper.GetMediaItemTake_Source(take)
    local sourceLengthQN = reaper.GetMediaSourceLength(source)
    return reaper.MIDI_GetPPQPosFromProjQN(take, sourceLengthQN) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  end

  -- time signatures within the take's range
  -- returns array of { ppq, num, denom } sorted by ppq,
  -- starting with the time sig in effect at the take's start
  function mm:timeSigs()
    if not take then return {} end

    local item = reaper.GetMediaItemTake_Item(take)
    local startTime = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local endTime = startTime + itemLength
    local basePPQ = reaper.MIDI_GetPPQPosFromProjTime(take, startTime)

    local result = {}
    local count = reaper.CountTempoTimeSigMarkers(0)

    -- find the last marker at or before the take start for the initial time sig
    local initNum, initDenom
    for i = 0, count - 1 do
      local _, pos, _, _, _, num, denom, _ = reaper.GetTempoTimeSigMarker(0, i)
      if num > 0 and pos <= startTime then
        initNum, initDenom = num, denom
      end
    end

    -- fall back to project default if no marker precedes the take
    if not initNum then
      local num, denom, _ = reaper.TimeMap_GetTimeSigAtTime(0, startTime)
      initNum, initDenom = num, denom
    end

    result[1] = { ppq = 0, num = initNum, denom = initDenom }

    -- collect any time sig changes within the take
    for i = 0, count - 1 do
      local _, pos, _, _, _, num, denom, _ = reaper.GetTempoTimeSigMarker(0, i)
      if num > 0 and pos > startTime and pos < endTime then
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pos) - basePPQ
        result[#result + 1] = { ppq = ppq, num = num, denom = denom }
      end
    end

    return result
  end

  --- MESSAGING

  -- Add callback function
  function mm:addCallback(fn)
    callbacks[fn] = true
  end

  -- Remove callback function
  function mm:removeCallback(fn)
    callbacks[fn] = nil
  end

  ---------- FACTORY BODY

  if take then mm:load(take) end
  return mm
end
