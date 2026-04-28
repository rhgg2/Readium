-- Exercises vm's grid construction against seeded tm state.

local t = require('support')

return {
  {
    name = 'empty take produces an empty grid',
    run = function(harness)
      local h = harness.mk()
      t.eq(h.cm:get('rowPerBeat'), 4,  'default rowPerBeat')
      t.eq(h.vm:rowPerBar(),       16, 'default rowPerBar (4/4)')
      t.truthy(h.tm:resolution(),       'resolution set')
    end,
  },

  {
    name = 'one note on channel 1 creates one grid column',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      -- grid is private; reach in via chanFirstCol/chanLastCol by selecting col 1.
      h.vm:setGridSize(80, 40)
      h.ec:selectColumn(1)
      t.eq(h.ec:col(), 1, 'cursor lands on first column')
    end,
  },

  {
    name = 'notes on two channels expose both via channel selection',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0, endppq = 240, chan = 3, pitch = 64, vel = 100 },
          },
        },
      }
      h.vm:setGridSize(80, 40)

      h.ec:selectChannel(1)
      local col1 = h.ec:col()
      h.ec:selectChannel(3)
      local col3 = h.ec:col()
      t.truthy(col3 > col1, 'channel 3 column lies after channel 1 column')
    end,
  },

  {
    name = 'rowBeatInfo reports bar/beat for row 0 under 4/4',
    run = function(harness)
      local h = harness.mk()
      local info = h.vm:rowBeatInfo(0)
      t.truthy(info, 'rowBeatInfo returns a table')
    end,
  },

  -- Column-shape invariants: cc cols sort ascending by cc number, and
  -- within a channel the kinds appear pc → pb → notes (lane order) → at → cc.
  {
    name = 'cc columns appear sorted by cc number',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0, chan = 1, msgType = 'cc', cc = 74, val = 0 },
            { ppq = 0, chan = 1, msgType = 'cc', cc = 1,  val = 0 },
            { ppq = 0, chan = 1, msgType = 'cc', cc = 11, val = 0 },
          },
        },
      }
      local ccs = {}
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' then ccs[#ccs+1] = col.cc end
      end
      t.deepEq(ccs, { 1, 11, 74 }, 'cc cols ascending by cc number')
    end,
  },

  {
    name = 'kinds within a channel: pc → pb → note → at → cc',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
          ccs = {
            { ppq = 0, chan = 1, msgType = 'cc', cc = 1, val = 0 },
            { ppq = 0, chan = 1, msgType = 'at', val = 64 },
            { ppq = 0, chan = 1, msgType = 'pc', val = 5 },
            { ppq = 0, chan = 1, msgType = 'pb', val = 0 },
          },
        },
      }
      local types = {}
      for _, col in ipairs(h.vm.grid.cols) do
        if col.midiChan == 1 then types[#types+1] = col.type end
      end
      t.deepEq(types, { 'pc', 'pb', 'note', 'at', 'cc' }, 'canonical order')
    end,
  },

  -- col.lane: note cols carry their 1-indexed lane; non-note cols nil.
  {
    name = 'note grid columns carry their lane number',
    run = function(harness)
      -- Two notes at the same start ppq always spill to a new lane.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100 },
          },
        },
      }
      local lanes = {}
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type == 'note' and col.midiChan == 1 then lanes[#lanes+1] = col.lane end
      end
      t.deepEq(lanes, { 1, 2 }, 'note cols dense lane indices')
    end,
  },

  {
    name = 'non-note columns have nil lane',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0, chan = 1, msgType = 'pb', val = 0 },
            { ppq = 0, chan = 1, msgType = 'cc', cc = 1, val = 0 },
            { ppq = 0, chan = 1, msgType = 'at', val = 64 },
            { ppq = 0, chan = 1, msgType = 'pc', val = 5 },
          },
        },
      }
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type ~= 'note' then
          t.eq(col.lane, nil, 'non-note col ' .. col.type .. ' has nil lane')
        end
      end
    end,
  },

  -- grid.lane1Col: the per-channel lane-1 note column index.
  {
    name = 'grid.lane1Col indexes the lane-1 note column for each channel',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0, endppq = 240, chan = 3, pitch = 64, vel = 100 },
          },
        },
      }
      local c1 = h.vm.grid.lane1Col[1]
      local c3 = h.vm.grid.lane1Col[3]
      t.truthy(c1, 'chan 1 has a lane-1 col')
      t.truthy(c3, 'chan 3 has a lane-1 col')
      t.eq(c1.type, 'note'); t.eq(c1.lane, 1); t.eq(c1.midiChan, 1)
      t.eq(c3.type, 'note'); t.eq(c3.lane, 1); t.eq(c3.midiChan, 3)
    end,
  },

  {
    name = 'grid.lane1Col has an entry per channel even on an empty take',
    run = function(harness)
      local h = harness.mk()
      for chan = 1, 16 do
        local c = h.vm.grid.lane1Col[chan]
        t.truthy(c, 'chan ' .. chan .. ' has a lane-1 col')
        t.eq(c.type, 'note'); t.eq(c.lane, 1); t.eq(c.midiChan, chan)
      end
    end,
  },

  -- Note col stop/selgroup shape depends on noteDelay config.
  {
    name = 'note col without delay has the compact stop layout',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local col = h.vm.grid.cols[1]
      t.eq(col.type, 'note')
      t.falsy(col.showDelay, 'showDelay off by default')
      t.deepEq(col.stopPos,   { 0, 2, 4, 5 })
      t.deepEq(col.selGroups, { 1, 1, 2, 2 })
      t.eq(col.width, 6)
    end,
  },

  {
    name = 'note col with delay extends stops and widens',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
        config = { take = { noteDelay = { [1] = { [1] = true } } } },
      }
      local col = h.vm.grid.cols[1]
      t.eq(col.type, 'note')
      t.truthy(col.showDelay, 'showDelay flag derived from cfg.noteDelay')
      t.deepEq(col.stopPos,   { 0, 2, 4, 5, 7, 8, 9 })
      t.deepEq(col.selGroups, { 1, 1, 2, 2, 3, 3, 3 })
      t.eq(col.width, 10)
    end,
  },

  {
    -- Spec (design/archive/swing.md): displayRow(e) = round(ppqToRow_c(e.ppq))
    -- under current swing; on-grid iff rowToPPQ_c reproduces e.ppq exactly.
    -- With float rowPPQs the round-trip is bit-exact even for extreme
    -- multi-atom composites, so a note authored under the active swing
    -- lands on its row with no off-grid flag.
    name = 'extreme swing: a note authored under the current swing lands on its row, no off-grid flag',
    run = function(harness)
      local extreme = {
        { atom = 'classic', shift = 0.3, period = 1 },
        { atom = 'shuffle', shift = 0.2, period = 1 },
      }
      local factors = {}
      for i, f in ipairs(extreme) do
        local Tqn = timing.atomTilePeriod(f)
        factors[i] = { S = timing.atoms[f.atom](f.shift / Tqn), T = Tqn * 240 }
      end
      local rowPPQ   = 5 * 60   -- ppqPerRow=60 at rpb=4
      local realised = util.round(timing.applyFactors(factors, rowPPQ))
      t.truthy(realised ~= rowPPQ,
        'sanity: extreme swing actually deflects row 5 (got ' .. realised .. ')')

      local h = harness.mk{
        seed = {
          notes = {
            { ppq = realised, endppq = realised + 60,
              chan = 1, pitch = 60, vel = 100 },
          },
        },
        config = {
          project = { swings = { ['x'] = extreme } },
          take    = { swing = 'x' },
        },
      }
      local col = h.vm.grid.cols[1]
      t.truthy(col.cells[5],     'note placed on row 5')
      t.eq(col.offGrid[5], nil,  'note not flagged off-grid')
    end,
  },

  {
    -- Bug 1: notes added with swing off then swing-on must surface as
    -- off-grid — their realised ppq sits at the straight-grid position,
    -- which under the new swing no longer lands on rowToPPQ_c(N).
    name = 'swing change: notes authored under swing-off are off-grid under a non-trivial swing',
    run = function(harness)
      -- Seed each note as the user would have authored it with swing off:
      -- frame.swing = nil, straightPPQ pins the row. Under c58 the realised
      -- ppq remains at the unswung position, no longer on the swung grid.
      local c58 = { { atom = 'classic', shift = 0.08, period = 1 } }
      local nilFrame = { swing = nil, colSwing = nil, rpb = 4 }
      local h = harness.mk{
        seed = {
          notes = {
            -- ppqPerRow = 60 at rpb=4. Rows 0, 1, 2, 4 placed with no swing.
            { ppq = 0,   endppq = 60,  straightPPQ = 0,   straightEndPPQ = 60,
              chan = 1, pitch = 60, vel = 100, frame = nilFrame },
            { ppq = 60,  endppq = 120, straightPPQ = 60,  straightEndPPQ = 120,
              chan = 1, pitch = 62, vel = 100, frame = nilFrame },
            { ppq = 120, endppq = 180, straightPPQ = 120, straightEndPPQ = 180,
              chan = 1, pitch = 64, vel = 100, frame = nilFrame },
            { ppq = 240, endppq = 300, straightPPQ = 240, straightEndPPQ = 300,
              chan = 1, pitch = 67, vel = 100, frame = nilFrame },
          },
        },
        config = {
          project = { swings = { c58 = c58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      local col = h.vm.grid.cols[1]
      -- Period boundaries (rows 0, 4) are fixed points of c58 → on-grid.
      t.truthy(col.cells[0], 'row 0 cell present')
      t.eq(col.offGrid[0], nil, 'row 0 (period boundary) on-grid')
      t.truthy(col.cells[4], 'row 4 cell present')
      t.eq(col.offGrid[4], nil, 'row 4 (period boundary) on-grid')
      -- Off-fixed-point rows: realised ppq doesn't sit on the new grid.
      t.truthy(col.cells[1], 'row 1 cell present')
      t.truthy(col.offGrid[1], 'row 1 flagged off-grid under c58')
      t.truthy(col.cells[2], 'row 2 cell present')
      t.truthy(col.offGrid[2], 'row 2 flagged off-grid under c58')
    end,
  },

  {
    -- Bug 2: a fresh PB authored at a row under non-trivial swing must
    -- land on-grid. Regression guard for addPb dropping straightPPQ/frame.
    name = 'fresh PB authored under swing lands on-grid (no off-grid flag, regardless of period position)',
    run = function(harness)
      local c58 = { { atom = 'classic', shift = 0.08, period = 1 } }
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = 0 } },
        },
        config = {
          project = { swings = { c58 = c58 } },
          take    = { swing = 'c58', rowPerBeat = 4, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      local pbColIdx
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'pb' and c.midiChan == 1 then pbColIdx = i end
      end
      t.truthy(pbColIdx, 'pb column present')

      -- Author a non-zero pb at row 2 (off the period boundary under c58).
      h.ec:setPos(2, pbColIdx, 1)
      h.vm:editEvent(h.vm.grid.cols[pbColIdx], nil, 1, string.byte('5'), false)

      local pbCol = h.vm.grid.cols[pbColIdx]
      t.truthy(pbCol.cells[2],     'fresh pb landed on row 2')
      t.eq(pbCol.offGrid[2], nil,  'fresh pb not flagged off-grid')
    end,
  },

  {
    -- Underlying mechanism for bug 2: fresh PBs must retain straightPPQ
    -- and frame through addPb, otherwise reswing has nothing to invert.
    name = 'fresh PB carries straightPPQ + frame after authoring',
    run = function(harness)
      local c58 = { { atom = 'classic', shift = 0.08, period = 1 } }
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, msgType = 'pb', val = 0 } },
        },
        config = {
          project = { swings = { c58 = c58 } },
          take    = { swing = 'c58', rowPerBeat = 4, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      local pbColIdx
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'pb' and c.midiChan == 1 then pbColIdx = i end
      end
      h.ec:setPos(2, pbColIdx, 1)
      h.vm:editEvent(h.vm.grid.cols[pbColIdx], nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'pb' and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh,                'fresh pb landed in mm dump')
      t.truthy(fresh.frame,          'fresh pb carries frame')
      t.eq(fresh.frame.swing, 'c58', 'frame.swing matches cm')
      t.eq(fresh.frame.rpb,   4,     'frame.rpb matches cm')
      t.eq(fresh.straightPPQ, 120,   'straightPPQ pins authoring row 2 (60·2)')
    end,
  },
}
