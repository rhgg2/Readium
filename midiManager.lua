-- See docs/midiManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util:print(...)
end

function newMidiManager(take)

  ---------- PRIVATE
 
  local noteTbl   = {}
  local ccTbl     = {}
  local sysexTbl  = {}
  local uuidTbl   = {}
  local maxUUID   = 0
  local lock      = false
  local fire  -- installed below, once mm exists

  local INTERNALS = { idx = true, uuidIdx = true }

  -- channel message (CC-family) and text/sysex type LUTs. Keep the name→code
  -- direction canonical and derive the inverse so the two stay in sync.
  local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }
  local chanMsgTypes = {}
  for k, v in pairs(chanMsgLUT) do chanMsgTypes[v] = k end

  -- CC point shape (REAPER MIDI_SetCCShape codes 0..5)
  local shapeLUT = { step = 0, linear = 1, slow = 2, ['fast-start'] = 3, ['fast-end'] = 4, bezier = 5 }
  local shapeNames = {}
  for k, v in pairs(shapeLUT) do shapeNames[v] = k end

  -- Bezier tension LUT: 11 rows of (handle length, long-arm θ, short-arm θ)
  -- sampled at |tau| = 0, 0.1, ..., 1.0. Interpolated linearly in |tau|, then
  -- the cubic Bézier is solved for y at parameter t by 20-step bisection.
  local BEZIER = {
    { 0.2794, 0.4636,    0.4636 },
    { 0.3442, 0.7704,    0.3384 },
    { 0.4020, 0.9849,    0.2466 },
    { 0.4642, 1.1455,    0.1812 },
    { 0.5326, 1.2647,    0.1353 },
    { 0.6059, 1.3532,    0.1011 },
    { 0.6820, 1.4199,    0.0738 },
    { 0.7604, 1.4714,    0.0515 },
    { 0.8397, 1.5116,    0.0321 },
    { 0.9198, 1.5441,    0.0154 },
    { 1.0000, math.pi/2, 0      },
  }

  local function bezierSample(tau, t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local fi = util:clamp(math.abs(tau), 0, 1) * 10
    local i = math.min(math.floor(fi), 9)
    local f = fi - i
    local r0, r1 = BEZIER[i+1], BEZIER[i+2]
    local h  = r0[1] + (r1[1] - r0[1]) * f
    local tL = r0[2] + (r1[2] - r0[2]) * f
    local tS = r0[3] + (r1[3] - r0[3]) * f
    local t1, t2 = tS, tL
    if tau < 0 then t1, t2 = tL, tS end
    local ax, ay = h*math.cos(t1),     h*math.sin(t1)
    local bx, by = 1 - h*math.cos(t2), 1 - h*math.sin(t2)
    local lo, hi = 0, 1
    for _ = 1, 20 do
      local s = (lo + hi) * 0.5
      local u = 1 - s
      local x = 3*u*u*s*ax + 3*u*s*s*bx + s*s*s
      if x < t then lo = s else hi = s end
    end
    local s = (lo + hi) * 0.5
    local u = 1 - s
    return 3*u*u*s*ay + 3*u*s*s*by + s*s*s
  end

  -- Curve fraction in [0,1] for shape at parameter t ∈ [0,1]. tension only
  -- meaningful for 'bezier'; ignored elsewhere.
  local function curveSample(shape, tension, t)
    if     shape == 'step'       then return t >= 1 and 1 or 0
    elseif shape == 'linear'     then return t
    elseif shape == 'slow'       then return t*t*(3 - 2*t)
    elseif shape == 'fast-start' then local u = 1 - t; return 1 - u*u*u
    elseif shape == 'fast-end'   then return t*t*t
    elseif shape == 'bezier'     then return bezierSample(tension or 0, t)
    end
  end

  local eventTypeLUT = {
    sysex = -1, text = 1, copyright = 2, trackname = 3,
    instrument = 4, lyric = 5, marker = 6, cuepoint = 7, notation = 15,
  }
  local textMsgTypes = {}
  for k, v in pairs(eventTypeLUT) do textMsgTypes[v] = k end

  local BASE36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'

  local function fromBase36(txt)
    local n = tonumber(txt, 36)
    if not n then print('Error! ' .. txt .. ' is not a valid base36 string') end
    return n
  end

  local function toBase36(num)
    if num == 0 then return '0' end
    local result = ''
    while num > 0 do
      local r = num % 36
      result = string.sub(BASE36, r + 1, r + 1) .. result
      num = math.floor(num / 36)
    end
    return result
  end

  -- matches only NOTE notation events tagged with our rdm_<uuid> marker
  local function parseUUIDNotation(msg)
    local chan, pitch, uuidTxt = msg:match('^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$')
    if uuidTxt then return uuidTxt, chan + 1, pitch end
  end

  local function loadMetadata()
    if not take then return {} end

    local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', '', false)
    if not (ok and keysText and keysText ~= '') then return {} end
    local tbl = {}
    for uuidTxt in keysText:gmatch('[^,]+') do
      local uuid = fromBase36(uuidTxt)
      tbl[uuid] = { }

      local entryOk, fields = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. uuidTxt, '', false)
      if entryOk and fields then
        tbl[uuid] = util:unserialise(fields)
      end
    end
    return tbl
  end

  -- note-event fields stripped when serialising per-note metadata
  local noteEventFields = {
    idx = true, ppq = true, endppq = true, chan = true,
    pitch = true, vel = true, muted = true, uuid = true, uuidIdx = true,
  }

  local function saveMetadatum(uuid)
    if not take then return end

    local uuidTxt = toBase36(uuid)
    local data = uuidTbl[uuid]

    if not data then
      print('Error! uuid not found')
      return
    end

    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. uuidTxt, util:serialise(data, noteEventFields), true)

    -- Ensure this UUID is in the keys list so loadMetadata() finds it on reload
    local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', '', false)
    if not ok or not keysText or not keysText:find(uuidTxt, 1, true) then
      local keys = (ok and keysText and keysText ~= '') and (keysText .. ',' .. uuidTxt) or uuidTxt
      reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', keys, true)
    end
  end

  local function saveMetadata()
    if not take then return end
    
    -- Collect uuids as both a set (for stale-key check) and a list (for serialisation)
    local newKeys, keyList = {}, {}
    for uuid in pairs(uuidTbl) do
      local uuidTxt = toBase36(uuid)
      newKeys[uuidTxt] = true
      util:add(keyList, uuidTxt)
      saveMetadatum(uuid)
    end

    -- Delete stale keys that exist in the old key list but not in metadata table
    local ok, oldKeysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', '', false)
    if ok and oldKeysText and oldKeysText ~= '' then
      for oldUuidTxt in oldKeysText:gmatch('[^,]+') do
        if not newKeys[oldUuidTxt] then
          -- Writing an empty string effectively removes the extension data
          reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. oldUuidTxt, '', true)
        end
      end
    end

    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', table.concat(keyList, ','), true)
  end

  local function removeDuplicateEvents()
    if not take then return end
    
    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return end

    local notesSeen = {}
    local notesToDelete = {}
    
    for i=0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        chan = chan + 1
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        if notesSeen[tag] then
          local last = notesSeen[tag]
          if endppq > last.endppq then
            util:add(notesToDelete, last.idx)
            notesSeen[tag] = { idx = i, endppq = endppq }
          else
            util:add(notesToDelete, i)
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
  
  ----- Utils

  local function assignNewUUID(note)
    maxUUID = maxUUID + 1
    note.uuid = maxUUID
    uuidTbl[maxUUID] = note
    return maxUUID
  end

  ---------- PUBLIC

  local mm = {}
  fire = util:installHooks(mm)

  ----- Load

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

    local notesLUT = {}

    local removedCount = removeDuplicateEvents() or 0
    if removedCount > 0 then
      print('Removed ' .. removedCount .. ' duplicate events!')
    end

    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return end

    for i = 0, noteCount-1 do
      local ok, selected, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        chan = chan + 1
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        local entry = {
          idx    = i,
          ppq    = ppq,
          endppq = endppq,
          chan   = chan,
          pitch  = pitch,
          vel    = vel,
        }
        if muted then entry.muted = true end
        notesLUT[tag] = util:add(noteTbl, entry)
      end
    end

    for i = 0, ccCount-1 do
      local ok, selected, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
      if ok then
        chan = chan + 1
        local msgType = chanMsgTypes[chanmsg] or ('chanmsg_' .. chanmsg)
        local entry = {
          idx     = i,
          ppq     = ppq,
          msgType = msgType,
          chan    = chan,
        }
        if muted then entry.muted = true end

        if msgType == 'pa' then
          entry.pitch = msg2
          entry.val = msg3
        elseif msgType == 'cc' then
          entry.cc  = msg2
          entry.val = msg3
        elseif msgType == 'pc' or msgType == 'at' then
          entry.val = msg2
        elseif msgType == 'pb' then
          entry.val = ((msg3 << 7) | msg2) - 8192
        else
          entry.val = msg2
          entry.val2 = msg3
        end

        local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
        entry.shape = shapeNames[shape] or 'step'
        if entry.shape == 'bezier' then entry.tension = tension end

        util:add(ccTbl, entry)
      end
    end

    -- Scan notation events to obtain UUIDs for notes
    local UUIDCount = {}

    for i = 0, textCount-1 do
      local ok, selected, muted, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local uuidTxt, chan, pitch = parseUUIDNotation(msg)
        if uuidTxt then
          local uuid = fromBase36(uuidTxt)
          local note = notesLUT[ppq .. '|' .. chan .. '|' .. pitch]
          if note then
            note.uuid = uuid
            note.uuidIdx = i
            UUIDCount[uuid] = (UUIDCount[uuid] or 0) + 1
          else
            print('Error! UUID at ' .. ppq .. ' has no coincident note')
          end
        end
      end
    end

    local metadata = loadMetadata()
    
    for uuid in pairs(metadata) do
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
        metadata[newUUID] = util:clone(metadata[oldUUID]) or {}
        reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, nil, 15, string.format('NOTE %d %d custom rdm_%s', note.chan - 1, note.pitch, toBase36(newUUID)), false)
      elseif not uuid then
        local newUUID = assignNewUUID(note)
        UUIDCount[newUUID] = 1
        metadata[newUUID] = {}
        reaper.MIDI_InsertTextSysexEvt(take, false, false, note.ppq, 15, string.format('NOTE %d %d custom rdm_%s', note.chan - 1, note.pitch, toBase36(newUUID)))
      end
    end
    reaper.MIDI_Sort(take)

    -- rescan: step 3 inserted notation events, so uuidIdx values are stale
    _ , _, _, textCount = reaper.MIDI_CountEvts(take)
    for i = 0, textCount-1 do
      local ok, selected, muted, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local uuidTxt, chan, pitch = parseUUIDNotation(msg)
        if uuidTxt then
          local note = notesLUT[ppq .. '|' .. chan .. '|' .. pitch]
          if note then
            note.uuidIdx = i
          end
        else
          -- some other notation event
          util:add(sysexTbl, {
            idx     = i,
            ppq     = ppq,
            msgType = 'notation',
            val     = msg,
          })
        end
      elseif ok then
        util:add(sysexTbl, {
            idx     = i,
            ppq     = ppq,
            msgType = textMsgTypes[eventtype] or ('meta_' .. eventtype),
            val     = msg,
        })
      end
    end

    for _, note in ipairs(noteTbl) do
      util:assign(note, metadata[note.uuid])
      uuidTbl[note.uuid] = note
    end

    saveMetadata()

    fire(changed, mm)
  end

  function mm:reload()
    if not take then return end
    self:load(take)
  end


  ----- Locking

  local function checkLock()
    assert(lock, 'Error! You must call modification functions via modify()!')
    return true
  end

  function mm:modify(fn)
    if not take then return end
      
    lock = true
    reaper.MIDI_DisableSort(take)
    local ok, err = pcall(fn)
    reaper.MIDI_Sort(take)
    self:reload()
    lock = false
    if not ok then print('Error in modify: ' .. tostring(err)) end
  end

  ----- Notes

  function mm:getNote(loc)
    local note = noteTbl[loc]
    return util:clone(note, INTERNALS)
  end

  function mm:notes()
    local i = 0
    return function()
      i = i + 1
      local note = noteTbl[i]
      if note then
        return i, util:clone(note, INTERNALS)
      end
    end
  end

  function mm:deleteNote(loc)
    if not (take and checkLock()) then return end

    local note = noteTbl[loc]
    if not note then return end

    reaper.MIDI_DeleteNote(take, note.idx)

    -- clean up internal tables
    uuidTbl[note.uuid] = nil
    noteTbl[loc] = nil
  end

  function mm:assignNote(loc, t)
    if not take then return end

    if not (t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil) then
      -- just metadata, allow without lock
      local note = noteTbl[loc]
      if not note then return end

      util:assign(note, t)

      saveMetadatum(note.uuid)
      return
    end

    if not checkLock() then return end

    local note = noteTbl[loc]
    if not note then return end

    local chan = (t.chan or note.chan) - 1

    -- nil args leave REAPER's value unchanged
    reaper.MIDI_SetNote(take, note.idx, nil, t.muted, t.ppq, t.endppq, chan, t.pitch, t.vel, true)

    util:assign(note, t)
    if note.muted == false then note.muted = nil end

    -- notation event encodes (chan, pitch) at ppq, so keep it in sync
    if (t.ppq or t.chan or t.pitch) and note.uuidIdx then
      reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, note.ppq, 15, string.format('NOTE %d %d custom rdm_%s', chan, note.pitch, toBase36(note.uuid)), true)
    end

    saveMetadatum(note.uuid)
  end

  function mm:addNote(t)
    if not (take and checkLock()) then return end

    if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
      print('Error! Underspecified new note')
      return
    end

    reaper.MIDI_InsertNote(take, false, t.muted or false, t.ppq, t.endppq, t.chan - 1, t.pitch, t.vel, true)

    local note = util:clone(t)
    if not note.muted then note.muted = nil end
    local uuid = assignNewUUID(note)
    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, string.format('NOTE %d %d custom rdm_%s', t.chan - 1, t.pitch, toBase36(note.uuid)), true)

    local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
    note.uuidIdx = sysexCount - 1
    note.idx = noteCount - 1
    util:add(noteTbl, note)

    saveMetadatum(note.uuid)

    return #noteTbl
  end

  ----- CCs

  function mm:getCC(loc)
    local msg = ccTbl[loc]
    return util:clone(msg, INTERNALS)
  end

  function mm:ccs()
    local i = 0
    return function()
      i = i + 1
      local msg = ccTbl[i]
      if msg then
        return i, util:clone(msg, INTERNALS)
      end
    end
  end

  function mm:deleteCC(loc)
    if not (take and checkLock()) then return end

    local msg = ccTbl[loc]
    if not msg then return end

    reaper.MIDI_DeleteCC(take, msg.idx)
    ccTbl[loc] = nil
  end

  -- pack semantic fields back into REAPER's (msg2, msg3) per msgType
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

    local msg = ccTbl[loc]
    if not msg then return end

    local chanmsg, msg2, msg3
    if t.msgType then
      chanmsg = chanMsgLUT[t.msgType]
      if not chanmsg then
        print('Error! Unspecified message type')
        return
      end
      msg2, msg3 = reconstruct(t)
    elseif t.val or t.cc or t.pitch then
      msg2, msg3 = reconstruct(util:assign(util:clone(msg), t))
    end
    local chan = t.chan and t.chan - 1
    reaper.MIDI_SetCC(take, msg.idx, nil, t.muted, t.ppq, chanmsg, chan, msg2, msg3, true)

    util:assign(msg, t)
    if msg.muted == false then msg.muted = nil end
    if msg.msgType ~= 'cc' then msg.cc = nil end
    if msg.msgType ~= 'pa' then msg.pitch = nil end

    if t.shape or t.tension then
      local shape = shapeLUT[msg.shape] or 0
      reaper.MIDI_SetCCShape(take, msg.idx, shape, msg.tension or 0, true)
    end
    if msg.shape ~= 'bezier' then msg.tension = nil end
  end

  function mm:addCC(t)
    if not (take and checkLock()) then return end

    if t.msgType == nil then t.msgType = 'cc' end

    if t.ppq == nil or t.chan == nil or t.val == nil then
      print('Error! Underspecified new cc event')
      return
    end

    local chanmsg = chanMsgLUT[t.msgType]
    if not chanmsg then
      print('Error! Unspecified message type')
      return
    end
    local msg2, msg3 = reconstruct(t)

    reaper.MIDI_InsertCC(take, false, t.muted or false, t.ppq, chanmsg, t.chan - 1, msg2, msg3)

    local msg = util:clone(t)
    if not msg.muted then msg.muted = nil end

    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    msg.idx = ccCount - 1

    if t.shape or t.tension then
      reaper.MIDI_SetCCShape(take, msg.idx, shapeLUT[t.shape] or 0, t.tension or 0, true)
    end
    if msg.shape ~= 'bezier' then msg.tension = nil end

    util:add(ccTbl, msg)

    return #ccTbl
  end


  ----- Sysex / text

  function mm:getSysex(loc)
    local sysex = sysexTbl[loc]
    return util:clone(sysex, INTERNALS)
  end

  function mm:sysexes()
    local i = 0
    return function()
      i = i + 1
      local sysex = sysexTbl[i]
      if sysex then
        return i, util:clone(sysex, INTERNALS)
      end
    end
  end

  function mm:deleteSysex(loc)
    if not (take and checkLock()) then return end

    local sysex = sysexTbl[loc]
    if not sysex then return end

    reaper.MIDI_DeleteTextSysexEvt(take, sysex.idx)
    sysexTbl[loc] = nil
  end

  function mm:assignSysex(loc, t)
    if not (take and checkLock()) then return end

    local sysex = sysexTbl[loc]
    if not sysex then return end

    local eventtype = t.msgType and eventTypeLUT[t.msgType] or eventTypeLUT[sysex.msgType]

    reaper.MIDI_SetTextSysexEvt(take, sysex.idx, nil, nil, t.ppq, eventtype, t.val, true)

    util:assign(sysex, t)
  end

  function mm:addSysex(t)
    if not (take and checkLock()) then return end

    local eventtype = t.msgType and eventTypeLUT[t.msgType]
    if not eventtype then
      print('Error! Unspecified message type')
      return
    end
    
    if t.ppq == nil or t.msgType == nil or t.val == nil then
      print('Error! Underspecified new sysex/text event')
      return
    end

    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, eventtype, t.val)

    local sysex = util:clone(t)

    local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
    sysex.idx = sysexCount - 1
    util:add(sysexTbl, sysex)

    return #sysexTbl
  end

  ----- Take data

  function mm:take()
    return take
  end

  -- Interpolated value at ppq between two scalar events A and B, using the
  -- shape/tension carried on A (REAPER's convention: a CC point's shape
  -- governs the curve from that point to the next). Returns A.val for step
  -- and shapeless events.
  function mm:interpolate(A, B, ppq)
    if not A.shape or A.shape == 'step' then return A.val end
    local span = B.ppq - A.ppq
    if span == 0 then return A.val end
    local t = (ppq - A.ppq) / span
    return (A.val or 0) + curveSample(A.shape, A.tension, t) * ((B.val or 0) - (A.val or 0))
  end

  function mm:resolution()
    if not take then return end
    return reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  end

  function mm:length()
    if not take then return end
    local source = reaper.GetMediaItemTake_Source(take)
    local sourceLengthQN = reaper.GetMediaSourceLength(source)
    return reaper.MIDI_GetPPQPosFromProjQN(take, sourceLengthQN) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  end

  function mm:timeSigs()
    if not take then return {} end

    local item = reaper.GetMediaItemTake_Item(take)
    local startTime = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local itemLength = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
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

    for i = 0, count - 1 do
      local _, pos, _, _, _, num, denom, _ = reaper.GetTempoTimeSigMarker(0, i)
      if num > 0 and pos > startTime and pos < endTime then
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pos) - basePPQ
        util:add(result, { ppq = ppq, num = num, denom = denom })
      end
    end

    return result
  end

  if take then mm:load(take) end
  return mm
end
