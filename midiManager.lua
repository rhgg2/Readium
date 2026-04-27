-- See docs/midiManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util.print(...)
end

-- Shared by newMidiManager + newSidecarReconciler. Inverse derived to avoid drift.
local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }
local chanMsgTypes = {}
for k, v in pairs(chanMsgLUT) do chanMsgTypes[v] = k end

local BASE36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'

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

local function fromBase36(txt)
  local n = tonumber(txt, 36)
  if not n then print('Error! ' .. txt .. ' is not a valid base36 string') end
  return n
end

function newMidiManager(take)

  ---------- PRIVATE

  local noteTbl    = {}
  local ccTbl      = {}
  local sysexTbl   = {}
  local sidecarTbl = {}     -- Readium-magic sysex events; not exposed via sysexes()
  local uuidTbl    = {}
  local maxUUID    = 0
  local lock       = false
  local fire  -- installed below, once mm exists

  local sr = newSidecarReconciler()

  local INTERNALS = { idx = true, uuidIdx = true }

  -- REAPER MIDI_SetCCShape codes 0..5
  local shapeLUT = { step = 0, linear = 1, slow = 2, ['fast-start'] = 3, ['fast-end'] = 4, bezier = 5 }
  local shapeNames = {}
  for k, v in pairs(shapeLUT) do shapeNames[v] = k end

  -- 11 rows of (handle length, long-arm θ, short-arm θ) sampled at |tau| =
  -- 0, 0.1, ..., 1.0. Interpolated linearly in |tau|; cubic Bézier solved
  -- for y at parameter t by 20-step bisection.
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
    local fi = util.clamp(math.abs(tau), 0, 1) * 10
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

  -- tension is ignored except for 'bezier'.
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
        tbl[uuid] = util.unserialise(fields)
      end
    end
    return tbl
  end

  -- Stripped when serialising per-event metadata. saveMetadatum picks the
  -- right set by entry shape (msgType marks a cc).
  local noteEventFields = {
    idx = true, ppq = true, endppq = true, chan = true,
    pitch = true, vel = true, muted = true, uuid = true, uuidIdx = true,
  }
  local ccEventFields = {
    idx = true, uuidIdx = true, ppq = true, msgType = true, chan = true,
    cc = true, pitch = true, val = true,
    muted = true, shape = true, tension = true, uuid = true,
  }

  local function saveMetadatum(uuid)
    if not take then return end

    local uuidTxt = toBase36(uuid)
    local entry   = uuidTbl[uuid]

    if not entry then
      print('Error! uuid not found')
      return
    end

    local strip = entry.msgType and ccEventFields or noteEventFields
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. uuidTxt, util.serialise(entry, strip), true)

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
      util.add(keyList, uuidTxt)
      saveMetadatum(uuid)
    end

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

  -- Longest note at each (ppq, chan, pitch) wins; losers deleted.
  -- Returns one event per collided coordinate.
  local function removeDuplicateEvents()
    if not take then return {} end

    local ok, noteCount = reaper.MIDI_CountEvts(take)
    if not ok then return {} end

    local groups = {}      -- tag -> { ppq, chan, pitch, kept = {idx,endppq}, dropped = {idx,...} }
    for i = 0, noteCount-1 do
      local ok, _, _, ppq, endppq, chan, pitch = reaper.MIDI_GetNote(take, i)
      if ok then
        chan = chan + 1
        local tag = ppq .. '|' .. chan .. '|' .. pitch
        local g = groups[tag]
        if not g then
          groups[tag] = { ppq = ppq, chan = chan, pitch = pitch,
                          kept = { idx = i, endppq = endppq }, dropped = {} }
        elseif endppq > g.kept.endppq then
          util.add(g.dropped, g.kept.idx)
          g.kept = { idx = i, endppq = endppq }
        else
          util.add(g.dropped, i)
        end
      end
    end

    local events, toDelete = {}, {}
    for _, g in pairs(groups) do
      if #g.dropped > 0 then
        util.add(events, { ppq = g.ppq, chan = g.chan, pitch = g.pitch,
                           droppedCount = #g.dropped })
        for _, idx in ipairs(g.dropped) do util.add(toDelete, idx) end
      end
    end

    table.sort(toDelete)
    reaper.MIDI_DisableSort(take)
    for i = #toDelete, 1, -1 do
      reaper.MIDI_DeleteNote(take, toDelete[i])
    end
    reaper.MIDI_Sort(take)

    return events
  end

  ----- Utils

  local function assignNewUUID(entry)
    maxUUID = maxUUID + 1
    entry.uuid = maxUUID
    uuidTbl[maxUUID] = entry
    return maxUUID
  end

  ---------- PUBLIC

  local mm = {}
  fire = util.installHooks(mm)

  ----- Load

  function mm:load(newTake)
    if not newTake then return end

    local takeSwapped = take ~= newTake
    if takeSwapped then take = newTake end

    noteTbl    = {}
    ccTbl      = {}
    sysexTbl   = {}
    sidecarTbl = {}
    uuidTbl    = {}
    maxUUID    = 0
    lock       = false

    local notesLUT = {}

    local dedupEvents = removeDuplicateEvents()

    local ok, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    if not ok then return end

    for i = 0, noteCount-1 do
      local ok, _, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
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
        notesLUT[tag] = util.add(noteTbl, entry)
      end
    end

    for i = 0, ccCount-1 do
      local ok, _, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
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
        end

        local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
        entry.shape = shapeNames[shape] or 'step'
        if entry.shape == 'bezier' then entry.tension = tension end

        util.add(ccTbl, entry)
      end
    end

    local UUIDCount = {}

    for i = 0, textCount-1 do
      local ok, _, _, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
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

    local reassignEvents = {}
    reaper.MIDI_DisableSort(take)
    for _, note in ipairs(noteTbl) do
      local uuid = note.uuid
      if uuid and UUIDCount[uuid] > 1 then
        local oldUUID = uuid
        local newUUID = assignNewUUID(note)
        UUIDCount[oldUUID] = UUIDCount[oldUUID] - 1
        UUIDCount[newUUID] = 1
        metadata[newUUID] = util.clone(metadata[oldUUID]) or {}
        reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, nil, 15, string.format('NOTE %d %d custom rdm_%s', note.chan - 1, note.pitch, toBase36(newUUID)), false)
        util.add(reassignEvents, { oldUuid = oldUUID, newUuid = newUUID,
                                   ppq = note.ppq, chan = note.chan, pitch = note.pitch })
      elseif not uuid then
        local newUUID = assignNewUUID(note)
        UUIDCount[newUUID] = 1
        metadata[newUUID] = {}
        reaper.MIDI_InsertTextSysexEvt(take, false, false, note.ppq, 15, string.format('NOTE %d %d custom rdm_%s', note.chan - 1, note.pitch, toBase36(newUUID)))
      end
    end
    reaper.MIDI_Sort(take)

    -- Rebuilds sysexTbl + sidecarTbl after any mid-load mutation that
    -- shifts text/sysex idxs. Refreshes note.uuidIdx via notesLUT.
    local function scanText()
      sysexTbl   = {}
      sidecarTbl = {}
      local _, _, _, textCount = reaper.MIDI_CountEvts(take)
      for i = 0, textCount-1 do
        local ok, _, _, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
        if ok and eventtype == 15 then
          local uuidTxt, chan, pitch = parseUUIDNotation(msg)
          if uuidTxt then
            local note = notesLUT[ppq .. '|' .. chan .. '|' .. pitch]
            if note then note.uuidIdx = i end
          else
            util.add(sysexTbl, { idx = i, ppq = ppq, msgType = 'notation', val = msg })
          end
        elseif ok then
          local sidecar = eventtype == -1 and sr:decode(msg) or nil
          if sidecar then
            sidecar.idx  = i
            sidecar.ppq  = ppq
            sidecar.body = msg
            util.add(sidecarTbl, sidecar)
          else
            util.add(sysexTbl, { idx = i, ppq = ppq,
                                 msgType = textMsgTypes[eventtype] or ('meta_' .. eventtype),
                                 val = msg })
          end
        end
      end
    end

    scanText()

    -- After scanText: relink each uuid'd cc's uuidIdx to its live sidecar.
    local function rewireCcSysexIdxs()
      local uuidToCc = {}
      for _, c in ipairs(ccTbl) do if c.uuid then uuidToCc[c.uuid] = c end end
      for _, s in ipairs(sidecarTbl) do
        local c = uuidToCc[s.uuid]
        if c then c.uuidIdx = s.idx end
      end
    end

    -- See docs: dedup runs after reconciliation so rule 2 sees uuid attachments.
    local function dedupCCs()
      local function key(c)
        return c.ppq .. '|' .. c.chan .. '|' .. c.msgType .. '|' .. (c.cc or c.pitch or 0)
      end

      local groups = {}
      for loc, c in ipairs(ccTbl) do
        local k = key(c)
        local g = groups[k]
        if not g then
          groups[k] = { winnerLoc = loc, losers = {} }
        else
          -- Rule 2: uuid'd beats plain; on tie, latest wins.
          local winner = ccTbl[g.winnerLoc]
          if winner.uuid == nil or c.uuid ~= nil then
            util.add(g.losers, g.winnerLoc); g.winnerLoc = loc
          else
            util.add(g.losers, loc)
          end
        end
      end

      local events, ccDelIdxs, sxDelIdxs, loserSet = {}, {}, {}, {}
      for _, g in pairs(groups) do
        if #g.losers > 0 then
          local kept = ccTbl[g.winnerLoc]
          util.add(events, { ppq = kept.ppq, chan = kept.chan, msgType = kept.msgType,
                             cc = kept.cc, pitch = kept.pitch,
                             droppedCount = #g.losers, keptHadUuid = kept.uuid ~= nil })
          for _, loc in ipairs(g.losers) do
            local lc = ccTbl[loc]
            loserSet[loc] = true
            util.add(ccDelIdxs, lc.idx)
            if lc.uuidIdx then util.add(sxDelIdxs, lc.uuidIdx) end
          end
        end
      end

      if #events == 0 then return events end

      -- Descending so each delete leaves earlier siblings untouched. cc
      -- and sysex arrays are independent in REAPER; the passes don't interfere.
      table.sort(ccDelIdxs, function(a, b) return a > b end)
      table.sort(sxDelIdxs, function(a, b) return a > b end)
      reaper.MIDI_DisableSort(take)
      for _, idx in ipairs(ccDelIdxs) do reaper.MIDI_DeleteCC(take, idx) end
      for _, idx in ipairs(sxDelIdxs) do reaper.MIDI_DeleteTextSysexEvt(take, idx) end
      reaper.MIDI_Sort(take)

      -- ccTbl is idx-sorted ascending; kept subsequence is too, so renumber in one pass.
      local kept = {}
      for loc, c in ipairs(ccTbl) do
        if not loserSet[loc] then c.idx = #kept; util.add(kept, c) end
      end
      ccTbl = kept

      -- Sysex idxs shifted from the deletes; rebuild and rewire.
      scanText(); rewireCcSysexIdxs()

      return events
    end

    -- Sidecar reconciliation — see docs/midiManager.md for the staging.
    -- Noisy binds (stages 2-4) need their sidecars rewritten; orphans are
    -- deleted so they don't re-emit on every load. Stale-key sweep in
    -- saveMetadata purges the orphans' rdm_<uuid> ext-data.
    local reconcileEvents = {}
    if #sidecarTbl > 0 then
      local r = sr:reconcile(sidecarTbl, ccTbl)
      reconcileEvents = r.events

      local rebinds = {}
      for _, b in ipairs(r.binds) do
        local cc      = ccTbl[b.ccIdx]
        local sidecar = sidecarTbl[b.sidecarIdx]
        cc.uuid    = sidecar.uuid
        cc.uuidIdx = sidecar.idx
        if cc.uuid > maxUUID then maxUUID = cc.uuid end
        if not b.silent then util.add(rebinds, b) end
      end

      local orphanSysexIdxs = {}
      for _, sci in ipairs(r.unboundSidecarIdxs) do
        util.add(orphanSysexIdxs, sidecarTbl[sci].idx)
      end

      if #rebinds > 0 or #orphanSysexIdxs > 0 then
        reaper.MIDI_DisableSort(take)
        for _, b in ipairs(rebinds) do
          local cc      = ccTbl[b.ccIdx]
          local sidecar = sidecarTbl[b.sidecarIdx]
          reaper.MIDI_SetTextSysexEvt(take, sidecar.idx, nil, nil, cc.ppq, -1, sr:encode(cc), true)
        end
        -- Descending order so each delete leaves earlier indices untouched.
        table.sort(orphanSysexIdxs, function(a, b) return a > b end)
        for _, idx in ipairs(orphanSysexIdxs) do
          reaper.MIDI_DeleteTextSysexEvt(take, idx)
        end
        reaper.MIDI_Sort(take)

        -- Sysex indices are stale after deletion + sort; rebuild and rewire.
        scanText(); rewireCcSysexIdxs()
      end
    end

    local ccDedupEvents = dedupCCs()

    for _, note in ipairs(noteTbl) do
      util.assign(note, metadata[note.uuid])
      uuidTbl[note.uuid] = note
    end

    for _, cc in ipairs(ccTbl) do
      if cc.uuid then
        util.assign(cc, metadata[cc.uuid])
        uuidTbl[cc.uuid] = cc
      end
    end

    saveMetadata()

    if takeSwapped            then fire('takeSwapped', nil) end
    if #dedupEvents > 0       then fire('notesDeduped',    { events = dedupEvents }) end
    if #reassignEvents > 0    then fire('uuidsReassigned', { events = reassignEvents }) end
    if #reconcileEvents > 0   then fire('ccsReconciled',   { events = reconcileEvents }) end
    if #ccDedupEvents > 0     then fire('ccsDeduped',      { events = ccDedupEvents }) end
    fire('reload', nil)
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
    return util.clone(note, INTERNALS)
  end

  function mm:notes()
    local i = 0
    return function()
      i = i + 1
      local note = noteTbl[i]
      if note then
        return i, util.clone(note, INTERNALS)
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

      util.assign(note, t)

      saveMetadatum(note.uuid)
      return
    end

    if not checkLock() then return end

    local note = noteTbl[loc]
    if not note then return end

    local chan = (t.chan or note.chan) - 1

    -- nil args leave REAPER's value unchanged
    reaper.MIDI_SetNote(take, note.idx, nil, t.muted, t.ppq, t.endppq, chan, t.pitch, t.vel, true)

    util.assign(note, t)
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

    local note = util.clone(t)
    if not note.muted then note.muted = nil end
    assignNewUUID(note)
    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, string.format('NOTE %d %d custom rdm_%s', t.chan - 1, t.pitch, toBase36(note.uuid)))

    local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
    note.uuidIdx = sysexCount - 1
    note.idx = noteCount - 1
    util.add(noteTbl, note)

    saveMetadatum(note.uuid)

    return #noteTbl
  end

  ----- CCs

  function mm:getCC(loc)
    local msg = ccTbl[loc]
    return util.clone(msg, INTERNALS)
  end

  function mm:ccs()
    local i = 0
    return function()
      i = i + 1
      local msg = ccTbl[i]
      if msg then
        return i, util.clone(msg, INTERNALS)
      end
    end
  end

  function mm:deleteCC(loc)
    if not (take and checkLock()) then return end

    local msg = ccTbl[loc]
    if not msg then return end

    reaper.MIDI_DeleteCC(take, msg.idx)
    if msg.uuid then
      reaper.MIDI_DeleteTextSysexEvt(take, msg.uuidIdx)
      uuidTbl[msg.uuid] = nil
      -- saveMetadata at end-of-modify purges the rdm_<uuid> ext-data slot
    end
    ccTbl[loc] = nil
  end

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
    if not take then return end

    local msg = ccTbl[loc]
    if not msg then return end

    -- ccEventFields is the structural set; any other key is metadata.
    local hasStructural = t.ppq or t.msgType or t.chan or t.cc or t.pitch
                          or t.val or t.muted ~= nil or t.shape or t.tension
    local hasMetadata = false
    for k in pairs(t) do
      if not ccEventFields[k] then hasMetadata = true; break end
    end

    -- Lockless metadata-only carve-out (mirrors assignNote).
    if not hasStructural and msg.uuid then
      util.assign(msg, t)
      saveMetadatum(msg.uuid)
      return
    end

    if not checkLock() then return end

    if hasStructural then
      local chanmsg, msg2, msg3
      if t.msgType then
        chanmsg = chanMsgLUT[t.msgType]
        if not chanmsg then
          print('Error! Unspecified message type')
          return
        end
        msg2, msg3 = reconstruct(t)
      elseif t.val or t.cc or t.pitch then
        msg2, msg3 = reconstruct(util.assign(util.clone(msg), t))
      end
      local chan = t.chan and t.chan - 1
      reaper.MIDI_SetCC(take, msg.idx, nil, t.muted, t.ppq, chanmsg, chan, msg2, msg3, true)
    end

    util.assign(msg, t)

    if hasStructural then
      if msg.muted == false then msg.muted = nil end
      if msg.msgType ~= 'cc' then msg.cc    = nil end
      if msg.msgType ~= 'pa' then msg.pitch = nil end
      if t.shape or t.tension then
        local shape = shapeLUT[msg.shape] or 0
        reaper.MIDI_SetCCShape(take, msg.idx, shape, msg.tension or 0, true)
      end
      if msg.shape ~= 'bezier' then msg.tension = nil end
    end

    -- First metadata stamp: allocate uuid + insert its sidecar.
    if hasMetadata and not msg.uuid then
      assignNewUUID(msg)
      reaper.MIDI_InsertTextSysexEvt(take, false, false, msg.ppq, -1, sr:encode(msg))
      local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
      msg.uuidIdx = sysexCount - 1
    end

    -- Resync sidecar ppq + fingerprint so the next load is tier-1 clean.
    if msg.uuid and hasStructural then
      reaper.MIDI_SetTextSysexEvt(take, msg.uuidIdx, nil, nil, msg.ppq, -1, sr:encode(msg), true)
    end

    if msg.uuid then saveMetadatum(msg.uuid) end
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

    local msg = util.clone(t)
    if not msg.muted then msg.muted = nil end

    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    msg.idx = ccCount - 1

    if t.shape or t.tension then
      reaper.MIDI_SetCCShape(take, msg.idx, shapeLUT[t.shape] or 0, t.tension or 0, true)
    end
    if msg.shape ~= 'bezier' then msg.tension = nil end

    util.add(ccTbl, msg)

    return #ccTbl
  end


  ----- Sysex / text

  function mm:getSysex(loc)
    local sysex = sysexTbl[loc]
    return util.clone(sysex, INTERNALS)
  end

  function mm:sysexes()
    local i = 0
    return function()
      i = i + 1
      local sysex = sysexTbl[i]
      if sysex then
        return i, util.clone(sysex, INTERNALS)
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

    util.assign(sysex, t)
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

    local sysex = util.clone(t)

    local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
    sysex.idx = sysexCount - 1
    util.add(sysexTbl, sysex)

    return #sysexTbl
  end

  ----- Take data

  function mm:take()
    return take
  end

  -- REAPER convention: shape on A governs the curve from A to next.
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
        util.add(result, { ppq = ppq, num = num, denom = denom })
      end
    end

    return result
  end

  if take then mm:load(take) end
  return mm
end

-- Pure factory; see docs/midiManager.md for the wire format and tiers.
function newSidecarReconciler()
  local sr = {}

  local SIDECAR_MAGIC = '\x7D\x52\x44\x4D'  -- '}RDM'

  -- wire `id` byte: controller for cc, pitch for pa, 0 for the rest.
  local function idOf(cc) return cc.cc or cc.pitch or 0 end

  function sr:encode(cc)
    local typeByte = chanMsgLUT[cc.msgType]
    if not typeByte then return nil end
    local typeNib = typeByte >> 4

    local lo, hi
    if cc.msgType == 'pb' then
      local raw = (cc.val or 0) + 8192
      lo, hi = raw & 0x7F, (raw >> 7) & 0x7F
    else
      lo, hi = (cc.val or 0) & 0x7F, 0
    end

    return SIDECAR_MAGIC
      .. string.char(typeNib)
      .. string.char((cc.chan or 1) - 1)
      .. string.char(idOf(cc))
      .. string.char(lo)
      .. string.char(hi)
      .. toBase36(cc.uuid)
  end

  function sr:decode(body)
    if not body or #body < 10 then return nil end
    if body:sub(1, 4) ~= SIDECAR_MAGIC then return nil end

    local msgType = chanMsgTypes[body:byte(5) << 4]
    if not msgType then return nil end

    local chan = body:byte(6) + 1
    local id   = body:byte(7)
    local lo   = body:byte(8)
    local hi   = body:byte(9)

    local val = (msgType == 'pb') and (((hi << 7) | lo) - 8192) or lo

    local uuid = tonumber(body:sub(10), 36)
    if not uuid then return nil end

    local out = { uuid = uuid, msgType = msgType, chan = chan, val = val }
    if     msgType == 'cc' then out.cc    = id
    elseif msgType == 'pa' then out.pitch = id
    end
    return out
  end

  local function bucketKey(e) return e.msgType .. '|' .. e.chan .. '|' .. idOf(e) end

  -- Payload for rebind kinds; orphaned/ambiguous build payloads inline.
  local function payload(kind, sidecar, cc, extras)
    local from = cc or sidecar
    local p = { kind = kind, uuid = sidecar.uuid, ppq = from.ppq,
                chan = from.chan, msgType = from.msgType,
                cc = from.cc, pitch = from.pitch }
    if extras then for k, v in pairs(extras) do p[k] = v end end
    return p
  end

  -- Four-stage reconciler — see docs/midiManager.md for the staging.
  function sr:reconcile(sidecars, ccs)
    local THRESHOLD_FRAC = 0.5
    local THRESHOLD_MIN  = 2

    local scBuckets, ccBuckets = {}, {}
    for i, s in ipairs(sidecars) do util.bucket(scBuckets, bucketKey(s), i) end
    for i, c in ipairs(ccs)      do util.bucket(ccBuckets, bucketKey(c), i) end

    local binds, events, scBound, ccBound = {}, {}, {}, {}

    local function bind(sci, cci, silent, evt)
      scBound[sci] = true; ccBound[cci] = true
      util.add(binds, { sidecarIdx = sci, ccIdx = cci, silent = silent })
      if evt then util.add(events, evt) end
    end

    for k, scIdxs in pairs(scBuckets) do
      local ccIdxs = ccBuckets[k] or {}

      -- Stage 1: exact (ppq, val).
      local byPpqVal = {}
      for _, cci in ipairs(ccIdxs) do
        local c = ccs[cci]
        util.bucket(byPpqVal, c.ppq .. '|' .. (c.val or 0), cci)
      end
      for _, sci in ipairs(scIdxs) do
        local s = sidecars[sci]
        local kk = s.ppq .. '|' .. (s.val or 0)
        for _, cci in ipairs(byPpqVal[kk] or {}) do
          if not ccBound[cci] then bind(sci, cci, true); break end
        end
      end

      -- Stage 2: same ppq, val drift.
      local byPpq = {}
      for _, cci in ipairs(ccIdxs) do
        if not ccBound[cci] then util.bucket(byPpq, ccs[cci].ppq, cci) end
      end
      for _, sci in ipairs(scIdxs) do
        if not scBound[sci] then
          local s = sidecars[sci]
          for _, cci in ipairs(byPpq[s.ppq] or {}) do
            if not ccBound[cci] then
              local c = ccs[cci]
              bind(sci, cci, false,
                   payload('valueRebound', s, c, { oldVal = s.val, newVal = c.val }))
              break
            end
          end
        end
      end

      -- Stage 3: consensus offset.
      local scLeft, ccLeft = {}, {}
      for _, sci in ipairs(scIdxs) do if not scBound[sci] then util.add(scLeft, sci) end end
      for _, cci in ipairs(ccIdxs) do if not ccBound[cci] then util.add(ccLeft, cci) end end

      if #scLeft > 0 and #ccLeft > 0 then
        -- Each sidecar votes once per distinct offset it could realise.
        local offsetVotes, sidecarOffsets = {}, {}
        for _, sci in ipairs(scLeft) do
          local s = sidecars[sci]
          local seen = {}
          for _, cci in ipairs(ccLeft) do
            local off = ccs[cci].ppq - s.ppq
            if not seen[off] then
              seen[off] = true
              offsetVotes[off] = (offsetVotes[off] or 0) + 1
            end
          end
          sidecarOffsets[sci] = seen
        end

        local bestOff, bestCount, tied = nil, 0, false
        for off, count in pairs(offsetVotes) do
          if count > bestCount then bestOff, bestCount, tied = off, count, false
          elseif count == bestCount then tied = true end
        end

        local threshold = math.max(THRESHOLD_MIN, math.ceil(THRESHOLD_FRAC * #scLeft))
        if bestOff and not tied and bestCount >= threshold then
          for _, sci in ipairs(scLeft) do
            if sidecarOffsets[sci][bestOff] then
              local s = sidecars[sci]
              for _, cci in ipairs(ccLeft) do
                if not ccBound[cci] and ccs[cci].ppq - s.ppq == bestOff then
                  bind(sci, cci, false,
                       payload('consensusRebound', s, ccs[cci], { offset = bestOff }))
                  break
                end
              end
            end
          end
        end
      end

      -- Stage 4: per-orphan fallback.
      for _, sci in ipairs(scIdxs) do
        if not scBound[sci] then
          local s = sidecars[sci]
          local cands = {}
          for _, cci in ipairs(ccIdxs) do
            if not ccBound[cci] then util.add(cands, cci) end
          end
          if #cands == 0 then
            util.add(events, { kind = 'orphaned', uuid = s.uuid, lastPpq = s.ppq,
                               chan = s.chan, msgType = s.msgType,
                               cc = s.cc, pitch = s.pitch })
          elseif #cands == 1 then
            bind(sci, cands[1], false, payload('guessedRebound', s, ccs[cands[1]]))
          else
            local ppqs = {}
            for _, cci in ipairs(cands) do util.add(ppqs, ccs[cci].ppq) end
            util.add(events, { kind = 'ambiguous', uuid = s.uuid, candidatePpqs = ppqs })
          end
        end
      end
    end

    local unboundSidecarIdxs, unboundCcIdxs = {}, {}
    for i = 1, #sidecars do if not scBound[i] then util.add(unboundSidecarIdxs, i) end end
    for i = 1, #ccs       do if not ccBound[i] then util.add(unboundCcIdxs,      i) end end

    return { binds = binds, events = events,
             unboundSidecarIdxs = unboundSidecarIdxs, unboundCcIdxs = unboundCcIdxs }
  end

  return sr
end
