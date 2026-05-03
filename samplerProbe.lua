-- See docs/samplerProbe.md for the model.
--
-- trackerMode is derived from the take's track FX list, not user
-- configuration. The probe runs at startup and once per defer tick;
-- writes to cm only on change so configChanged doesn't fire every tick.

local SAMPLER_FX = 'Continuum Sampler'

function probeTrackerMode(mm, cm)
  local track = reaper.GetMediaItemTake_Track(mm:take())
  local detected = false
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    if name:find(SAMPLER_FX, 1, true) then detected = true; break end
  end
  if cm:get('trackerMode') ~= detected then
    cm:set('transient', 'trackerMode', detected)
  end
end
