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
    -- Regression: under multi-atom / extreme composites, ε amplification
    -- through unapply pushed ppqToRow off the authored row, and fresh
    -- on-grid notes lit up the off-grid colour. vm:rebuild now invokes
    -- ctx:authoredRow which round-trips against the apply, so on-grid
    -- notes stay on their row regardless of slope.
    name = 'extreme swing: a fresh on-grid note lands on its authored row, no off-grid flag',
    run = function(harness)
      local extreme = {
        { atom = 'classic', shift = 0.3, period = 1 },
        { atom = 'shuffle', shift = 0.2, period = 1 },
      }
      -- Build the realised ppq for row 5 the way authoring does:
      -- rowPPQ = round(r * ppqPerRow) → round(apply(rowPPQ)).
      local factors = {}
      for i, f in ipairs(extreme) do
        local Tqn = timing.atomTilePeriod(f)
        factors[i] = { S = timing.atoms[f.atom](f.shift / Tqn), T = Tqn * 240 }
      end
      local rowPPQ   = util.round(5 * 60)   -- ppqPerRow=60 at default rpb=4
      local realised = util.round(timing.applyFactors(factors, rowPPQ))
      t.truthy(realised ~= rowPPQ,
        'sanity: extreme swing actually deflects row 5 (got ' .. realised .. ')')

      local h = harness.mk{
        seed = {
          notes = { { ppq = realised, endppq = realised + 60, chan = 1, pitch = 60, vel = 100 } },
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
}
