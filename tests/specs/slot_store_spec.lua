-- Pin tests for slotStore. cm is real; fileOps + loadSlot are call-recording
-- stubs so we can verify the side-effects without disk I/O.

local t = require('support')
require('fs')
require('slotStore')

local function mkOps()
  local ops = {
    copies = {}, moves = {}, mkdirs = {},
    copyResult = true,  -- flip to false to simulate failure
    moveResult = true,
  }
  ops.copy  = function(src, dst) ops.copies[#ops.copies+1] = { src, dst }; return ops.copyResult end
  ops.move  = function(src, dst) ops.moves [#ops.moves +1] = { src, dst }; return ops.moveResult end
  ops.mkdir = function(dir)      ops.mkdirs[#ops.mkdirs+1] = dir          end
  return ops
end

local function mkLoad()
  local rec = { calls = {} }
  rec.fn = function(idx, abs) rec.calls[#rec.calls+1] = { idx, abs } end
  return rec
end

return {
  {
    name = 'slotEntries default is an empty table per call',
    run = function(harness)
      local h = harness.mk()
      local a = h.cm:get('slotEntries')
      a[0] = { path = 'leak' }
      local b = h.cm:get('slotEntries')
      t.eq(b[0], nil, 'mutation of returned table does not pollute cm')
    end,
  },
  {
    name = 'slotEntries round-trips through track ext-state',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', { [3] = { path = 'Continuum/k.wav' } })
      local cm2 = newConfigManager()
      cm2:setContext('take1')
      t.eq(cm2:get('slotEntries')[3].path, 'Continuum/k.wav', 'rehydrated from track P_EXT')
    end,
  },
  {
    name = 'assign copies, writes cm, fires loadSlot',
    run = function(harness)
      local h = harness.mk()
      local ops, load = mkOps(), mkLoad()
      local store = newSlotStore(h.cm, ops, load.fn)

      local ok = store:assign(5, '/disk/kick.wav', '/proj')
      t.truthy(ok, 'returns true on success')

      t.eq(#ops.mkdirs, 1, 'one mkdir')
      t.eq(ops.mkdirs[1], '/proj/Continuum', 'mkdir targets Continuum subdir')

      t.eq(#ops.copies, 1, 'one copy')
      t.eq(ops.copies[1][1], '/disk/kick.wav', 'copy src is the source path')
      t.truthy(ops.copies[1][2]:match('^/proj/Continuum/kick%-%x+%.wav$'),
        'copy dst is /proj/Continuum/kick-<rand>.wav, got ' .. ops.copies[1][2])

      local entry = h.cm:get('slotEntries')[5]
      t.truthy(entry, 'cm has slot 5')
      t.truthy(entry.path:match('^Continuum/kick%-%x+%.wav$'),
        'cm path is project-relative, got ' .. tostring(entry.path))

      t.eq(#load.calls, 1, 'loadSlot fired once')
      t.eq(load.calls[1][1], 5, 'loadSlot got the right slot')
      t.eq(load.calls[1][2], entry.path,
        'loadSlot got the rel path (JSFX composes abs from prefix)')
    end,
  },
  {
    name = 'assign returns false on copy failure, leaves cm and loadSlot untouched',
    run = function(harness)
      local h = harness.mk()
      local ops, load = mkOps(), mkLoad()
      ops.copyResult = false
      local store = newSlotStore(h.cm, ops, load.fn)

      t.eq(store:assign(2, '/disk/missing.wav', '/proj'), false, 'returns false')
      t.eq(h.cm:get('slotEntries')[2], nil, 'no cm entry written')
      t.eq(#load.calls, 0, 'no loadSlot call')
    end,
  },
  {
    name = 'assign preserves other slot fields when overwriting path',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries',
        { [4] = { path = 'Continuum/old.wav', shStart = 100 } })
      local ops, load = mkOps(), mkLoad()
      local store = newSlotStore(h.cm, ops, load.fn)

      store:assign(4, '/disk/new.wav', '/proj')
      local entry = h.cm:get('slotEntries')[4]
      t.eq(entry.shStart, 100, 'shStart survived re-assign')
      t.truthy(entry.path:match('^Continuum/new%-'), 'path was overwritten')
    end,
  },
  {
    name = 'sweep replays every entry through loadSlot',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', {
        [0] = { path = 'Continuum/a.wav' },
        [3] = { path = 'Continuum/b.wav' },
      })
      local ops, load = mkOps(), mkLoad()
      local store = newSlotStore(h.cm, ops, load.fn)

      store:sweep()
      t.eq(#load.calls, 2, 'one loadSlot per entry')
      local seen = {}
      for _, c in ipairs(load.calls) do seen[c[1]] = c[2] end
      t.eq(seen[0], 'Continuum/a.wav', 'slot 0 forwarded as rel')
      t.eq(seen[3], 'Continuum/b.wav', 'slot 3 forwarded as rel')
    end,
  },
  {
    name = 'sweep skips entries with no path',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', { [1] = { shStart = 50 } })
      local ops, load = mkOps(), mkLoad()
      newSlotStore(h.cm, ops, load.fn):sweep()
      t.eq(#load.calls, 0, 'pathless entry not loaded')
    end,
  },
  {
    name = 'migrate moves bytes when project path changes',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', {
        [0] = { path = 'Continuum/k.wav' },
        [1] = { path = 'Continuum/s.wav' },
      })
      local ops, load = mkOps(), mkLoad()
      local store = newSlotStore(h.cm, ops, load.fn)

      local moved = store:migrate('/new', '/old')
      t.eq(moved, true, 'migrate reports work was done')
      t.eq(#ops.moves, 2, 'one move per entry')
      local seen = {}
      for _, m in ipairs(ops.moves) do seen[m[1]] = m[2] end
      t.eq(seen['/old/Continuum/k.wav'], '/new/Continuum/k.wav', 'slot 0 moved')
      t.eq(seen['/old/Continuum/s.wav'], '/new/Continuum/s.wav', 'slot 1 moved')

      local entries = h.cm:get('slotEntries')
      t.eq(entries[0].path, 'Continuum/k.wav', 'cm path unchanged (still relative)')
    end,
  },
  {
    name = 'migrate is a no-op when paths match or oldPath is nil',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', { [0] = { path = 'Continuum/k.wav' } })
      local ops, load = mkOps(), mkLoad()
      local store = newSlotStore(h.cm, ops, load.fn)

      t.eq(store:migrate('/proj', nil), false, 'nil oldPath = no-op')
      t.eq(store:migrate('/proj', '/proj'), false, 'same path = no-op')
      t.eq(#ops.moves, 0, 'no moves issued')
    end,
  },
}
