-- See docs/readium.md for the model and API reference.

function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('commandManager')
loadModule('viewManager')
loadModule('renderManager')

local function print(...)
  return util:print(...)
end

local function err_handler(err)
  reaper.ShowConsoleMsg('\nERROR:\n' .. tostring(err) .. '\n\n')
  reaper.ShowConsoleMsg(debug.traceback() .. '\n')
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

function Main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowConsoleMsg('Please select a MIDI item.\n')
    return
  end

  local take = reaper.GetActiveTake(item)
  local mm = newMidiManager(take)
  local cm = newConfigManager()
  cm:setContext(take)
  local tm = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)

  local vm = newViewManager(tm, cm, cmgr)
  local renderer = newRenderManager(vm, cm, cmgr)
  renderer:init()

  local function loop()
    if renderer:loop() then
      reaper.defer(loop)
    end
  end
  loop()
end

run(Main)
