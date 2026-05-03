-- Pins the ppqL invariant across vm's authoring + editing paths.
--
-- Storage model: every event stamped under a frame carries ppqL
-- (and endppqL for notes), the canonical authoring-grid position
-- pre-swing, pre-delay. Mutation rules:
--   - snap-to-row             writes ppqL = row * sppr_currentFrame
--   - shift-by-row             ppqL += rowDelta * sppr_currentFrame
--   - delay nudge              ppqL unchanged, frame unchanged
--   - reswing                  ppqL unchanged, realised re-applied

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }

local function noteByPitch(dump, pitch)
  for _, n in ipairs(dump.notes) do if n.pitch == pitch then return n end end
end

local function ccByCC(dump, cc)
  for _, c in ipairs(dump.ccs) do if c.cc == cc then return c end end
end

return {

  ---------- AUTHORING

  {
    name = 'fresh note at cursor row r writes ppqL = r·logPerRow in current frame',
    run = function(harness)
      local h = harness.mk{ config = { take = { rowPerBeat = 4, currentOctave = 4 } } }
      h.vm:setGridSize(80, 40)

      -- C-4 at row 2, col 1, no swing → logical = realised = 120.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.truthy(n, 'note authored')
      t.eq(n.ppq,         120, 'realised ppq at row 2')
      t.eq(n.ppqL, 120, 'logical ppq pins authoring row')
      t.eq(n.frame.rpb,   4,   'frame.rpb stamped from take')
    end,
  },

  {
    name = 'fresh note under c58 stamps ppqL at the logical row, ppq at the swung position',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      -- Row 2 = mid-period under c58: logical=120, realised≈139.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL, 120,   'logical pins row 2 (60 * 2)')
      t.truthy(math.abs(n.ppq - 139) <= 1,
        'realised lands at swung position, got ' .. n.ppq)
      t.eq(n.frame.swing, 'c58', 'frame.swing stamped from take')
    end,
  },

  {
    name = 'fresh cc at cursor row writes ppqL at row * logPerRow',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'cc', cc = 11, val = 0 } },
        },
        config = { take = { rowPerBeat = 8 } },
      }
      h.vm:setGridSize(80, 40)

      -- Find the cc=11 column.
      local ccColIdx
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 11 then ccColIdx = i end
      end
      h.ec:setPos(3, ccColIdx, 1)  -- row 3 in rpb=8 → logPerRow=30, logical=90
      h.vm:editEvent(h.vm.grid.cols[ccColIdx], nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.cc == 11 and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh, 'cc authored')
      t.eq(fresh.ppq,         90, 'realised ppq at row 3')
      t.eq(fresh.ppqL, 90, 'ppqL pins row 3 (30 * 3)')
    end,
  },

  ---------- DELAY NUDGE

  {
    name = 'delay nudge shifts realised onset but leaves end + ppqL intact',
    run = function(harness)
      -- Note covers intent ppq 120..360 (duration 240). Delay 500
      -- milli-QN = 120 ppq fits below the duration-1 collapse bound.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              ppqL = 120, endppqL = 360,
              frame = { swing = nil, colSwing = nil, rpb = 4 } },
          },
        },
        config = { take = { rowPerBeat = 4, noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      -- Edit delay on the existing note. Note delay is decimal, stops 5..7.
      -- Set first nibble of delay magnitude to 5 → +500 ms-QN = 120 ppq.
      local cells = h.vm.grid.cols[1].cells
      local note  = cells[2]
      h.vm:editEvent(h.vm.grid.cols[1], note, 5, string.byte('5'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL, 120,    'ppqL untouched by delay nudge')
      t.eq(n.endppqL, 360, 'endppqL untouched by delay nudge')
      t.eq(n.delay, 500,          'delay applied (milli-QN, first digit slot)')
      t.eq(n.ppq,    240,         'realised onset shifted by delay')
      t.eq(n.endppq, 360,         'endppq stays put — delay shifts only the note-on')
    end,
  },

  ---------- PASTE TRUNCATE

  -- F1 / Class A: when paste truncates a note that overhangs into the
  -- paste region, both endppq and endppqL must be rewritten. Writing
  -- only endppq leaves the tail off the logical grid even when frames
  -- match.
  {
    name = 'pasteSingle truncating an overhanging note rewrites endppq AND endppqL',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Long note rows 0..8 (ppq 0..480) at rpb=4. Will be truncated.
          { ppq = 0,   endppq = 480, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          -- Source note at row 10 — copied and pasted into the long note's tail.
          { ppq = 600, endppq = 660, chan = 1, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(10, 1, 1)             -- on the source note
      h.cmgr.commands.copy()
      h.ec:setPos(4, 1, 1)              -- inside long note's tail
      h.cmgr.commands.paste()

      local long = noteByPitch(h.fm:dump(), 60)
      t.truthy(long, 'long note survived')
      t.eq(long.endppq,  240, 'truncated endppq lands at paste row')
      t.eq(long.endppqL, 240, 'truncated endppqL written alongside endppq')
    end,
  },

  -- F1 / Class A: same fix for multi-col paste's truncate-last branch.
  {
    name = 'pasteMulti truncating an overhanging note rewrites endppq AND endppqL',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Two long notes on chans 1 & 2, both will be truncated.
          { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 0, endppq = 480, chan = 2, pitch = 64, vel = 100,
            detune = 0, delay = 0 },
          -- Two source notes on chans 1 & 2 to drive multi-col paste.
          { ppq = 600, endppq = 660, chan = 1, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 600, endppq = 660, chan = 2, pitch = 65, vel = 100,
            detune = 0, delay = 0 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      -- Multi-col copy: row 10, cols 1..2 pitch part.
      h.ec:setSelection{ row1=10, row2=10, col1=1, col2=2,
                          part1='pitch', part2='pitch' }
      h.cmgr.commands.copy()
      h.ec:setPos(4, 1, 1)
      h.cmgr.commands.paste()

      local long1 = noteByPitch(h.fm:dump(), 60)
      local long2 = noteByPitch(h.fm:dump(), 64)
      t.eq(long1.endppq,  240, 'chan-1 truncated endppq')
      t.eq(long1.endppqL, 240, 'chan-1 truncated endppqL written')
      t.eq(long2.endppq,  240, 'chan-2 truncated endppq')
      t.eq(long2.endppqL, 240, 'chan-2 truncated endppqL written')
    end,
  },

  ---------- CROSS-RPB COHERENCE  (F1 / Class B)
  --
  -- Whenever a note's tail (or head) is rewritten, frame must travel
  -- with it: writing endppqL alone in current frame's units while
  -- frame still says rpb_old leaves (ppqL/endppqL, frame) incoherent.
  -- Each pin below seeds a note whose `frame.rpb` differs from the
  -- take's current `rowPerBeat` and exercises one editing mechanic.

  -- Tail-stamp path (covers applyNoteOff, adjustDurationCore,
  -- queueDeleteNotes survivor, placeNewNote truncate-last, paste
  -- truncate-last — all flow through assignTail now).
  {
    name = 'noteOff under cross-rpb restamps frame and lands endppqL on current grid',
    run = function(harness)
      -- Note authored at rpb=8 (logPerRow=30, row 8 → ppqL=240).
      -- Take is now at rpb=4 (logPerRow=60). Cursor on row 2 (ppq=120).
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            frame = { swing = nil, colSwing = nil, rpb = 8 } },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)
      h.cmgr.commands.noteOff()

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppq,    120, 'tail clipped to cursor ppq')
      t.eq(n.endppqL,   120, 'endppqL = row 2 * logPerRow_new (60)')
      t.eq(n.frame.rpb, 4,   'frame restamped to current')
    end,
  },

  -- Spanning row-shift path (insertRow / deleteRow): different from
  -- assignTail's row-map derivation: uses dLogical math + swing.
  {
    name = 'insertRow into a cross-rpb note rewrites tail with frame restamped',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Note spans rows 0..4 in current frame (rpb=4): ppq 0..240.
          -- Frame.rpb=8 (cross-rpb).
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            frame = { swing = nil, colSwing = nil, rpb = 8 } },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)        -- inside the note's tail
      h.cmgr.commands.insertRow()  -- pushes the spanning tail down by 1 row

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppq,    300, 'spanning tail extended by 1 row (60 ppq)')
      t.eq(n.endppqL,   300, 'endppqL coherent with new frame')
      t.eq(n.frame.rpb, 4,   'spanning note frame restamped')
    end,
  },

  -- quantizeKeepRealised path: head gets at(newRow), but endppqL is
  -- separate — it must be re-derived under the new (current) frame
  -- so it stays coherent with the rebased head's frame. To make the
  -- fix observable in a no-swing setup (where the rebase formula
  -- happens to be identity for well-formed seeds), seed with a
  -- deliberately stale endppqL — the kind of value left behind by
  -- a prior frame change that didn't sweep tails.
  {
    name = 'quantizeKeepRealised re-derives endppqL under current frame',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Realised ppq=70 is off-grid (between rows 1 and 2); quantize
          -- triggers and snaps the head. endppqL=999 is deliberately
          -- stale — fix should rewrite it to ctx:ppqToRow(240) * 60 = 240.
          { ppq = 70, endppq = 240, chan = 1, pitch = 60, vel = 100,
            delay = 0, detune = 0,
            ppqL = 60, endppqL = 999,
            frame = { swing = nil, colSwing = nil, rpb = 4 } },
        }},
        config = { take = { rowPerBeat = 4,
                            noteDelay  = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)
      h.vm:quantizeKeepRealisedAll()

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppq,  240, 'endppq (intent) untouched')
      t.eq(n.endppqL, 240, 'stale endppqL rewritten under current frame')
    end,
  },

  -- reswingCore restamp path: when frame is restamped to current,
  -- ppqL/endppqL must be rebased by the logPerRow ratio so the note
  -- keeps the same authoring row in the new rpb's units.
  {
    name = 'reswing restamp under cross-rpb rebases ppqL/endppqL by logPerRow ratio',
    run = function(harness)
      -- Note at rpb=8 with ppqL=60 (row 2 in rpb=8: 2*30). Same time
      -- position in rpb=4 is row 1 (1*60=60). Same absolute logical-ppq
      -- value, but the rebase formula multiplies by logPerRow ratio
      -- (60/30=2): newPpqL = 60 * 2 = 120. Wait — that's wrong direction.
      -- Re-derive: row in old frame = ppqL/logPerRow_old = 60/30 = 2.
      -- New ppqL = oldRow * logPerRow_new = 2 * 60 = 120.
      -- So after reswing-all (which restamps), ppqL should be 120 (row 2
      -- in current rpb=4 → ppq=120). The authoring row identity is
      -- preserved as row index, not as time position.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 60, endppq = 120, chan = 1, pitch = 60, vel = 100,
            ppqL = 60, endppqL = 120,
            frame = { swing = nil, colSwing = nil, rpb = 8 } },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL,      120, 'ppqL = oldRow(2) * logPerRow_new(60)')
      t.eq(n.endppqL,   240, 'endppqL = oldEndRow(4) * logPerRow_new(60)')
      t.eq(n.frame.rpb, 4,   'frame restamped to current')
    end,
  },

  ---------- PA FRAME  (F1 / Class C)
  --
  -- A PA's frame is hybrid: swing/colSwing follow the host note (so
  -- a reswing of the host carries the PA along — without that link
  -- a reswing would orphan it), but rpb takes the current take's
  -- value (so the PA's ppqL, written in current row units, stays
  -- coherent with the rpb its frame names).

  {
    name = 'PA emitted on a sustain row inherits host swing but takes current rpb',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Host: c58 swing, rpb=8 (cross-rpb vs. take); covers rows 0..4.
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            delay = 0, detune = 0,
            frame = { swing = 'c58', colSwing = nil, rpb = 8 } },
        }},
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = nil, rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Cursor on row 2 (mid-sustain), col 1, vel stop (kind='vel', stop=3).
      h.ec:setPos(2, 1, 3)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 3, string.byte('5'), false)

      local pa
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pa' then pa = c end
      end
      t.truthy(pa, 'PA emitted on sustain-row vel edit')
      t.eq(pa.frame.swing, 'c58', 'PA inherits host swing')
      t.eq(pa.frame.rpb,   4,     'PA takes rpb from current take')
    end,
  },

  ---------- RESWING ROUND-TRIP

  {
    name = 'reswing under same swing is a no-op on ppqL',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, ppqL = 120,
              chan = 1, msgType = 'cc', cc = 1, val = 64,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local c = ccByCC(h.fm:dump(), 1)
      t.eq(c.ppqL, 120, 'ppqL unchanged across same-swing reswing')
      -- realised re-applied; under same swing it's the same realised value
      -- (modulo rounding).
      t.truthy(math.abs(c.ppq - 139) <= 1, 'realised within ε of original')
    end,
  },
}
