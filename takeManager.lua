local function print(...)
  return util:print(...)
end

--------------------
-- newTakeManager(take)
--
-- Creates an abstraction layer over REAPER's MIDI take API, providing
-- UUID-based note identity, persistent per-note metadata via take
-- extension data, and a clean read/write interface for notes, CCs,
-- and sysex/text events.
--
-- CONSTRUCTION
--   local mgr = newTakeManager(take)   -- load immediately
--   local mgr = newTakeManager(nil)    -- create empty, call mgr:load(take) later
--
-- LIFECYCLE
--   mgr:load(take)                     -- (re)initialise from a REAPER take
--   mgr:reload()                       -- reloads from mgr.take
--
-- MESSAGING
--   mgr:addCallback(fn)                -- add a callback function
--     On any mutation or reload, the manager will call 'fn' with the
--     signature fn(changes, mgr), where mgr is a reference to the manager,
--     and changes is a table of the form { take = false, data = true }
--     where the boolean values indicate whether the take and/or the
--     take data (notes, cc, sysex) have changed.
--   mgr:removeCallback(fn)             -- remove a callback function
--
-- MUTATION
--   All mutations (assign*, add*, delete*) must be performed inside a
--   mgr:modify(fn) call. modify() acquires a lock, disables MIDI sort,
--   calls fn(), re-sorts, and then reloads. Calling any mutation
--   function outside of modify() will print an error and return nil.
--
--   mgr:modify(function()
--     mgr:addNote({ppq=0, endppq=960, chan=0, pitch=60, vel=100})
--     mgr:assignNote(0, {vel=80})
--     mgr:deleteCC(3)
--   end)
--
-- NOTES  (location-based access, identified internally by uuid)
--   mgr:getNote(loc)                   -- returns a copy of the note at location, or nil
--   mgr:getNoteByUUID(uuid)            -- returns a copy of the note with uuid, or nil
--   mgr:notes()                        -- iterator: for loc, note in mgr:notes() do ... end
--   mgr:assignNote(loc, t)             -- update existing note at location
--     Only provided fields in t are changed (ppq, endppq, chan, pitch,
--     vel, plus any custom metadata fields). Automatically updates the
--     notation event if ppq, chan, or pitch changed.
--   mgr:addNote(t)                     -- create a new note
--     t must contain ppq, endppq, chan, pitch, and vel.
--     A new UUID is assigned automatically. Returns the new location.
--   mgr:deleteNote(loc)                -- delete note at location
--     Removes both the MIDI note and its notation-event UUID marker.
--
-- CCs  (location-based access)
--   mgr:getCC(loc)                     -- returns a copy of the CC at location, or nil
--   mgr:ccs()                          -- iterator: for loc, cc in mgr:ccs() do ... end
--   mgr:assignCC(loc, t)               -- update existing CC at location
--     Supports msgType change; val is decoded per type:
--       cc  -> t.cc, t.val       pb -> t.val (-8192..8191)
--       pa  -> t.pitch, t.val    pc/at -> t.val
--   mgr:addCC(t)                       -- create a new CC event
--     t must contain ppq, chan, and val. Defaults to msgType 'cc'.
--     Returns the new location.
--   mgr:deleteCC(loc)                  -- delete CC at location
--
-- SYSEX / TEXT  (location-based access)
--   mgr:getSysex(loc)                  -- returns a copy of the sysex entry at location, or nil
--   mgr:sysexes()                      -- iterator: for loc, sx in mgr:sysexes() do ... end
--   mgr:assignSysex(loc, t)            -- update existing sysex/text event at location
--   mgr:addSysex(t)                    -- create a new sysex/text event
--     t must contain ppq, msgType, and val.
--     msgType is one of: sysex, text, copyright, trackname,
--     instrument, lyric, marker, cuepoint, notation.
--     Returns the new location.
--   mgr:deleteSysex(loc)               -- delete sysex/text event at location
--
-- FIELDS
--   mgr.take                           -- the current REAPER take (read-only)
--
-- ACCESSORS
--   All get* functions and iterators return shallow copies. Modifying a
--   returned table has no effect on internal state — use assign* to
--   write changes back. Iterators must not be interleaved with modify()
--   calls; collect entries first, then mutate inside a single modify().
--
-- METADATA
--   Any fields on a note table beyond the standard note-event fields
--   (idx, ppq, endppq, chan, pitch, vel, uuid, uuidIdx) are treated as
--   custom metadata and persisted to the take's extension data. These
--   survive project save/load and are restored on mgr:load().
--------------------

