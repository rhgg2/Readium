-- See docs/midiManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util.print(...)
end

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

  local notes      = {}
  local ccs        = {}
  local eventsByUuid      = {}
  local maxUUID    = 0
  local lock       = false

  local INTERNALS = { idx = true, uuidIdx = true }

  -- REAPER MIDI_SetCCShape codes 0..5
  local shapeLUT = { step = 0, linear = 1, slow = 2, ['fast-start'] = 3, ['fast-end'] = 4, bezier = 5 }
  local shapeNames = {}
  for k, v in pairs(shapeLUT) do shapeNames[v] = k end

  local curveSample do
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
      { 1.0000, math.pi / 2, 0 },
    }

    local function bezierSample(tau, t)
      if t <= 0 then return 0 end
      if t >= 1 then return 1 end
      local fi     = util.clamp(math.abs(tau), 0, 1) * 10
      local i      = math.min(math.floor(fi), 9)
      local f      = fi - i
      local r0, r1 = BEZIER[i + 1], BEZIER[i + 2]
      local h      = r0[1] + (r1[1] - r0[1]) * f
      local tL     = r0[2] + (r1[2] - r0[2]) * f
      local tS     = r0[3] + (r1[3] - r0[3]) * f
      local t1, t2 = tS, tL
      if tau < 0 then t1, t2 = tL, tS end
      local ax, ay = h * math.cos(t1), h * math.sin(t1)
      local bx, by = 1 - h * math.cos(t2), 1 - h * math.sin(t2)
      local lo, hi = 0, 1
      for _ = 1, 20 do
        local s = (lo + hi) * 0.5
        local u = 1 - s
        local x = 3 * u * u * s * ax + 3 * u * s * s * bx + s * s * s
        if x < t then lo = s else hi = s end
      end
      local s = (lo + hi) * 0.5
      local u = 1 - s
      return 3 * u * u * s * ay + 3 * u * s * s * by + s * s * s
    end

    function curveSample(shape, tension, t)
      if shape == 'step' then
        return t >= 1 and 1 or 0
      elseif shape == 'linear' then
        return t
      elseif shape == 'slow' then
        return t * t * (3 - 2 * t)
      elseif shape == 'fast-start' then
        local u = 1 - t; return 1 - u * u * u
      elseif shape == 'fast-end' then
        return t * t * t
      elseif shape == 'bezier' then
        return bezierSample(tension or 0, t)
      end
    end
  end

  local noteSidecarEncode, noteSidecarDecode, ccSidecarEncode, ccSidecarDecode do
    local SIDECAR_MAGIC = '\x7D\x52\x44\x4D'  -- '}RDM'
    local function idOf(cc) return cc.cc or cc.pitch or 0 end

    function noteSidecarEncode(note)
      return string.format('NOTE %d %d custom rdm_%s', note.chan-1, note.pitch, toBase36(note.uuid))
    end

    function noteSidecarDecode(msg)
      local chan, pitch, uuidTxt = msg:match('^NOTE%s+(%d+)%s+(%d+)%s+custom%s+rdm_(.+)$')
      if uuidTxt then
        return { chan = chan + 1, pitch = pitch, uuid = fromBase36(uuidTxt) }
      end
    end

    function ccSidecarEncode(cc)
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

    function ccSidecarDecode(body)
      if not body or #body < 10 then return nil end
      if body:sub(1, 4) ~= SIDECAR_MAGIC then return nil end

      local out = {}
      out.msgType = chanMsgTypes[body:byte(5) << 4]
      out.uuid = tonumber(body:sub(10), 36)
      if not out.msgType or not out.uuid then return nil end
      local lo, hi = body:byte(8), body:byte(9)
      out.chan = body:byte(6) + 1
      out.val = (out.msgType == 'pb') and (((hi << 7) | lo) - 8192) or lo
      if     out.msgType == 'cc' then out.cc    = body:byte(7)
      elseif out.msgType == 'pa' then out.pitch = body:byte(7)
      end
      return out
    end
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
    local evt   = eventsByUuid[uuid]

    if not evt then
      print('Error! uuid not found')
      return
    end

    local strip = evt.msgType and ccEventFields or noteEventFields
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. uuidTxt, util.serialise(evt, strip), true)

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
    for uuid in pairs(eventsByUuid) do
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

  ----- Utils

  -- Sparse → dense, preserving order. n is the original (pre-sparsening) length.
  local function compact(t, n)
    local out = {}
    for i = 1, n do if t[i] ~= nil then out[#out+1] = t[i] end end
    return out
  end

  local function assignNewUUID(evt)
    maxUUID = maxUUID + 1
    evt.uuid = maxUUID
    eventsByUuid[maxUUID] = evt
    return maxUUID
  end

  ---------- PUBLIC

  local mm = {}
  local fire = util.installHooks(mm)

  ----- Load

  function mm:load(newTake)
    if not newTake then return end

    local takeSwapped = take ~= newTake
    if takeSwapped then take = newTake end

    notes, ccs, eventsByUuid, maxUUID, lock = {}, {}, {}, 0, false
    local ccSidecars, noteSidecars = {}, {}
    local sidecarRewrites, sidecarInserts, sidecarDeletes, ccDeletes = {}, {}, {}, {}
    local noteDedupEvents, ccDedupEvents, reassignEvents, reconcileEvents = {}, {}, {}, {}

    local metadata = loadMetadata()
    for uuid in pairs(metadata) do if uuid > maxUUID then maxUUID = uuid end end

    ----- Helper functions
    local function noteKey(n)   return n.ppq .. '|' .. n.chan .. '|' .. n.pitch end
    local function idOf(cc)     return cc.cc or cc.pitch or 0 end
    local function ccIdKey(e)   return e.msgType .. '|' .. e.chan .. '|' .. idOf(e) end
    local function ccPPQKey(e)  return ccIdKey(e)  .. '|' .. e.ppq end
    local function ccFullKey(e) return ccPPQKey(e) .. '|' .. (e.val or 0) end

    ----- Read notes
    local _, noteCount = reaper.MIDI_CountEvts(take)
    for i = 0, noteCount-1 do
      local ok, _, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if ok then
        local evt = { idx = i, ppq = ppq, endppq = endppq, chan = chan + 1, pitch = pitch, vel = vel }
        if muted then evt.muted = true end
        util.add(notes, evt)
      end
    end

    ----- Note dedup → flush. Longest endppq wins; flush before sysex read so
    ----- the cascade-deleted notation events don't leave us with stale idxs.

    local notesKeyed = {}
    do
      local groups, noteDeletes = {}, {}
      for loc, n in ipairs(notes) do
        local key = noteKey(n)
        local g = groups[key]
        if not g then
          groups[key] = { kept = loc, dropped = {} }
        elseif n.endppq > notes[g.kept].endppq then
          util.add(g.dropped, g.kept); g.kept = loc
        else
          util.add(g.dropped, loc)
        end
      end
      for key, g in pairs(groups) do
        local kept = notes[g.kept]
        notesKeyed[key] = kept
        if #g.dropped > 0 then
          util.add(noteDedupEvents, util.pick(kept, 'ppq chan pitch', { droppedCount = #g.dropped }))
          for _, loc in ipairs(g.dropped) do
            util.add(noteDeletes, notes[loc].idx)
            notes[loc] = nil
          end
        end
      end
      if #noteDeletes > 0 then
        table.sort(noteDeletes)
        reaper.MIDI_DisableSort(take)
        for i = #noteDeletes, 1, -1 do reaper.MIDI_DeleteNote(take, noteDeletes[i]) end
        reaper.MIDI_Sort(take)
      end
    end

    ----- Read ccs + sysex (notation events for notes, magic sidecars for ccs)
    local _, _, ccCount, textCount = reaper.MIDI_CountEvts(take)

    for i = 0, ccCount-1 do
      local ok, _, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
      if ok then
        local msgType = chanMsgTypes[chanmsg] or ('chanmsg_' .. chanmsg)
        local evt = { idx = i, ppq = ppq, msgType = msgType, chan = chan + 1}
        if muted then evt.muted = true end
        if     msgType == 'pa' then evt.pitch, evt.val = msg2, msg3
        elseif msgType == 'cc' then evt.cc,    evt.val = msg2, msg3
        elseif msgType == 'pc' or msgType == 'at' then evt.val = msg2
        elseif msgType == 'pb' then evt.val = ((msg3 << 7) | msg2) - 8192
        end
        local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
        evt.shape = shapeNames[shape] or 'step'
        if evt.shape == 'bezier' then evt.tension = tension end
        util.add(ccs, evt)
      end
    end

    for i = 0, textCount-1 do
      local ok, _, _, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      if ok and eventtype == 15 then
        local sc = noteSidecarDecode(msg)
        if sc then util.add(noteSidecars, util.assign(sc, { idx = i, ppq = ppq})) end
      elseif ok and eventtype == -1 then
        local sc = ccSidecarDecode(msg)
        if sc then util.add(ccSidecars, util.assign(sc, { idx = i, ppq = ppq})) end
      end
    end
    local sidecarCount = #ccSidecars

    ----- CC dedup (in-memory only — flush is bundled into the single bracket below)

    do
      local stageOneHit = {}
      for _, s in ipairs(ccSidecars) do
        stageOneHit[ccFullKey(s)] = true
      end

      local groups = {}
      for loc, c in ipairs(ccs) do util.bucket(groups, ccPPQKey(c), loc) end

      for _, locs in pairs(groups) do
        if #locs > 1 then
          local candidates, fallbacks = {}, {}
          for _, loc in ipairs(locs) do
            util.add(stageOneHit[ccFullKey(ccs[loc])] and candidates or fallbacks, loc)
          end
          local pool = #candidates > 0 and candidates or fallbacks
          local winnerLoc = pool[#pool]
          local kept = ccs[winnerLoc]
          util.add(ccDedupEvents, util.pick(kept, 'ppq chan msgType cc pitch', { droppedCount = #locs - 1 }))
          for _, loc in ipairs(locs) do
            if loc ~= winnerLoc then util.add(ccDeletes, ccs[loc].idx); ccs[loc] = nil end
          end
        end
      end
    end

    ----- UUID unification (notes ↔ noteSidecars). First-arrival wins per tag;
    ----- duplicates and orphans get queued for deletion.

    do
      local uuidCount = {}
      for _, ns in ipairs(noteSidecars) do
        local note = notesKeyed[noteKey(ns)]
        if note and not note.uuid then
          note.uuid, note.uuidIdx = ns.uuid, ns.idx
          uuidCount[ns.uuid] = (uuidCount[ns.uuid] or 0) + 1
        else
          util.add(sidecarDeletes, ns.idx)
        end
      end

      for _, note in pairs(notesKeyed) do
        local uuid = note.uuid
        if uuid and uuidCount[uuid] > 1 then
          local oldUUID = uuid
          local newUUID = assignNewUUID(note)
          uuidCount[oldUUID] = uuidCount[oldUUID] - 1
          uuidCount[newUUID] = 1
          metadata[newUUID] = util.clone(metadata[oldUUID]) or {}
          util.add(sidecarRewrites, {
            idx = note.uuidIdx, ppq = note.ppq, type = 15,
            body = noteSidecarEncode(note),
          })
          util.add(reassignEvents, util.pick(note, 'ppq chan pitch', { oldUuid = oldUUID, newUuid = newUUID }))
        elseif uuid then
          eventsByUuid[uuid] = note
        else
          local newUUID = assignNewUUID(note)
          uuidCount[newUUID] = 1
          metadata[newUUID] = {}
          util.add(sidecarInserts, util.pick(note, 'ppq chan pitch', { uuid = newUUID }))
        end
      end
    end

    ----- Sidecar reconcile (ccs ↔ ccSidecars). Working sets are
    ----- clones; what's left in `sidecars` after stage 4 is unmatched
    ----- and queued for deletion.
    if next(ccSidecars) then
      local THRESHOLD_FRAC, THRESHOLD_MIN = 0.5, 2
      local scsWorking, ccsWorking = util.clone(ccSidecars), util.clone(ccs)
      local scBuckets, ccBuckets

      local function bucketBy(keyFn)
        scBuckets, ccBuckets = {}, {}
        for _, s in pairs(scsWorking) do util.bucket(scBuckets, keyFn(s), s) end
        for _, c in pairs(ccsWorking) do util.bucket(ccBuckets, keyFn(c), c) end
      end

      local function bind(s, c, kind, extras)
        local function removeFirst(t, e)
          for i, x in pairs(t) do if x == e then t[i] = nil; return end end
        end
        c.uuid, c.uuidIdx = s.uuid, s.idx
        if s.uuid > maxUUID then maxUUID = s.uuid end
        if kind then
          util.add(sidecarRewrites, { idx = s.idx, ppq = c.ppq, type = -1, body = ccSidecarEncode(c) })
          util.add(reconcileEvents,
            util.assign(util.pick(c, 'ppq chan msgType cc pitch', { kind = kind, uuid = s.uuid }),
                        extras or {}))
        end
        removeFirst(scsWorking, s); removeFirst(ccsWorking, c)
      end

      -- Stage 1: exact (ppq, val).
      bucketBy(ccFullKey)
      for k, scs in pairs(scBuckets) do
        local cs = ccBuckets[k] or {}
        for _, s in ipairs(scs) do
          if cs[1] then bind(s, cs[1]); table.remove(cs, 1) end
        end
      end

      -- Stage 2: same ppq, val drift.
      bucketBy(ccPPQKey)
      for k, scs in pairs(scBuckets) do
        local cs = ccBuckets[k] or {}
        for _, s in ipairs(scs) do
          local c = cs[1]
          if c then
            bind(s, c, 'valueRebound', { oldVal = s.val, newVal = c.val })
            table.remove(cs, 1)
          end
        end
      end

      -- Stage 3: consensus offset.
      bucketBy(ccIdKey)
      for k, scs in pairs(scBuckets) do
        local cs = ccBuckets[k] or {}
        if #scs > 0 and #cs > 0 then
          local offsetVotes, sidecarOffsets = {}, {}
          for _, s in ipairs(scs) do
            local seen = {}
            for _, c in ipairs(cs) do
              local off = c.ppq - s.ppq
              if not seen[off] then
                seen[off] = true
                offsetVotes[off] = (offsetVotes[off] or 0) + 1
              end
            end
            sidecarOffsets[s] = seen
          end

          local bestOff, bestCount, tied = nil, 0, false
          for off, count in pairs(offsetVotes) do
            if count > bestCount then bestOff, bestCount, tied = off, count, false
            elseif count == bestCount then tied = true end
          end

          local threshold = math.max(THRESHOLD_MIN, math.ceil(THRESHOLD_FRAC * #scs))
          if bestOff and not tied and bestCount >= threshold then
            for _, s in ipairs(scs) do
              if sidecarOffsets[s][bestOff] then
                for i, c in ipairs(cs) do
                  if c.ppq - s.ppq == bestOff then
                    bind(s, c, 'consensusRebound', { offset = bestOff })
                    table.remove(cs, i)
                    break
                  end
                end
              end
            end
          end
        end
      end

      -- Stage 4: per-orphan fallback.
      bucketBy(ccIdKey)
      for k, scs in pairs(scBuckets) do
        local cs = ccBuckets[k] or {}
        for _, s in ipairs(scs) do
          if #cs == 0 then
            util.add(reconcileEvents, util.pick(s, 'uuid chan msgType cc pitch', { kind = 'orphaned', lastPpq = s.ppq }))
          elseif #cs == 1 then
            bind(s, cs[1], 'guessedRebound')
            table.remove(cs, 1)
          else
            local ppqs = {}
            for _, c in ipairs(cs) do util.add(ppqs, c.ppq) end
            util.add(reconcileEvents, { kind = 'ambiguous', uuid = s.uuid, candidatePpqs = ppqs })
          end
        end
      end

      -- Whatever's left in `sidecars` never bound → delete.
      if next(scsWorking) then
        local unbound = {}
        for _, s in pairs(scsWorking) do unbound[s] = true end
        for loc, sc in pairs(ccSidecars) do
          if unbound[sc] then
            util.add(sidecarDeletes, sc.idx)
            ccSidecars[loc] = nil
          end
        end
      end
    end

    ----- Single bracketed flush: sets first (idx-stable), deletes descending,
    ----- inserts last (their idxs aren't tracked — final read will pick them up).
    local hasFlush = #sidecarRewrites + #ccDeletes + #sidecarDeletes + #sidecarInserts > 0
    if hasFlush then
      reaper.MIDI_DisableSort(take)
      for _, r in ipairs(sidecarRewrites) do
        reaper.MIDI_SetTextSysexEvt(take, r.idx, nil, nil, r.ppq, r.type, r.body, true)
      end

      table.sort(ccDeletes, function(a, b) return a > b end)
      table.sort(sidecarDeletes, function(a, b) return a > b end)
      for _, idx in ipairs(ccDeletes) do reaper.MIDI_DeleteCC(take, idx) end
      for _, idx in ipairs(sidecarDeletes) do reaper.MIDI_DeleteTextSysexEvt(take, idx) end

      for _, ins in ipairs(sidecarInserts) do
        reaper.MIDI_InsertTextSysexEvt(take, false, false, ins.ppq, 15, noteSidecarEncode(ins))
      end
      reaper.MIDI_Sort(take)
    end

    ----- Compact in-memory tables to dense.
    notes      = compact(notes,      noteCount)
    ccs        = compact(ccs,        ccCount)
    ccSidecars = compact(ccSidecars, sidecarCount)

    ----- Final read pass: refresh idx / uuidIdx from current REAPER state.
    notesKeyed = {}
    local ccsKeyed = {}
    for _, n in ipairs(notes) do
      notesKeyed[noteKey(n)] = n
      util.assign(n, metadata[n.uuid])
    end
    for _, c in ipairs(ccs) do
      ccsKeyed[ccPPQKey(c)] = c
      if c.uuid then
        eventsByUuid[c.uuid] = c
        util.assign(c, metadata[c.uuid])
      end
    end

    _, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    for i = 0, noteCount-1 do
      local ok, _, _, ppq, _, chan, pitch = reaper.MIDI_GetNote(take, i)
      if ok then
        local evt = { ppq = ppq, chan = chan + 1, pitch = pitch }
        local n = notesKeyed[noteKey(evt)]
        if n then n.idx = i end
      end
    end
    for i = 0, ccCount-1 do
      local ok, _, _, ppq, chanmsg, chan, msg2 = reaper.MIDI_GetCC(take, i)
      if ok then
        local msgType = chanMsgTypes[chanmsg] or ('chanmsg_'..chanmsg)
        local evt = { ppq = ppq, chan = chan + 1, msgType = msgType }
        if msgType == 'cc' then evt.cc = msg2 end
        if msgType == 'pa' then evt.pitch = msg2 end
        local c = ccsKeyed[ccPPQKey(evt)]
        if c then c.idx = i end
      end
    end
    for i = 0, textCount-1 do
      local ok, _, _, _, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      local sc = ok and (eventtype == 15  and noteSidecarDecode(msg)
                      or eventtype == -1 and ccSidecarDecode(msg))
      local evt = sc and eventsByUuid[sc.uuid]
      if evt then evt.uuidIdx = i end
    end

    ----- Persist + signals
    saveMetadata()

    if takeSwapped           then fire('takeSwapped',     nil) end
    if #noteDedupEvents > 0  then fire('notesDeduped',    { events = noteDedupEvents }) end
    if #reassignEvents > 0   then fire('uuidsReassigned', { events = reassignEvents })  end
    if #ccDedupEvents > 0    then fire('ccsDeduped',      { events = ccDedupEvents })   end
    if #reconcileEvents > 0  then fire('ccsReconciled',   { events = reconcileEvents }) end
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
    local note = notes[loc]
    return util.clone(note, INTERNALS)
  end

  function mm:notes()
    local i = 0
    return function()
      i = i + 1
      local note = notes[i]
      if note then
        return i, util.clone(note, INTERNALS)
      end
    end
  end

  function mm:deleteNote(loc)
    if not (take and checkLock()) then return end

    local note = notes[loc]
    if not note then return end

    reaper.MIDI_DeleteNote(take, note.idx)

    -- clean up internal tables
    eventsByUuid[note.uuid] = nil
    notes[loc] = nil
  end

  function mm:assignNote(loc, t)
    if not take then return end

    if not (t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil) then
      -- just metadata, allow without lock
      local note = notes[loc]
      if not note then return end

      util.assign(note, t)

      saveMetadatum(note.uuid)
      return
    end

    if not checkLock() then return end

    local note = notes[loc]
    if not note then return end

    local chan = (t.chan or note.chan) - 1

    -- nil args leave REAPER's value unchanged
    reaper.MIDI_SetNote(take, note.idx, nil, t.muted, t.ppq, t.endppq, chan, t.pitch, t.vel, true)

    util.assign(note, t)
    if note.muted == false then note.muted = nil end

    -- notation event encodes (chan, pitch) at ppq, so keep it in sync
    if (t.ppq or t.chan or t.pitch) and note.uuidIdx then
      reaper.MIDI_SetTextSysexEvt(take, note.uuidIdx, nil, nil, note.ppq, 15, noteSidecarEncode(note), true)
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
    reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, noteSidecarEncode(note))

    local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
    note.uuidIdx = sysexCount - 1
    note.idx = noteCount - 1
    util.add(notes, note)

    saveMetadatum(note.uuid)

    return #notes
  end

  ----- CCs

  function mm:getCC(loc)
    local msg = ccs[loc]
    return util.clone(msg, INTERNALS)
  end

  function mm:ccs()
    local i = 0
    return function()
      i = i + 1
      local msg = ccs[i]
      if msg then
        return i, util.clone(msg, INTERNALS)
      end
    end
  end

  function mm:deleteCC(loc)
    if not (take and checkLock()) then return end

    local msg = ccs[loc]
    if not msg then return end

    reaper.MIDI_DeleteCC(take, msg.idx)
    if msg.uuid then
      reaper.MIDI_DeleteTextSysexEvt(take, msg.uuidIdx)
      eventsByUuid[msg.uuid] = nil
      -- saveMetadata at end-of-modify purges the rdm_<uuid> ext-data slot
    end
    ccs[loc] = nil
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

    local msg = ccs[loc]
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
      reaper.MIDI_InsertTextSysexEvt(take, false, false, msg.ppq, -1, ccSidecarEncode(msg))
      local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
      msg.uuidIdx = sysexCount - 1
    end

    -- Resync sidecar ppq + fingerprint so the next load is tier-1 clean.
    if msg.uuid and hasStructural then
      reaper.MIDI_SetTextSysexEvt(take, msg.uuidIdx, nil, nil, msg.ppq, -1, ccSidecarEncode(msg), true)
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

    util.add(ccs, msg)

    return #ccs
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
