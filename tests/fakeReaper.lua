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
    if os.getenv('RDM_TEST_VERBOSE') then io.write(msg) end
  end

  -- Test helpers

  function r:setCursor(time)  state.cursorTime = time end
  function r:tick(dt)         state.precise = state.precise + dt end
  function r:setTempo(bpm)    state.tempoBPM = bpm end
  function r:bindTake(take, item, track)
    state.itemForTake[take]  = item
    state.trackForItem[item] = track
  end
  function r:clearCalls()   state.calls = {} end
  function r:clearConsole() state.console = {} end

  return r
end

return M
