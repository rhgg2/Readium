local function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('takeManager')

---

local function print(...)
  return util:print(...)
end

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
  local item = reaper.GetSelectedMediaItem(0,0)
  local tm = newTakeManager(reaper.GetActiveTake(item))

  tm:modify( function ()
      tm:addNote({ppq=0, endppq=12288, pitch=60, vel=127, chan=1})
      tm:addNote({ppq=12288, endppq=30000, pitch=61, vel=127, chan=1, extra=10})
  end)
  
  tm:modify( function ()
    tm:assignNote(0, { ppq = 10000 })
  end )
end

run(Main)


