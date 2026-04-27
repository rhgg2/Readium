-- Loads the real midiManager.lua under the harness, returning
-- { newMidiManager, newSidecarReconciler } without leaving the real
-- factories sitting in `_G`. The harness has stuffed `_G.newMidiManager`
-- with a fake; specs that need the real one save/restore around a
-- require, but `require` is process-cached, so the second spec to do
-- this dance would silently get the fake back. Going through this
-- helper guarantees a fresh chunk execution every call.

return function()
  package.loaded['midiManager'] = nil
  local savedMM = _G.newMidiManager
  require('midiManager')
  local realMM, realSR = _G.newMidiManager, _G.newSidecarReconciler
  -- newMidiManager is restored so harness-using specs keep seeing the
  -- fake. newSidecarReconciler stays in _G — the harness never installed
  -- a fake, and other sidecar_* specs reach for it as a global.
  _G.newMidiManager = savedMM
  return realMM, realSR
end
