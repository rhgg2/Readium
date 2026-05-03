-- Pins commit 2c: trackerMode is derived from the take's track FX list,
-- not user configuration. probeTrackerMode walks reaper.TrackFX_*; on
-- change it writes 'transient' tier so the existing configChanged
-- pipeline drives a rebuild. Repeat calls with the same FX list are
-- idempotent (no spurious configChanged storm).

local t = require('support')

return {

  {
    name = 'no Continuum Sampler FX: trackerMode stays false',
    run = function(harness)
      local h = harness.mk{}
      h.reaper:setTrackFX('take1/track', { 'JS: ReaEQ', 'VST: Some Synth' })
      probeTrackerMode(h.fm, h.cm)
      t.eq(h.cm:get('trackerMode'), false)
    end,
  },

  {
    name = 'Continuum Sampler in FX list: trackerMode set true',
    run = function(harness)
      local h = harness.mk{}
      h.reaper:setTrackFX('take1/track', { 'JS: Continuum Sampler' })
      probeTrackerMode(h.fm, h.cm)
      t.eq(h.cm:get('trackerMode'), true)
    end,
  },

  {
    name = 'matches when sampler is anywhere in the chain',
    run = function(harness)
      local h = harness.mk{}
      h.reaper:setTrackFX('take1/track',
        { 'JS: ReaEQ', 'JS: Continuum Sampler', 'VST: Reverb' })
      probeTrackerMode(h.fm, h.cm)
      t.eq(h.cm:get('trackerMode'), true)
    end,
  },

  {
    name = 'removing the sampler flips trackerMode back to false',
    run = function(harness)
      local h = harness.mk{}
      h.reaper:setTrackFX('take1/track', { 'JS: Continuum Sampler' })
      probeTrackerMode(h.fm, h.cm)
      t.eq(h.cm:get('trackerMode'), true)
      h.reaper:setTrackFX('take1/track', { 'JS: ReaEQ' })
      probeTrackerMode(h.fm, h.cm)
      t.eq(h.cm:get('trackerMode'), false)
    end,
  },

  {
    name = 'idempotent: repeat probe with no change does not re-fire configChanged',
    run = function(harness)
      local h = harness.mk{}
      h.reaper:setTrackFX('take1/track', { 'JS: Continuum Sampler' })
      probeTrackerMode(h.fm, h.cm)
      local fires = 0
      h.cm:subscribe('configChanged', function() fires = fires + 1 end)
      probeTrackerMode(h.fm, h.cm)
      probeTrackerMode(h.fm, h.cm)
      t.eq(fires, 0, 'no configChanged emitted when state unchanged')
    end,
  },
}
