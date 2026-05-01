-- Pins F3's "endppq is intent at every layer" at the addEvent seam.
--
-- Note on the bug class: same-(chan, pitch) overlap reconciliation in
-- `clearSameKeyRange` lives in REALISED space — MIDI gives one voice
-- per (chan, pitch), so a realised collision MUST truncate or shorten
-- regardless of intent geometry. vm-side `delayRange` is the gate
-- that prevents legitimate edits from creating those collisions.
-- That's a firm rule, not a bug.
--
-- F3 #3, however, was a separate stale shift in `um:addEvent`: pre-fix,
-- a non-zero `delay` on the payload shifted both ppq AND endppq by
-- delayToPPQ(delay). Shifting endppq is wrong — endppq is intent and
-- delay is a realisation-level shift on the note-on only. Today no
-- caller passes delay≠0 to addEvent, so the bug is unreachable; this
-- pin makes that the contract.

local t = require('support')

return {

  -- F3 #3: tm:addEvent must not shift endppq by delay.
  {
    name = 'F3 #3: tm:addEvent with delay≠0 leaves endppq at caller value',
    run = function(harness)
      local h = harness.mk()

      -- delayToPPQ(500, 240) = round(240 * 500 / 1000) = 120.
      h.tm:addEvent('note', {
        ppq = 100, endppq = 200, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 500, lane = 1,
      })
      h.tm:flush()

      local n = h.fm:dump().notes[1]
      t.truthy(n, 'note added')
      t.eq(n.delay,  500, 'delay survives')
      t.eq(n.ppq,    220, 'realised onset = caller ppq + delayToPPQ(delay)')
      t.eq(n.endppq, 200, 'endppq unchanged — F3 (was 320 pre-fix)')
    end,
  },
}
