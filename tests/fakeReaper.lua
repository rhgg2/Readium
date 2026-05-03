-- In-memory stand-in for the REAPER API. Covers just the surface touched
-- by configManager, trackerManager, and viewManager; midiManager's MIDI
-- calls are bypassed by using the fake midiManager instead.

local M = {}

function M.new()
  local r = {}
  local state = {
    cursorTime   = 0,
    precise      = 0,
    tempoBPM     = 120,
    ppqPerQN     = 240,
    projExt      = {},
    trackExt     = {},
    takeExt      = {},
    globalExt    = {},
    itemForTake  = {},
    trackForItem = {},
    calls        = {},
    console      = {},
    messages     = {},
  }
  r._state = state

  -- Config storage

  function r.GetProjExtState(_proj, section, key)
    local v = state.projExt[section .. '/' .. key]
    if v then return 1, v end
    return 0, ''
  end

  function r.SetProjExtState(_proj, section, key, value)
    state.projExt[section .. '/' .. key] = value
  end

  function r.GetSetMediaTrackInfo_String(track, key, value, setNew)
    local k = tostring(track) .. '/' .. key
    if setNew then state.trackExt[k] = value; return true, value end
    return true, state.trackExt[k] or ''
  end

  function r.GetSetMediaItemTakeInfo_String(take, key, value, setNew)
    local k = tostring(take) .. '/' .. key
    if setNew then state.takeExt[k] = value; return true, value end
    return true, state.takeExt[k] or ''
  end

  function r.GetMediaItemTake_Item(take) return state.itemForTake[take] end
  function r.GetMediaItemTrack(item)     return state.trackForItem[item] end
  function r.GetMediaItemTake_Track(take)
    return state.trackForItem[state.itemForTake[take]]
  end

  -- Track FX list (used by probeTrackerMode in continuum.lua).
  state.fxByTrack = {}
  function r.TrackFX_GetCount(track)
    return #(state.fxByTrack[track] or {})
  end
  function r.TrackFX_GetFXName(track, idx)
    local names = state.fxByTrack[track] or {}
    return names[idx + 1] ~= nil, names[idx + 1] or ''
  end

  -- Transport / cursor

  function r.GetCursorPosition() return state.cursorTime end

  function r.SetEditCurPos(time)
    state.cursorTime = time
    state.calls[#state.calls + 1] = { fn = 'SetEditCurPos', time = time }
  end

  function r.MIDI_GetPPQPosFromProjTime(_take, time)
    return time * (state.tempoBPM / 60) * state.ppqPerQN
  end

  function r.MIDI_GetProjTimeFromPPQPos(_take, ppq)
    return ppq / state.ppqPerQN / (state.tempoBPM / 60)
  end

  function r.Main_OnCommand(cmd, flag)
    state.calls[#state.calls + 1] = { fn = 'Main_OnCommand', cmd = cmd, flag = flag }
  end

  -- Audition / UI

  function r.StuffMIDIMessage(mode, b1, b2, b3)
    state.calls[#state.calls + 1] = { fn = 'StuffMIDIMessage', mode = mode, b1 = b1, b2 = b2, b3 = b3 }
  end

  function r.time_precise() return state.precise end

  function r.ShowMessageBox(msg, title, btn)
    state.messages[#state.messages + 1] = { msg = msg, title = title, btn = btn }
    return 1
  end

  function r.SetExtState(section, key, value)
    state.globalExt[section .. '/' .. key] = value
  end

  function r.GetExtState(section, key)
    return state.globalExt[section .. '/' .. key] or ''
  end

  function r.ShowConsoleMsg(msg)
    state.console[#state.console + 1] = msg
    if os.getenv('CTM_TEST_VERBOSE') then io.write(msg) end
  end

  -- MIDI take store. Created lazily on first reference. Each list keeps
  -- entries 1-indexed internally; the REAPER API surface converts to 0-index
  -- on read/write/delete.
  --
  -- Insertion order is preserved between MIDI_DisableSort and MIDI_Sort; on
  -- Sort, notes/ccs/texts each restabilise by ppq using a stable sort. Text
  -- events fold sysex (eventtype = -1) and notation (eventtype = 15) into
  -- one stream — same as the real REAPER API surface.
  state.takeMidi = {}
  local function midi(take)
    local m = state.takeMidi[take]
    if not m then
      m = { notes = {}, ccs = {}, texts = {}, sortDisabled = false }
      state.takeMidi[take] = m
    end
    return m
  end

  local function stableSort(list)
    for i, e in ipairs(list) do e.__order = i end
    table.sort(list, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      return a.__order < b.__order
    end)
    for _, e in ipairs(list) do e.__order = nil end
  end

  function r.MIDI_CountEvts(take)
    local m = midi(take)
    return true, #m.notes, #m.ccs, #m.texts
  end

  function r.MIDI_GetNote(take, i)
    local n = midi(take).notes[i + 1]
    if not n then return false end
    return true, n.selected or false, n.muted or false, n.ppq, n.endppq, n.chan, n.pitch, n.vel
  end

  function r.MIDI_GetCC(take, i)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    return true, c.selected or false, c.muted or false, c.ppq, c.chanmsg, c.chan, c.msg2, c.msg3
  end

  function r.MIDI_GetCCShape(take, i)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    return true, c.shape or 0, c.tension or 0
  end

  function r.MIDI_GetTextSysexEvt(take, i)
    local e = midi(take).texts[i + 1]
    if not e then return false end
    return true, e.selected or false, e.muted or false, e.ppq, e.eventtype, e.msg
  end

  function r.MIDI_DisableSort(take) midi(take).sortDisabled = true end
  function r.MIDI_Sort(take)
    local m = midi(take)
    stableSort(m.notes)
    stableSort(m.ccs)
    stableSort(m.texts)
    m.sortDisabled = false
  end

  function r.MIDI_DeleteNote(take, i)
    table.remove(midi(take).notes, i + 1)
    return true
  end
  function r.MIDI_DeleteCC(take, i)
    table.remove(midi(take).ccs, i + 1)
    return true
  end
  function r.MIDI_DeleteTextSysexEvt(take, i)
    table.remove(midi(take).texts, i + 1)
    return true
  end

  function r.MIDI_InsertTextSysexEvt(take, _selected, muted, ppq, eventtype, msg)
    local m = midi(take)
    m.texts[#m.texts + 1] = { ppq = ppq, eventtype = eventtype, msg = msg, muted = muted }
    if not m.sortDisabled then stableSort(m.texts) end
    return true
  end

  function r.MIDI_SetTextSysexEvt(take, i, _selected, muted, ppq, eventtype, msg, _sortIn)
    local e = midi(take).texts[i + 1]
    if not e then return false end
    if muted     ~= nil then e.muted     = muted     end
    if ppq       ~= nil then e.ppq       = ppq       end
    if eventtype ~= nil then e.eventtype = eventtype end
    if msg       ~= nil then e.msg       = msg       end
    return true
  end

  function r.MIDI_InsertNote(take, _selected, muted, ppq, endppq, chan, pitch, vel, _sortIn)
    local m = midi(take)
    m.notes[#m.notes + 1] = { ppq = ppq, endppq = endppq, chan = chan,
                              pitch = pitch, vel = vel, muted = muted }
    if not m.sortDisabled then stableSort(m.notes) end
    return true
  end
  function r.MIDI_SetNote(take, i, _selected, muted, ppq, endppq, chan, pitch, vel, _sortIn)
    local n = midi(take).notes[i + 1]
    if not n then return false end
    if muted  ~= nil then n.muted  = muted  end
    if ppq    ~= nil then n.ppq    = ppq    end
    if endppq ~= nil then n.endppq = endppq end
    if chan   ~= nil then n.chan   = chan   end
    if pitch  ~= nil then n.pitch  = pitch  end
    if vel    ~= nil then n.vel    = vel    end
    return true
  end

  function r.MIDI_InsertCC(take, _selected, muted, ppq, chanmsg, chan, msg2, msg3)
    local m = midi(take)
    m.ccs[#m.ccs + 1] = { ppq = ppq, chanmsg = chanmsg, chan = chan,
                          msg2 = msg2, msg3 = msg3, muted = muted }
    if not m.sortDisabled then stableSort(m.ccs) end
    return true
  end
  function r.MIDI_SetCC(take, i, _selected, muted, ppq, chanmsg, chan, msg2, msg3, _sortIn)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    if muted   ~= nil then c.muted   = muted   end
    if ppq     ~= nil then c.ppq     = ppq     end
    if chanmsg ~= nil then c.chanmsg = chanmsg end
    if chan    ~= nil then c.chan    = chan    end
    if msg2    ~= nil then c.msg2    = msg2    end
    if msg3    ~= nil then c.msg3    = msg3    end
    return true
  end
  function r.MIDI_SetCCShape(take, i, shape, tension, _sortIn)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    c.shape = shape; c.tension = tension
    return true
  end

  -- Test helpers

  function r:setCursor(time)  state.cursorTime = time end
  function r:tick(dt)         state.precise = state.precise + dt end
  function r:setTempo(bpm)    state.tempoBPM = bpm end
  function r:bindTake(take, item, track)
    state.itemForTake[take]  = item
    state.trackForItem[item] = track
  end
  function r:setTrackFX(track, names)
    state.fxByTrack[track] = names
  end
  function r:clearCalls()   state.calls = {} end
  function r:clearConsole() state.console = {} end

  -- Bulk-seed a take's MIDI store. Mirrors the field shape REAPER returns.
  -- notes : { { ppq, endppq, chan, pitch, vel, [muted] }, ... }
  -- ccs   : { { ppq, chanmsg, chan, msg2, msg3, [muted], [shape], [tension] }, ... }
  -- texts : { { ppq, eventtype, msg, [muted] }, ... }
  function r:seedMidi(take, seed)
    local m = midi(take)
    m.notes = {}; m.ccs = {}; m.texts = {}
    for _, n in ipairs(seed.notes or {}) do m.notes[#m.notes+1] = { ppq = n.ppq, endppq = n.endppq,
        chan = n.chan, pitch = n.pitch, vel = n.vel, muted = n.muted } end
    for _, c in ipairs(seed.ccs or {})   do m.ccs[#m.ccs+1]     = { ppq = c.ppq, chanmsg = c.chanmsg,
        chan = c.chan, msg2 = c.msg2, msg3 = c.msg3, muted = c.muted, shape = c.shape, tension = c.tension } end
    for _, e in ipairs(seed.texts or {}) do m.texts[#m.texts+1] = { ppq = e.ppq, eventtype = e.eventtype,
        msg = e.msg, muted = e.muted } end
    stableSort(m.notes); stableSort(m.ccs); stableSort(m.texts)
  end

  function r:dumpMidi(take)
    local m = midi(take)
    return { notes = m.notes, ccs = m.ccs, texts = m.texts }
  end

  return r
end

return M
