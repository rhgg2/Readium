-- Pins vm:moveLaneEvent: row-typed write surface for cc/pb/at events
-- driven by the lane-strip drag in renderManager.
--
-- Invariants:
--   - integer toRow → ppq = rowToPPQ(toRow), straightPPQ = toRow * sppr
--   - identity-by-index survives the post-flush rebuild, because:
--       * tm sorts col.events by ppq each rebuild
--       * the move clamps newPPQ strictly inside (prev.ppq, next.ppq) by ±1
--   - fractional toRow (shift-drag) lands ppq off-grid; straightPPQ
--     records the authored fractional row so reswing remembers it
--   - non cc/pb/at columns are silently ignored

local t = require('support')

local function findCcCol(vm, ccNum)
  for i, col in ipairs(vm.grid.cols) do
    if col.type == 'cc' and col.cc == ccNum then return i end
  end
end

return {

  {
    name = 'integer toRow lands ppq on rowToPPQ exactly; identity-by-index preserved',
    run = function(harness)
      -- rpb=4, resolution=240 → sppr=60. Three CCs at rows 1, 4, 6.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 20 },
            { ppq = 360, chan = 1, msgType = 'cc', cc = 1, val = 30 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)
      t.truthy(idx, 'cc=1 col found')

      h.vm:moveLaneEvent(h.vm.grid.cols[idx], 2, 3, 20)

      local events = h.vm.grid.cols[idx].events
      t.eq(events[2].ppq,         180, 'ppq = rowToPPQ(3)')
      t.eq(events[2].val,         20,  'val carried through (event identity preserved)')
      t.eq(events[2].straightPPQ, 180, 'straightPPQ = row * sppr')
      t.eq(events[1].ppq,         60,  'prev untouched')
      t.eq(events[3].ppq,         360, 'next untouched')
    end,
  },

  {
    name = 'toRow past previous event clamps to prev.ppq + 1',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 20 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)

      -- Try to drag event 2 back to row 0 — past event 1 at row 1.
      h.vm:moveLaneEvent(h.vm.grid.cols[idx], 2, 0, 20)
      t.eq(h.vm.grid.cols[idx].events[2].ppq, 61, 'clamped to prev.ppq + 1')
      t.eq(h.vm.grid.cols[idx].events[1].ppq, 60, 'prev still at 60')
    end,
  },

  {
    name = 'toRow past next event clamps to next.ppq - 1',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 20 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)

      -- Drag event 1 forward past event 2.
      h.vm:moveLaneEvent(h.vm.grid.cols[idx], 1, 10, 10)
      t.eq(h.vm.grid.cols[idx].events[1].ppq, 239, 'clamped to next.ppq - 1')
      t.eq(h.vm.grid.cols[idx].events[2].ppq, 240, 'next still at 240')
    end,
  },

  {
    name = 'fractional toRow (shift-drag) lands ppq off-grid',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 20 },
            { ppq = 360, chan = 1, msgType = 'cc', cc = 1, val = 30 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)

      -- 2.5 * 60 = 150; sits between rows, within (prev=60, next=360).
      h.vm:moveLaneEvent(h.vm.grid.cols[idx], 2, 2.5, 20)
      local evt = h.vm.grid.cols[idx].events[2]
      t.eq(evt.ppq,         150, 'ppq = rowToPPQ(2.5)')
      t.eq(evt.straightPPQ, 150, 'straightPPQ = 2.5 * sppr')
    end,
  },

  {
    name = 'non-cc/pb/at column is a no-op',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Col 1 is the note column. moveLaneEvent must ignore it.
      h.vm:moveLaneEvent(h.vm.grid.cols[1], 1, 5, 50)
      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    0,   'note ppq unchanged')
      t.eq(n.endppq, 240, 'note endppq unchanged')
    end,
  },

  {
    name = 'val updates without ppq change when toRow matches current row',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 20 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)

      h.vm:moveLaneEvent(h.vm.grid.cols[idx], 1, 1, 99)
      local evt = h.vm.grid.cols[idx].events[1]
      t.eq(evt.ppq, 60, 'ppq unchanged at row 1')
      t.eq(evt.val, 99, 'val updated')
    end,
  },
}
