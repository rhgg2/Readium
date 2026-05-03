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
        calls[#calls+1] = { slot, path }; return true
      end)
      t.eq(sv:loadSelectedIntoCurrent(), false, "returns false")
      t.eq(#calls, 0, "assignSlot not invoked")
    end,
  },
  {
    name = "loadSelectedIntoCurrent passes (currentSample, selectedFile) to assignSlot",
    run = function(harness)
      local h = harness.mk()
      local calls = {}
      local sv = newSampleView(h.cm, function(slot, path)
        calls[#calls+1] = { slot, path }; return true
      end)
      h.cm:set('transient', 'currentSample', 5)
      sv:setSelectedFile('/x.wav')
      t.eq(sv:loadSelectedIntoCurrent(), true, "returns true")
      t.eq(#calls, 1, "assignSlot called once")
      t.eq(calls[1][1], 5, "slot is currentSample")
      t.eq(calls[1][2], '/x.wav', "path is selectedFile")
    end,
  },
  {
    name = "loadSelectedIntoCurrent surfaces assignSlot failure",
    run = function(harness)
      local h = harness.mk()
      local sv = newSampleView(h.cm, function() return false end)
      sv:setSelectedFile('/x.wav')
      t.eq(sv:loadSelectedIntoCurrent(), false, "false propagates from assignSlot")
    end,
  },
  {
    name = "auditionPath(nil) is a no-op",
    run = function(harness)
      local h = harness.mk()
      local calls = {}
      local sv = newSampleView(h.cm, function() end,
        function() calls[#calls+1] = 'slot' end,
        function() calls[#calls+1] = 'path' end)
      t.eq(sv:auditionPath(nil), false, "returns false")
      t.eq(#calls, 0, "previewPath not invoked")
    end,
  },
  {
    name = "auditionPath(p) calls previewPath with that path",
    run = function(harness)
      local h = harness.mk()
      local pathCalls = {}
      local sv = newSampleView(h.cm, function() end, function() end,
        function(p) pathCalls[#pathCalls+1] = p end)
      t.eq(sv:auditionPath('/kick.wav'), true, "returns true")
      t.eq(#pathCalls, 1, "previewPath called once")
      t.eq(pathCalls[1], '/kick.wav', "path forwarded")
    end,
  },
  {
    name = "setTrack with cm injected rekeys cm and clears transient currentSample",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('transient', 'currentSample', 5)
      local sv = newSampleView(h.cm, function() end, function() end, function() end)
      local trackB = 'trackB'
      h.reaper._state.trackExt[trackB .. '/P_EXT:ctm_config'] =
        util.serialise({ pbRange = 9 })
      sv:setTrack(trackB)
      t.eq(sv:getTrack(), trackB, 'sv stored the new track')
      t.eq(h.cm:getAt('transient', 'currentSample'), nil,
           'transient currentSample cleared')
      t.eq(h.cm:getAt('track', 'pbRange'), 9,
           'cm now reads track-tier from new track')
    end,
  },
  {
    name = "setTrack with cm and same track is a no-op (no transient clear)",
    run = function(harness)
      local h = harness.mk()
      local sv = newSampleView(h.cm, function() end, function() end, function() end)
      sv:setTrack('trackA')
      h.cm:set('transient', 'currentSample', 7)
      sv:setTrack('trackA')
      t.eq(h.cm:getAt('transient', 'currentSample'), 7,
           'no-op setTrack leaves transient alone')
    end,
  },
  {
    name = "listTracks proxies the injected listSamplerTracks",
    run = function(harness)
      local h     = harness.mk()
      local stub  = { { track = 't1', name = 'Drums' },
                      { track = 't2', name = 'Synth' } }
      local calls = 0
      local sv = newSampleView(h.cm, function() end, function() end, function() end,
        function() calls = calls + 1; return stub end)
      local got = sv:listTracks()
      t.eq(calls,  1,         'injection invoked once')
      t.eq(#got,   2,         'two tracks returned')
      t.eq(got[1].name, 'Drums', 'first entry passes through')
    end,
  },
  {
    name = "auditionSlot(idx) calls previewSlot(idx, 1)",
    run = function(harness)
      local h = harness.mk()
      local slotCalls = {}
      local sv = newSampleView(h.cm, function() end,
        function(slot, bounds) slotCalls[#slotCalls+1] = { slot, bounds } end,
        function() end)
      sv:auditionSlot(7)
      t.eq(#slotCalls, 1, "previewSlot called once")
      t.eq(slotCalls[1][1], 7, "slot forwarded")
      t.eq(slotCalls[1][2], 1, "bounds=1 (honour SH_START/SH_END)")
    end,
  },
}
