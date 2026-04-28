-- Loads the real midiManager.lua under the harness, returning newMidiManager
-- without leaving the real factory sitting in `_G`. The harness has stuffed
-- `_G.newMidiManager` with a fake; specs that need the real one save/restore
-- around a require, but `require` is process-cached, so the second spec to do
-- this dance would silently get the fake back. Going through this helper
-- guarantees a fresh chunk execution every call.

return function()
  package.loaded['midiManager'] = nil
  local savedMM = _G.newMidiManager
  require('midiManager')
  local realMM = _G.newMidiManager
  _G.newMidiManager = savedMM
  return realMM
end
