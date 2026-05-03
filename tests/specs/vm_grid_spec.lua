-- Exercises vm's grid construction against seeded tm state.

local t = require('support')

return {
  {
    name = 'one note on channel 1 surfaces as one note col with that event',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local notesOnChan1 = {}
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type == 'note' and col.midiChan == 1 then
          notesOnChan1[#notesOnChan1 + 1] = col
        end
      end
      t.eq(#notesOnChan1, 1, 'exactly one note col for chan 1')
      t.eq(notesOnChan1[1].lane, 1, 'the note col is lane 1')
      t.eq(#notesOnChan1[1].events, 1, 'the seeded event lives in it')
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
    -- rowBeatInfo(row) → (isBarBoundary, isBeatBoundary). Under default
    -- 4/4 with rpb=4: row 0 is both, row 4 is a beat boundary only, row 1
    -- is neither, row 16 is the next bar boundary.
    name = 'rowBeatInfo flags bar and beat boundaries under 4/4',
    run = function(harness)
      local h = harness.mk()
      local function info(row) return { h.vm:rowBeatInfo(row) } end
      t.deepEq(info(0),  { true,  true  }, 'row 0 is bar+beat')
      t.deepEq(info(1),  { false, false }, 'row 1 is interior')
      t.deepEq(info(4),  { false, true  }, 'row 4 is beat-only')
      t.deepEq(info(16), { true,  true  }, 'row 16 is the next bar')
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
    -- Regression: vm:addExtraCol must not erase the implicit lane-1 note
    -- column when extras[chan] was previously absent. tm:rebuild treats
    -- absence as `{ notes = 1 }`; addExtraCol's seed has to match.
    name = 'addExtraCol on a channel with no notes preserves the implicit note column',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ec:selectChannel(1)

      local function chan1Cols()
        local notes, ccs = 0, 0
        for _, col in ipairs(h.vm.grid.cols) do
          if col.midiChan == 1 then
            if col.type == 'note' then notes = notes + 1
            elseif col.type == 'cc' then ccs = ccs + 1 end
          end
        end
        return notes, ccs
      end

      local n0, c0 = chan1Cols()
      t.eq(n0, 1, 'chan 1 starts with one implicit note col')
      t.eq(c0, 0, 'chan 1 starts with no cc cols')

      h.vm:addExtraCol('cc', 1)

      local n1, c1 = chan1Cols()
      t.eq(n1, 1, 'note col survives cc add (was 0 before fix — implicit col erased)')
      t.eq(c1, 1, 'cc col added')
    end,
  },

  {
    -- Empty-take grid shape: one implicit lane-1 note col per channel and
    -- nothing else. lane1Col is populated for all 16 chans.
    name = 'empty take: 16 implicit lane-1 note cols, lane1Col covers all chans',
    run = function(harness)
      local h = harness.mk()
      t.eq(#h.vm.grid.cols, 16, 'one col per channel, no extras')
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
      t.deepEq(col.stopPos, { 0, 2, 4, 5 })
      t.deepEq(col.partAt,  { 'pitch', 'pitch', 'vel', 'vel' })
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
      t.deepEq(col.stopPos, { 0, 2, 4, 5, 7, 8, 9 })
      t.deepEq(col.partAt,  { 'pitch', 'pitch', 'vel', 'vel', 'delay', 'delay', 'delay' })
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
    -- off-grid — their realised ppq sits at the logical-grid position,
    -- which under the new swing no longer lands on rowToPPQ_c(N).
    name = 'swing change: notes authored under swing-off are off-grid under a non-trivial swing',
    run = function(harness)
      -- Seed each note as the user would have authored it with swing off:
      -- frame.swing = nil, ppqL pins the row. Under c58 the realised
      -- ppq remains at the unswung position, no longer on the swung grid.
      local c58 = { { atom = 'classic', shift = 0.08, period = 1 } }
      local nilFrame = { swing = nil, colSwing = nil, rpb = 4 }
      local h = harness.mk{
        seed = {
          notes = {
            -- ppqPerRow = 60 at rpb=4. Rows 0, 1, 2, 4 placed with no swing.
            { ppq = 0,   endppq = 60,  ppqL = 0,   endppqL = 60,
              chan = 1, pitch = 60, vel = 100, frame = nilFrame },
            { ppq = 60,  endppq = 120, ppqL = 60,  endppqL = 120,
              chan = 1, pitch = 62, vel = 100, frame = nilFrame },
            { ppq = 120, endppq = 180, ppqL = 120, endppqL = 180,
              chan = 1, pitch = 64, vel = 100, frame = nilFrame },
            { ppq = 240, endppq = 300, ppqL = 240, endppqL = 300,
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
    -- land on-grid. Regression guard for addPb dropping ppqL/frame.
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
    -- Underlying mechanism for bug 2: fresh PBs must retain ppqL
    -- and frame through addPb, otherwise reswing has nothing to invert.
    name = 'fresh PB carries ppqL + frame after authoring',
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
      t.eq(fresh.ppqL, 120,   'ppqL pins authoring row 2 (60·2)')
    end,
  },
}
