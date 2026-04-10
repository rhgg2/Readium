function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

local function print(...)
  return util:print(...)
end

loadModule('util')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('viewManager')

---

local function err_handler(err)
  reaper.ShowConsoleMsg("\nERROR:\n" .. tostring(err) .. "\n\n")
  reaper.ShowConsoleMsg(debug.traceback() .. "\n")
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

---

function Main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowConsoleMsg("Please select a MIDI item.\n")
    return
  end

  local take = reaper.GetActiveTake(item)
  local mm = newMidiManager(take)
  local cm = newConfigManager()
  cm:setContext(take)
  local tm = newTrackerManager(mm, cm)

  local tracker = newViewManager(tm, cm)
  tracker:init()

  local function loop()
    if tracker:loop() then
      reaper.defer(loop)
    end
  end
  loop()
end

run(Main)