function newTakeManager(take)

  ---------- PUBLIC DATA

  local rv = {}
  rv.take  = nil

  ---------- PRIVATE DATA & FUNCTIONS
 
  local noteTbl   = {}
  local ccTbl     = {}
  local sysexTbl  = {}
  local uuidTbl   = {}
  local maxUUID   = -1
  local maxNote   = -1
  local maxCC     = -1
  local maxSysex  = -1
  local lock      = false
  local callbacks = {}

  local function copyEntry(entry)
    if not entry then return nil end
    return util:assign({}, entry)
  end
  
  local function loadMetadata()
    if not rv.take then return nil end
    local take = rv.take

    local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_keys", "", false)
    if not (ok and keysText and keysText ~= "") then return {} end
    local tbl = {}
    for uuidTxt in keysText:gmatch("[^,]+") do
      local uuid = util:fromBase36(uuidTxt)
      tbl[uuid] = { }

      local entryOk, fields = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. uuidTxt, "", false)
      if entryOk and fields then
        tbl[uuid] = util:unserialise(fields)
        -- for kv in fields:gmatch("[^,]+") do
        --   local k, v = kv:match("([^=]+)=([^=]+)")
        --   if k then
        --     tbl[uuid][k] = tonumber(v) or v
        --   end
        -- end
      end
    end
    return tbl
  end

  local function saveMetadatum(uuid)
    if not rv.take then return nil end
    local take = rv.take
    
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

    local fields = {}
    for k, v in pairs(data) do
      -- don't save note-event fields
      if not noteEventFields[k] then
        fields[#fields + 1] = k .. "=" .. tostring(v)
      end
    end
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. uuidTxt, util:serialise(data, noteEventFields), true)
  end

  local function saveMetadata()
    if not rv.take then return nil end
    local take = rv.take
    
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

  local function removeDuplicateNotes()
    if not rv.take then return nil end
    local take = rv.take
    
    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return nil end

    local notesSeen = {}
    local notesToDelete = {}
    
    for i=0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        if notesSeen[tag] then
          local last = notesSeen[tag]
          if endppq > last.endppq then
            table.insert(notesToDelete, last.idx)
            notesSeen[tag] = { idx = i, endppq = endppq }
          else
            table.insert(notesToDelete, i)
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

  -- Add callback function
  function rv:addCallback(fn)
    callbacks[fn] = true
  end

  -- Remove callback function
  function rv:removeCallback(fn)
    callbacks[fn] = nil
  end

  -- Load take and initialise tables
  function rv:load(take)
    if not take then return nil end

    local changed = { take = false, data = true }
    if self.take ~= take then
      self.take = take
      changed.take = true
    end

    noteTbl   = {}
    ccTbl     = {}
    sysexTbl  = {}
    uuidTbl   = {}
    maxUUID   = -1
    lock      = false
    maxNote   = -1
    maxCC     = -1
    maxSysex  = -1

    local notesLUT = {}

    -- remove duplicate notes
    local removedCount = removeDuplicateNotes() or 0
    if removedCount > 0 then
      print("Removed " .. removedCount .. " duplicate notes!")
    end

    -- get note data
    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return nil end

    for i = 0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        noteTbl[i] = {
          idx    = i,
          ppq    = ppq,
          endppq = endppq,
          chan   = chan,
          pitch  = pitch,
          vel    = vel,
        }
        notesLUT[tag] = noteTbl[i]
      end
    end
    maxNote = noteCount-1

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

        ccTbl[i] = entry
      end
    end
    maxCC = ccCount-1

    -- Scan notation events to obtain UUIDs for notes
    local UUIDCount = {}

    for i = 0, textCount-1 do
      local ok, selected, muted, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local chan, pitch, uuidTxt = msg:match("^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$")
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
    local function handleDuplicateUUID(note, tbl)
      return util:assign({ }, tbl)
    end

    local function defaultMetadata(note)
      return { }
    end

    reaper.MIDI_DisableSort(take)
    for _, note in pairs(noteTbl) do
      local uuid = note.uuid
      if uuid and UUIDCount[uuid] > 1 then
        local oldUUID = uuid
        local newUUID = assignNewUUID(note)
        UUIDCount[oldUUID] = UUIDCount[oldUUID] - 1
        UUIDCount[newUUID] = 1
        metadata[newUUID] = handleDuplicateUUID(note, metadata[oldUUID] or { })
        reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, nil, 15, string.format("NOTE %d %d custom rdm_%s", note.chan, note.pitch, util:toBase36(newUUID)), false)
      elseif not uuid then
        local newUUID = assignNewUUID(note)
        UUIDCount[newUUID] = 1
        metadata[newUUID] = defaultMetadata(note)
        reaper.MIDI_InsertTextSysexEvt(take, false, false, note.ppq, 15, string.format("NOTE %d %d custom rdm_%s", note.chan, note.pitch, util:toBase36(newUUID)))
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
    for i,note in pairs(noteTbl) do
      util:assign(note, metadata[note.uuid])
      uuidTbl[note.uuid] = note
    end

    -- save all metadata, built from uuidTbl
    saveMetadata()

    -- callbacks
    for fn,_ in pairs(callbacks) do
      fn(changed, self)
    end
  end

  --- LOCKING

  local function checkLock()
    if not lock then
      print("Error! You must call modification functions via modify()!")
      return false
    end
    return true
  end

  function rv:modify(fn)
    if not self.take then return nil end
      
    lock = true
    reaper.MIDI_DisableSort(self.take)
    pcall(fn)
    reaper.MIDI_Sort(self.take)
    self:reload()
    lock = false
  end

  --- NOTE FUNCTIONS. 

  function rv:getNote(idx)
    local note = noteTbl[idx]
    return copyEntry(note)
  end

  function rv:getNoteByUUID(uuid)
    local note = uuidTbl[uuid]
    return copyEntry(note)
  end

  function rv:notes()
    local key = nil
    return function()
      local note
      key, note = next(noteTbl, key)
      if note then return key, copyEntry(note) end
    end
  end

  function rv:deleteNote(loc)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local note = loc and noteTbl[loc]
    if not note then return nil end

    -- remove the notation event first
    reaper.MIDI_DeleteTextSysexEvt(take, note.uuidIdx)
    reaper.MIDI_DeleteNote(take, note.idx)

    -- clean up internal tables
    uuidTbl[note.uuid] = nil
    noteTbl[loc] = nil
  end

  function rv:assignNote(loc, t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local note = loc and noteTbl[loc]
    if not note then return nil end

    -- update the existing note (nil values will do nothing)
    reaper.MIDI_SetNote(take, note.idx, nil, nil, t.ppq, t.endppq, t.chan, t.pitch, t.vel, true)

    -- merge fields into the note
    util:assign(note, t)

    -- if ppq, chan, or pitch changed, update the notation event to match
    if (t.ppq or t.chan or t.pitch) and note.uuidIdx then
      reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, note.ppq, 15, string.format("NOTE %d %d custom rdm_%s", note.chan, note.pitch, util:toBase36(note.uuid)), true)
    end

    saveMetadatum(note.uuid)
  end

  function rv:addNote(t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
      print('Error! Underspecified new note')
      return nil
    end

    -- create a new note
    reaper.MIDI_InsertNote(take, false, false, t.ppq, t.endppq, t.chan, t.pitch, t.vel, true)
    -- copy table, assign new UUID
    local note = util:assign({ }, t)
    local uuid = assignNewUUID(note)
    -- create notation event for UUID
    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, string.format("NOTE %d %d custom rdm_%s", t.chan, t.pitch, util:toBase36(note.uuid)), true)

    -- copy data to tables
    local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
    note.uuidIdx = sysexCount - 1
    note.idx = noteCount - 1
    noteTbl[nextNote()] = note

    saveMetadatum(note.uuid)

    return maxNote -- location in table
  end

  --- CC FUNCTIONS
  function rv:getCC(loc)
    local msg = ccTbl[loc]
    return copyEntry(msg)
  end

  function rv:ccs()
    local key = nil
    return function()
      local msg
      key, msg = next(ccTbl, key)
      if msg then return key, copyEntry(msg) end
    end
  end

  function rv:deleteCC(loc)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local msg = loc and ccTbl[loc]
    if not msg then return nil end

    reaper.MIDI_DeleteCC(take, msg.idx)
    ccTbl[loc] = nil
  end

  -- reconstruct msg2/msg3 from semantic fields depending on type
  local function reconstruct(tbl)
    local msgType = tbl.msgType
    if not msgType then return nil end
    
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

  function rv:assignCC(loc, t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local msg = loc and ccTbl[loc]
    if not msg then return nil end
    
    local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

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
    reaper.MIDI_SetCC(take, msg.idx, nil, nil, t.ppq, chanmsg, t.chan, msg2, msg3, true)

    -- update the table entry
    util:assign(msg, t)
    if msg.msgType ~= 'cc' then msg.cc = nil end
    if msg.msgType ~= 'pa' then msg.pitch = nil end
  end

  function rv:addCC(t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    if t.msgType == nil then t.msgType = 'cc' end

    if t.ppq == nil or t.chan == nil or t.val == nil then
      print('Error! Underspecified new cc event')
      return nil
    end
      
    local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }
    local chanmsg = chanMsgLUT[t.msgType]
    local msg2, msg3 = reconstruct(t)
    
    if not chanmsg then
      print('Error! Unspecified message type')
      return nil
    end

    reaper.MIDI_InsertCC(take, false, false, t.ppq, chanmsg, t.chan, msg2, msg3)

    local msg = util:assign({ }, t)

    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    msg.idx = ccCount - 1
    
    ccTbl[nextCC()] = msg

    return maxCC -- location in table
  end


  --- SYSEX FUNCTIONS

  function rv:getSysex(idx)
    local sysex = sysexTbl[idx]
    return copyEntry(sysex)
  end

  function rv:sysexes()
    local key = nil
    return function()
      local sysex
      key, sysex = next(sysexTbl, key)
      if sysex then return key, copyEntry(sysex) end
    end
  end

  function rv:deleteSysex(loc)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local sysex = loc and sysexTbl[loc]
    if not sysex then return nil end

    reaper.MIDI_DeleteTextSysexEvt(take, sysex.idx)
    sysexTbl[loc] = nil
  end

  function rv:assignSysex(loc, t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    local sysex = loc and sysexTbl[loc]
    if not sysex then return nil end

    -- resolve eventtype from msgType
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

    local eventtype = t.msgType and eventTypeLUT[t.msgType] or eventTypeLUT[sysex.msgType]

    reaper.MIDI_SetTextSysexEvt(take, sysex.idx, nil, nil, t.ppq, eventtype, t.val, true)

    -- update the table entry
    util:assign(sysex, t)
  end

  function rv:addSysex(t)
    local take = self.take
    if not take then return nil end
    if not checkLock() then return nil end

    -- resolve eventtype from msgType
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

  function rv:reload()
    if not self.take then return nil end
    self:load(self.take)
  end

  ---------- FACTORY BODY

  if take then rv:load(take) end
  return rv
end
