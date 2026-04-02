local function print(...)
  if ( not ... ) then
    reaper.ShowConsoleMsg("nil value\n")
    return
  end
  reaper.ShowConsoleMsg(...)
  reaper.ShowConsoleMsg("\n")
end

--------------------

util = {}

function util:print_r(root)
  local cache = {  [root] = "." }
  local function _dump(t,space,name)
    local temp = {}
    for k,v in pairs(t) do
      local key = tostring(k)
      if cache[v] then
        table.insert(temp,"+" .. key .. " {" .. cache[v].."}")
      elseif type(v) == "table" then
        local new_key = name .. "." .. key
        cache[v] = new_key
        table.insert(temp,"+" .. key .. _dump(v,space .. (next(t,k) and "|" or " " ).. string.rep(" ",#key),new_key))
      else
        table.insert(temp,"+" .. key .. " [" .. tostring(v).."]")
      end
    end
    return table.concat(temp,"\n"..space)
  end
  print(_dump(root, "",""))
end

function util:assign(t1,t2)
  for k, v in pairs(t2) do
    t1[k] = v
  end
  return t1
end

function util:clamp(val,min,max)
  if val < min then
    return min
  elseif val > max then
    return max
  else
    return val
  end
end

function util:fromBase36(txt)
  if not tonumber(txt,36) then
    print("Error! " .. txt .. " is not a valid base36 string")
    return nil
  else
    return tonumber(txt,36)
  end
end

function util:toBase36(num)
  local alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  if num == 0 then return "0" end
  local result = ""
  while num > 0 do
    local remainder = num % 36
    result = string.sub(alphabet, remainder + 1, remainder + 1) .. result
    num = math.floor(num / 36)
  end
  return result
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
--   mgr:reload()                       -- sorts MIDI, then reloads from mgr.take
--
--   After any call to an assign* or delete* function, the caller MUST
--   call mgr:reload() before reading state back. Assign functions push
--   changes to the REAPER API and update metadata, but internal tables
--   are only fully consistent after a reload.
--
-- NOTES  (identified by idx + uuid)
--   mgr:getNote(idx)                   -- returns a copy of the note at idx, or nil
--   mgr:getNoteByUUID(uuid)            -- returns a copy of the note with uuid, or nil
--   mgr:notes()                        -- iterator: for idx, note in mgr:notes() do ... end
--   mgr:assignNote(t)                  -- update or create a note
--     Update: t must contain idx and uuid matching an existing note.
--             Only provided fields are changed (ppq, endppq, chan, pitch, vel,
--             plus any custom metadata fields).
--     Create: t must contain ppq, endppq, chan, pitch, and vel.
--             A new UUID is assigned automatically.
--   mgr:deleteNote(t)                  -- delete an existing note
--     t must contain idx and uuid matching an existing note.
--     Removes both the MIDI note and its notation-event UUID marker.
--
-- CCs  (identified by idx)
--   mgr:getCC(idx)                     -- returns a copy of the CC at idx, or nil
--   mgr:ccs()                          -- iterator: for idx, cc in mgr:ccs() do ... end
--   mgr:assignCC(t)                    -- update or create a CC event
--     Update: t must contain idx matching an existing CC.
--             Supports msgType change; val is decoded per type:
--               cc  -> t.cc, t.val       pb -> t.val (-8192..8191)
--               pa  -> t.pitch, t.val    pc/at -> t.val
--     Create: t must contain ppq, chan, and val. Defaults to msgType 'cc'.
--   mgr:deleteCC(t)                    -- delete a CC event; t must contain idx
--
-- SYSEX / TEXT  (identified by idx)
--   mgr:getSysex(idx)                  -- returns a copy of the sysex entry at idx, or nil
--   mgr:sysexes()                      -- iterator: for idx, sx in mgr:sysexes() do ... end
--   mgr:assignSysex(t)                 -- update or create a sysex/text event
--     Update: t must contain idx matching an existing entry.
--     Create: t must contain ppq, msgType, and val.
--             msgType is one of: sysex, text, copyright, trackname,
--             instrument, lyric, marker, cuepoint, notation.
--   mgr:deleteSysex(t)                 -- delete a sysex/text event; t must contain idx
--
-- FIELDS
--   mgr.take                           -- the current REAPER take (read-only)
--
-- NOTES ON ACCESSORS
--   All get* functions and iterators return shallow copies. Modifying a
--   returned table has no effect on internal state — use assign* to
--   write changes back. Iterators must not be interleaved with assign*
--   or delete* calls; collect entries first, then mutate after the loop.
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
 
  local noteTbl  = {}
  local ccTbl    = {}
  local sysexTbl = {}
  local uuidTbl  = {}
  local maxUUID  = 0

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
        for kv in fields:gmatch("[^,]+") do
          local k, v = kv:match("([^=]+)=([^=]+)")
          if k then
            tbl[uuid][k] = tonumber(v) or v
          end
        end
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
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_" .. uuidTxt, table.concat(fields, ","), true)
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

  local function assignNewUUID(note)
    maxUUID = maxUUID + 1
    note.uuid = maxUUID
    uuidTbl[maxUUID] = note
    return maxUUID
  end

  ---------- PUBLIC FUNCTIONS

  -- Load take and initialise tables
  function rv:load(take)
    if not take then return nil end
    self.take = take

    noteTbl  = {}
    ccTbl    = {}
    sysexTbl = {}
    uuidTbl  = {}
    maxUUID  = 0

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

    -- get text/sysex events, including UUIDs
    local UUIDCount = {}
    local sysexIdx = 0
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
        else
          -- some other notation event
          sysexTbl[sysexIdx] = {
            idx     = i,
            ppq     = ppq,
            msgType = 'notation',
            val     = msg,
          }
          sysexIdx = sysexIdx + 1
        end
      elseif ok then
        -- all other text/sysex events (text meta, sysex, etc.)
        sysexTbl[sysexIdx] = {
            idx     = i,
            ppq     = ppq,
            msgType = textMsgTypes[eventtype] or ("meta_" .. eventtype),
            val     = msg,
        }
        sysexIdx = sysexIdx + 1
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

    -- Re-scan notation events to rebuild correct uuidIdx for all notes
    local _, _, _, newTextCount = reaper.MIDI_CountEvts(take)
    for i = 0, newTextCount-1 do
      local ok2, _, _, ppq2, eventtype2, msg2 = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok2 and eventtype2 == 15 then
        local chan2, pitch2, uuidTxt2 = msg2:match("^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$")
        if uuidTxt2 then
          local tag2 = ppq2 .. '|' .. chan2 .. '|' .. pitch2
          local note2 = notesLUT[tag2]
          if note2 then
            note2.uuidIdx = i
          end
        end
      end
    end


    -- add metadata to notes
    for _,note in pairs(noteTbl) do
      util:assign(note, metadata[note.uuid])
      uuidTbl[note.uuid] = note
    end

    -- save all metadata, built from uuidTbl
    saveMetadata()
    util:print_r(noteTbl)
    util:print_r(ccTbl)
    util:print_r(sysexTbl)
    util:print_r(uuidTbl)
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

  --- You must call rv:reload after deletion or insertion of notes!

  function rv:deleteNote(t)
    local take = self.take
    if not take then return nil end

    local note = nil
    if t.idx and noteTbl[t.idx] then
      local candidate = noteTbl[t.idx]
      if candidate.uuid == t.uuid then
        note = candidate
      end
    end

    if not note then return nil end

    -- remove the notation event first
    if note.uuidIdx then
      reaper.MIDI_DeleteTextSysexEvt(take, note.uuidIdx)
    end
    reaper.MIDI_DeleteNote(take, note.idx)

    -- now client reloads
  end

  function rv:assignNote(t)
    local take = self.take
    if not take then return nil end

    local note = nil
    if t.idx and noteTbl[t.idx] then
      local candidate = noteTbl[t.idx]
      if candidate.uuid == t.uuid then
        note = candidate
      end
    end

    if note then
      -- update the existing note (nil values will do nothing)
      reaper.MIDI_SetNote(take, note.idx, nil, nil, t.ppq, t.endppq, t.chan, t.pitch, t.vel, true)

      -- merge fields into the note
      util:assign(note, t)

      -- if ppq, chan, or pitch changed, update the notation event to match
      if (t.ppq or t.chan or t.pitch) and note.uuidIdx then
        reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, note.ppq, 15,
                                      string.format("NOTE %d %d custom rdm_%s", note.chan, note.pitch, util:toBase36(note.uuid)), true)
      end
    else
      if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
        print('Error! Underspecified new note')
        return nil
      end

      -- create a new note
      reaper.MIDI_InsertNote(take, false, false, t.ppq, t.endppq, t.chan, t.pitch, t.vel, true)
      -- copy data to uuid table (which populates metadata)
      note = util:assign({ }, t)
      assignNewUUID(note)

      -- create notation event for UUID
      reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15,
                                     string.format("NOTE %d %d custom rdm_%s", t.chan, t.pitch, util:toBase36(note.uuid)), true)
    end

    saveMetadatum(note.uuid)
    -- now client reloads
  end

  --- CC FUNCTIONS
  function rv:getCC(idx)
    local msg = ccTbl[idx]
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

  function rv:deleteCC(t)
    local take = self.take
    if not take then return nil end

    local msg = nil
    if t.idx and ccTbl[t.idx] then
      msg = ccTbl[t.idx]
    end

    if msg then reaper.MIDI_DeleteCC(take, msg.idx) end
    -- now client reloads
  end

  function rv:assignCC(t)
    local take = self.take
    if not take then return nil end

    local msg = nil
    if t.idx and ccTbl[t.idx] then
      msg = ccTbl[t.idx]
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
    
    local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

    if msg then
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
      elseif t.val then
        t.msgType = msg.msgType
        msg2, msg3 = reconstruct(t)
      end
      reaper.MIDI_SetCC(take, msg.idx, nil, nil, t.ppq, chanmsg, t.chan, msg2, msg3, true)

      -- update the table entry
      util:assign(msg, t)
      if msg.msgType ~= 'cc' then msg.cc = nil end
      if msg.msgType ~= 'pa' then msg.pitch = nil end
    else
      if t.msgType == nil then t.msgType = 'cc' end

      if t.ppq == nil or t.chan == nil or t.val == nil then
        print('Error! Underspecified new cc event')
        return nil
      end
      
      if not chanMsgLUT[t.msgType] then
        print('Error! Unspecified message type')
        return nil
      end

      local chanmsg = chanMsgLUT[t.msgType]
      local msg2, msg3 = reconstruct(t)

      reaper.MIDI_InsertCC(take, false, false, t.ppq, chanmsg, t.chan, msg2, msg3)
      -- now client 
    end
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

  function rv:deleteSysex(t)
    local take = self.take
    if not take then return nil end

    local sysex = nil
    if t.idx  then
      for _, v in pairs(sysexTbl) do
        if v.idx == t.idx then
          sysex = v
        end
      end
    end

    if sysex then reaper.MIDI_DeleteTextSysexEvt(take, sysex.idx) end
    --- now client reloads
  end

  function rv:assignSysex(t)
    local take = self.take
    if not take then return nil end

    local sysex = nil
    if t.idx  then
      for _, v in pairs(sysexTbl) do
        if v.idx == t.idx then
          sysex = v
        end
      end
    end

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

    if sysex then
      local eventtype = nil
      if t.msgType then
        if not eventTypeLUT[t.msgType] then
          print('Error! Unspecified message type')
          return nil
        end
        eventtype = eventTypeLUT[t.msgType]
      end

      reaper.MIDI_SetTextSysexEvt(take, sysex.idx, nil, nil, t.ppq, eventtype, t.val, true)

      -- update the table entry
      util:assign(sysex, t)
    else
      if t.ppq == nil or t.msgType == nil or t.val == nil then
        print('Error! Underspecified new sysex/text event')
        return nil
      end
      if not eventTypeLUT[t.msgType] then
        print('Error! Unspecified message type')
        return nil
      end
      local eventtype = eventTypeLUT[t.msgType]

      reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, eventtype, t.val)
      -- now client reloads
    end
  end

  function rv:reload()
    if not self.take then return nil end
    reaper.MIDI_Sort(self.take)
    self:load(self.take)
  end

  ---------- FACTORY BODY

  if take then rv:load(take) end
  --return rv
end

--------------------

function Main()
  local item = reaper.GetSelectedMediaItem(0,0)
  local take = newTakeManager(reaper.GetActiveTake(item))
end

Main()


