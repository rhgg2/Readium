-- See docs/sampleView.md for the model and API reference.
--
-- Take-independent view for sample mode: the slot list, browser, and
-- wave editor all key against a REAPER track, not a take. continuum.lua's
-- loop pushes the selected track in via setTrack each tick.

function newSampleView()
  local sv = {}
  local track = nil

  function sv:setTrack(t) track = t end
  function sv:getTrack() return track end

  function sv:draw(ctx)
    -- Lazy-required so the module loads cleanly in the pure-Lua test
    -- harness (where ImGui is unavailable). require is cached, so the
    -- per-frame cost is a table lookup.
    local ImGui = require 'imgui' '0.10'
    if track then
      local _, name = reaper.GetTrackName(track)
      ImGui.Text(ctx, 'Sample mode — track: ' .. (name ~= '' and name or '(unnamed)'))
    else
      ImGui.Text(ctx, 'Sample mode — no track selected')
    end
  end

  return sv
end
