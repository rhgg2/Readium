-- Pin-tests for the sampleView module. Since draw() pulls in ImGui,
-- which isn't available in the pure-Lua harness, the smoke-tests stay
-- at the state-management level (track, selectedFile, load wiring);
-- rendering is verified manually in REAPER.

local t = require('support')
require('sampleView')

return {
  {
    name = "newSampleView starts with no track",
    run = function(harness)
      local sv = newSampleView()
      t.eq(sv:getTrack(), nil, "no track until setTrack")
    end,
  },
  {
    name = "setTrack stores the track",
    run = function(harness)
      local sv = newSampleView()
      sv:setTrack('track1')
      t.eq(sv:getTrack(), 'track1', "getTrack returns what setTrack stored")
    end,
  },
  {
    name = "setTrack(nil) clears the track",
    run = function(harness)
      local sv = newSampleView()
      sv:setTrack('track1')
      sv:setTrack(nil)
      t.eq(sv:getTrack(), nil, "nil clears the stored track")
    end,
  },
  {
    name = "selectedFile starts nil; setSelectedFile stores; setSelectedFile(nil) clears",
    run = function(harness)
      local sv = newSampleView()
      t.eq(sv:getSelectedFile(), nil, "no file until setSelectedFile")
      sv:setSelectedFile('/tmp/kick.wav')
      t.eq(sv:getSelectedFile(), '/tmp/kick.wav', "stored")
      sv:setSelectedFile(nil)
      t.eq(sv:getSelectedFile(), nil, "nil clears it")
    end,
  },
  {
    name = "loadSelectedIntoCurrent is a no-op when no file is selected",
    run = function(harness)
      local h = harness.mk()
      local calls = {}
      local sv = newSampleView(h.cm, function(slot, path)
        calls[#calls+1] = { slot, path }
      end)
      t.eq(sv:loadSelectedIntoCurrent(), false, "returns false")
      t.eq(#calls, 0, "loadSlot not invoked")
    end,
  },
  {
    name = "loadSelectedIntoCurrent passes (currentSample, selectedFile) to loadSlot",
    run = function(harness)
      local h = harness.mk()
      local calls = {}
      local sv = newSampleView(h.cm, function(slot, path)
        calls[#calls+1] = { slot, path }
      end)
      h.cm:set('transient', 'currentSample', 5)
      sv:setSelectedFile('/x.wav')
      t.eq(sv:loadSelectedIntoCurrent(), true, "returns true")
      t.eq(#calls, 1, "loadSlot called once")
      t.eq(calls[1][1], 5, "slot is currentSample")
      t.eq(calls[1][2], '/x.wav', "path is selectedFile")
    end,
  },
}
