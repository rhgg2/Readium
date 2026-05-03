-- Pin-tests for the sampleView module. Since draw() pulls in ImGui,
-- which isn't available in the pure-Lua harness, the smoke-tests stay
-- at the state-management level (setTrack/getTrack); rendering is
-- verified manually in REAPER.

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
}
