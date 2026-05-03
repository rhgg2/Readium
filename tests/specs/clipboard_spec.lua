-- Stage-6 contract pins for the clipboard factory (newClipboard in
-- viewManager.lua, scheduled to lift to clipboard.lua at 6d). These pin
-- the wire format between collect and pasteClip — what shape collect
-- produces, what trimTop preserves, what chanDelta means in multi mode —
-- so the file move can't drift the contract silently.

local t = require('support')

return {

  -- 1. collect() over a 1×1 pitch-part sel returns a single-mode clip
  -- whose one event carries (row, pitch, vel, endRow) relative to the
  -- selection's top row. Pins the encoding so pasteClip's decoder
  -- (rowToPPQ on r + ce.row) stays compatible.
  {
    name = 'clipboard:collect on 1×1 pitch sel produces single-mode clip with row-relative event',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 240, endppq = 300, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
        }},
      }
      h.vm:setGridSize(80, 40)
      -- Cursor on row 4 (240 ppq @ 4 rpb / res 240), col 1, pitch stop.
      h.ec:setPos(4, 1, 1)
      h.ec:extendTo(h.ec:pos())  -- degenerate 1x1 sel at cursor

      local clip = h.clipboard:collect()
      t.eq(clip.mode,    'single', 'mode')
      t.eq(clip.type,    'note',   'type')
      t.eq(clip.numRows, 1,        'numRows = sel height')
      t.eq(#clip.events, 1,        'one event captured')
      local e = clip.events[1]
      t.eq(e.row,    0,   'row encoded relative to r1')
      t.eq(e.endRow, 1,   'endRow encoded relative to r1 (note ends row 5)')
      t.eq(e.pitch,  60,  'pitch carried')
      t.eq(e.vel,    100, 'vel carried')
      -- Reserved keys must not round-trip: position is rebuilt from row,
      -- identity from the destination column, REAPER bookkeeping mustn't
      -- ride. If any of these leak into the clip, paste will overwrite
      -- destination identity with stale source values.
      for _, k in ipairs{'ppq','endppq','ppqL','endppqL','chan','frame','lane','loc','idx','uuid','uuidIdx'} do
        t.eq(e[k], nil, k .. ' not carried in clip event')
      end
    end,
  },

  -- 2. trimTop is pure on the clip table: drops top `trim` rows,
  -- decrements numRows, re-indexes survivors. Notes whose start row
  -- falls in the trimmed band are dropped entirely; survivors keep
  -- their pitch/vel/endRow shifted.
  {
    name = 'clipboard:trimTop drops top rows and re-indexes survivors',
    run = function(harness)
      local h = harness.mk{}  -- no seed; we only need the clipboard ref
      local clip = {
        mode = 'single', type = 'note', numRows = 4, sourceIdx = 1,
        events = {
          { row = 0, endRow = 1, pitch = 60, vel = 100 },  -- dropped
          { row = 2, endRow = 3, pitch = 62, vel = 100 },  -- shifted
          { row = 3,             pitch = 64, vel = 100 },  -- shifted, no endRow
        },
      }
      h.clipboard:trimTop(clip, 2)

      t.eq(clip.numRows, 2,       'numRows decremented by trim')
      t.eq(#clip.events, 2,       'event with row<trim dropped')
      t.eq(clip.events[1].row,    0, 'first survivor row shifted by -trim')
      t.eq(clip.events[1].endRow, 1, 'first survivor endRow shifted by -trim')
      t.eq(clip.events[1].pitch,  62, 'pitch preserved')
      t.eq(clip.events[2].row,    1, 'second survivor row shifted')
      t.eq(clip.events[2].endRow, nil, 'no endRow stays nil')
    end,
  },

  -- 3. Multi-mode collect encodes chanDelta as the offset from the
  -- leftmost selected col's channel. pasteClip's resolve() decodes by
  -- adding chanDelta to the cursor's channel, so this is the wire that
  -- carries cross-channel paste semantics.
  {
    name = 'clipboard:collect multi-col records chanDelta from leftmost col',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 0, endppq = 60, chan = 2, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 0, endppq = 60, chan = 3, pitch = 64, vel = 100,
            detune = 0, delay = 0 },
        }},
      }
      h.vm:setGridSize(80, 40)
      -- Select cols 1..3 (each chan's first note col), pitch part.
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=3, part1='pitch', part2='pitch' }

      local clip = h.clipboard:collect()
      t.eq(clip.mode,       'multi', 'mode')
      t.eq(clip.startType,  'note',  'startType = leftmost col type')
      t.eq(#clip.cols,       3,      'three cols captured')
      t.eq(clip.cols[1].chanDelta, 0, 'leftmost col has chanDelta 0')
      t.eq(clip.cols[2].chanDelta, 1, 'second col is +1 chan from leftmost')
      t.eq(clip.cols[3].chanDelta, 2, 'third col is +2 chan from leftmost')
      t.eq(clip.cols[1].type,      'note', 'col type recorded')
      t.eq(clip.cols[1].key,       0,      'first note col within chan = key 0')
    end,
  },

  -- 4. The collect/paste pipeline must NOT use a field allowlist: any
  -- metadata on a source event — including fields added in the future —
  -- must survive a collect → paste round-trip. The clipboard-side strip
  -- rule is destination-identity + REAPER bookkeeping only; payload rides
  -- through. The same rule holds for the upstream tm projection layer
  -- (see tm_rebuild_spec's 'arbitrary metadata on cc/pb/pa survives the
  -- projection') so the round-trip is lossless end-to-end.
  {
    name = 'arbitrary metadata survives note pitch-mode collect→paste round-trip',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0, mood = 'blue', tag = 42 },
        }},
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }

      local clip = h.clipboard:collect()
      -- Custom fields land in the clip event verbatim.
      t.eq(clip.events[1].mood, 'blue', 'mood preserved in clip')
      t.eq(clip.events[1].tag,  42,     'tag preserved in clip')

      -- Paste at row 8 (ppq 480 @ rpb=4, res=240).
      h.ec:setPos(8, 1, 1)
      h.clipboard:pasteClip(clip)

      local pasted
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 480 then pasted = n; break end
      end
      t.eq(pasted ~= nil, true, 'paste landed at row 8')
      t.eq(pasted.mood,   'blue', 'mood survives the round-trip')
      t.eq(pasted.tag,    42,     'tag survives the round-trip')
      t.eq(pasted.pitch,  60,     'pitch survives the round-trip')
    end,
  },

  -- Companion to test 4 for the cc path. Pins lossless flow through both
  -- layers: tm projection (which used to strip unknown fields via per-
  -- msgType util.pick allowlists) AND clipboard collect/paste. Together
  -- with the tm_rebuild pin this is the structural guarantee that any
  -- metadata field added to a cc in future will round-trip without the
  -- author having to update either layer's strip rule.
  {
    name = 'arbitrary metadata survives cc-mode collect→paste round-trip',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 0, chan = 1, msgType = 'cc', cc = 74, val = 64,
            mood = 'blue', tag = 42 },
        }},
      }
      h.vm:setGridSize(80, 40)

      -- Locate the cc#74 col index in the rendered grid.
      local ccCol
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 74 and col.midiChan == 1 then
          ccCol = i; break
        end
      end
      t.truthy(ccCol, 'cc#74 column present in grid')

      h.ec:setSelection{ row1=0, row2=0, col1=ccCol, col2=ccCol,
                         part1='val', part2='val' }

      local clip = h.clipboard:collect()
      t.eq(clip.events[1].mood, 'blue', 'mood preserved in clip')
      t.eq(clip.events[1].tag,  42,     'tag preserved in clip')

      -- Paste at row 8 (ppq 480 @ rpb=4, res=240).
      h.ec:setPos(8, ccCol, 1)
      h.clipboard:pasteClip(clip)

      local pasted
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.ppq == 480 and c.cc == 74 then pasted = c; break end
      end
      t.eq(pasted ~= nil, true,   'paste landed at row 8 on cc#74')
      t.eq(pasted.mood,   'blue', 'mood survives the round-trip')
      t.eq(pasted.tag,    42,     'tag survives the round-trip')
      t.eq(pasted.val,    64,     'val survives the round-trip')
    end,
  },

}
