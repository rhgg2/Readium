-- Stage-6 contract pins for the clipboard factory (newClipboard in
-- viewManager.lua, scheduled to lift to clipboard.lua at 6d). These pin
-- the wire format between collect and pasteClip — what shape collect
-- produces, what trimTop preserves, what chanDelta means in multi mode —
-- so the file move can't drift the contract silently.

local t = require('support')

return {

  -- 1. collect() over a 1×1 pitch-kind sel returns a single-mode clip
  -- whose one event carries (row, pitch, vel, endRow, loc) relative to
  -- the selection's top row. Pins the encoding so pasteClip's decoder
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
      t.eq(clip.sourceIdx, 1,      'sourceIdx = source col')
      t.eq(#clip.events, 1,        'one event captured')
      local e = clip.events[1]
      t.eq(e.row,    0,   'row encoded relative to r1')
      t.eq(e.endRow, 1,   'endRow encoded relative to r1 (note ends row 5)')
      t.eq(e.pitch,  60,  'pitch carried')
      t.eq(e.vel,    100, 'vel carried')
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
      -- Select cols 1..3 (each chan's first note col), pitch kind.
      h.ec:setSelection{ row1=0, row2=0, col1=1, col2=3, kind1='pitch', kind2='pitch' }

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

}
