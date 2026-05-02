-- Pins vm:moveLaneEvent: row-typed write surface for cc/pb/at events
-- driven by the lane-strip drag in renderManager.
--
-- Invariants:
--   - integer toRow → ppq = rowToPPQ(toRow), ppqL = toRow * logPerRow
--   - identity-by-index survives the post-flush rebuild, because:
--       * tm sorts col.events by ppq each rebuild
--       * the move clamps newppq strictly inside (prev.ppq, next.ppq) by ±1
--   - fractional toRow (shift-drag) lands ppq off-grid; ppqL
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
      -- rpb=4, resolution=240 → logPerRow=60. Three CCs at rows 1, 4, 6.
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
      t.eq(events[2].ppqL, 180, 'ppqL = row * logPerRow')
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
      t.eq(evt.ppqL, 150, 'ppqL = 2.5 * logPerRow')
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

  -- Hidden fake pbs (absorbers seated by tm at lane-1 note seats) live
  -- in col.events but are invisible to the user. Drag identity must be
  -- the *visible* sequence: the lane strip hovers, anchors, and clamps
  -- speak in those terms, and a real pb must be free to cross a hidden
  -- fake pb. The clamp neighbours are the next visible pbs on either
  -- side; fake pbs in between don't restrict horizontal motion.
  {
    name = 'real pb drags past hidden fake pb at lane-1 note seat',
    run = function(harness)
      -- Seed empty; build the scenario via tm so reconcile seats the
      -- fake pb at the note onset. cents stays in tm units (raw conversion
      -- happens at flush).
      local h = harness.mk{
        config = { take = { rowPerBeat = 4 } },
      }
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:addEvent('pb', { ppq = 60,  chan = 1, val = 0 })
      h.tm:addEvent('pb', { ppq = 600, chan = 1, val = 0 })
      h.tm:flush()
      h.vm:setGridSize(80, 40)

      local function pbCol()
        for _, col in ipairs(h.vm.grid.cols) do
          if col.type == 'pb' and col.midiChan == 1 then return col end
        end
      end
      local function visible(col)
        local out = {}
        for _, e in ipairs(col.events) do
          if not e.hidden then out[#out + 1] = e end
        end
        return out
      end

      local col = pbCol()
      t.truthy(col, 'pb col present')
      -- Sanity: three events in storage (real@60, fake@240 hidden, real@600);
      -- two visible.
      t.eq(#col.events,    3, 'three pb events in storage')
      t.eq(#visible(col),  2, 'two visible (fake@240 hidden)')
      t.eq(visible(col)[1].ppq, 60)
      t.eq(visible(col)[2].ppq, 600)

      -- Drag the visible pb at row 1 to row 5 (ppq 300) — past the hidden
      -- fake@240. Expected: lands at 300; clamp uses next visible (@600).
      h.vm:moveLaneEvent(col, 1, 5, 0)

      col = pbCol()
      local vis = visible(col)
      t.eq(#vis,        2,   'still two visible after drag')
      t.eq(vis[1].ppq,  300, 'real pb landed at ppq=300, past hidden fake@240')
      t.eq(vis[2].ppq,  600, 'far visible neighbour untouched')
    end,
  },

  -- Dragging a real pb directly onto a hidden fake pb's seat is not a
  -- collision: the fake is the absorber for that note seat, and the
  -- right semantics is "real pb wins over fake" — the fake's raw value
  -- (which already absorbs the detune) is exactly what a real pb at that
  -- seat should carry to preserve the user's intended logical line.
  -- After the drag, one pb at the seat (real, not fake), real@source
  -- gone, no dedup-style loss.
  {
    name = 'real pb dropped exactly on hidden fake pb seat — fake gets promoted, no loss',
    run = function(harness)
      local h = harness.mk{
        config = { take = { rowPerBeat = 4 } },
      }
      h.tm:addEvent('note', {
        ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100,
        detune = 50, delay = 0, lane = 1,
      })
      h.tm:addEvent('pb', { ppq = 60,  chan = 1, val = 0 })
      h.tm:addEvent('pb', { ppq = 600, chan = 1, val = 0 })
      h.tm:flush()
      h.vm:setGridSize(80, 40)

      local function pbCol()
        for _, col in ipairs(h.vm.grid.cols) do
          if col.type == 'pb' and col.midiChan == 1 then return col end
        end
      end
      local function visible(col)
        local out = {}
        for _, e in ipairs(col.events) do
          if not e.hidden then out[#out + 1] = e end
        end
        return out
      end

      -- Drag visible[1] (real@60) exactly onto the fake's seat (row 4 = ppq 240).
      h.vm:moveLaneEvent(pbCol(), 1, 4, 0)

      -- After the drag: a single visible pb at ppq=240, plus the far one at 600.
      local col = pbCol()
      local vis = visible(col)
      t.eq(#vis,        2,   'two visible: pb at 240 (was fake, now real) + pb at 600')
      t.eq(vis[1].ppq,  240, 'visible pb is now at the former fake seat')
      t.eq(vis[2].ppq,  600, 'far neighbour untouched')

      -- And the source is gone — no orphaned pb at ppq=60.
      local atSource = 0
      for _, e in ipairs(col.events) do
        if e.ppq == 60 then atSource = atSource + 1 end
      end
      t.eq(atSource, 0, 'source pb at ppq=60 was removed, not orphaned')
    end,
  },

  -- vm:addLaneEvent — inserts a new cc/pb/at event at (ppq, val), inheriting
  -- envelope shape from the previous *visible* event (so the existing curve
  -- shape from prev→next is preserved across the new midpoint). Returns
  -- the new event's visible index after flush so the lane-strip can seed
  -- a drag on it.

  {
    name = 'addLaneEvent between two events inherits prev shape, returns idx 2',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60,  chan = 1, msgType = 'cc', cc = 1, val = 10 },
            { ppq = 360, chan = 1, msgType = 'cc', cc = 1, val = 30 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)
      -- Mark first event's outgoing shape as 'linear' so the curve from
      -- prev→next is non-trivial; the new midpoint should inherit that.
      h.tm:assignEvent('cc', h.vm.grid.cols[idx].events[1], { shape = 'linear' })
      h.tm:flush()

      local newIdx = h.vm:addLaneEvent(h.vm.grid.cols[idx], idx, 180, 20)
      t.eq(newIdx, 2, 'new event sits between the two existing ones')
      local events = h.vm.grid.cols[idx].events
      t.eq(events[2].ppq,   180,      'ppq stored')
      t.eq(events[2].val,   20,       'val stored')
      t.eq(events[2].shape, 'linear', 'inherited prev shape')
      t.eq(events[1].ppq,   60,       'prev untouched')
      t.eq(events[3].ppq,   360,      'next untouched')
    end,
  },

  {
    name = 'addLaneEvent before first event has no prev → idx 1, nil shape',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 240, chan = 1, msgType = 'cc', cc = 1, val = 50 },
          },
        },
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      local idx = findCcCol(h.vm, 1)

      local newIdx = h.vm:addLaneEvent(h.vm.grid.cols[idx], idx, 60, 10)
      t.eq(newIdx, 1, 'new event is the new first')
      local events = h.vm.grid.cols[idx].events
      t.eq(events[1].ppq,   60,  'new lands ahead of seed')
      t.eq(events[1].shape, nil, 'no prev → no shape inherited')
      t.eq(events[2].ppq,   240, 'former first shifts to idx 2')
    end,
  },

  {
    name = 'addLaneEvent on non-renderable col is a no-op',
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
      local result = h.vm:addLaneEvent(h.vm.grid.cols[1], 1, 120, 64)
      t.eq(result, nil, 'returns nil on note column')
    end,
  },

  -- vm:deleteLaneEvent — removes the i-th visible event in cc/pb/at.

  {
    name = 'deleteLaneEvent removes the named visible event',
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

      h.vm:deleteLaneEvent(h.vm.grid.cols[idx], 2)

      local events = h.vm.grid.cols[idx].events
      t.eq(#events, 2, 'one event deleted')
      t.eq(events[1].ppq, 60,  'first untouched')
      t.eq(events[2].ppq, 360, 'middle gone, third shifted to idx 2')
    end,
  },

  {
    name = 'deleteLaneEvent on non-renderable col is a no-op',
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
      h.vm:deleteLaneEvent(h.vm.grid.cols[1], 1)
      local n = h.fm:dump().notes[1]
      t.truthy(n, 'note still present')
      t.eq(n.ppq, 0, 'note ppq unchanged')
    end,
  },

  -- vm:cycleLaneShape — advances the segment-owner's shape through
  -- shapeCycle = step → linear → slow → fast-start → fast-end → bezier.

  {
    name = 'cycleLaneShape advances shape on the named visible event',
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

      h.vm:cycleLaneShape(h.vm.grid.cols[idx], 1)
      t.eq(h.vm.grid.cols[idx].events[1].shape, 'linear', 'nil/step → linear')

      h.vm:cycleLaneShape(h.vm.grid.cols[idx], 1)
      t.eq(h.vm.grid.cols[idx].events[1].shape, 'slow', 'linear → slow')
    end,
  },

  {
    name = 'cycleLaneShape on non-renderable col is a no-op',
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
      h.vm:cycleLaneShape(h.vm.grid.cols[1], 1)
      local n = h.fm:dump().notes[1]
      t.truthy(n, 'note still present')
    end,
  },

  -- vm:setLaneTension — writes tension and forces shape to bezier
  -- (REAPER ignores tension on other shapes).

  {
    name = 'setLaneTension writes tension and forces shape=bezier',
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
      -- Start the segment as linear; tension write should override.
      h.tm:assignEvent('cc', h.vm.grid.cols[idx].events[1], { shape = 'linear' })
      h.tm:flush()

      h.vm:setLaneTension(h.vm.grid.cols[idx], 1, 0.5)

      local evt = h.vm.grid.cols[idx].events[1]
      t.eq(evt.shape,   'bezier', 'shape forced to bezier')
      t.eq(evt.tension, 0.5,      'tension recorded')
    end,
  },

  {
    name = 'setLaneTension on non-renderable col is a no-op',
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
      h.vm:setLaneTension(h.vm.grid.cols[1], 1, 0.7)
      local n = h.fm:dump().notes[1]
      t.truthy(n, 'note still present')
    end,
  },
}
