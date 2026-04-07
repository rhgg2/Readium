function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

local function print(...)
  return util:print(...)
end

loadModule('util')
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
  local tm = newTrackerManager(mm)
  util:print_r(tm:state())

  local tracker = newViewManager()
  tracker:init()
  tracker:setSource(mm, tm)

  local function loop()
    if tracker:loop() then
      reaper.defer(loop)
    end
  end
  loop()
end

run(Main)
