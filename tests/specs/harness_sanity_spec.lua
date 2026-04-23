-- Meta-tests that validate the harness itself. Each case targets a
-- specific wire; disabling or weakening that wire in the fakes should
-- cause the matching case to fail loudly rather than pass silently.

local t = require('support')

return {
  {
    -- If fake mm's lock were a no-op (assertLock didn't error), this passes
    -- silently and a production bug that forgot modify() would go unseen.
    name = 'writing to mm outside modify() errors',
    run = function(harness)
      local h = harness.mk()
      local ok, err = pcall(function()
        h.fm:addNote{ ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 }
      end)
      t.falsy(ok, 'addNote without modify should fail')
      t.truthy(tostring(err):find('modify'), 'error should mention modify(), got: ' .. tostring(err))
    end,
  },

  {
    -- If fire() were a no-op, tm would never rebuild after mutations and
    -- every structural test in the suite would still pass by coincidence
    -- (the seed-time fire would populate tm once and nothing else would).
    name = 'mm fires callbacks after modify() — tm rebuilds',
    run = function(harness)
      local h = harness.mk()
      t.eq(#h.tm:getChannel(1).columns.notes, 0, 'no note columns initially')

      h.fm:modify(function()
        h.fm:addNote{ ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 }
      end)

      -- tm only sees this if the mm callback fired AND tm is attached.
      t.eq(#h.tm:getChannel(1).columns.notes, 1, 'note column appeared via callback chain')
    end,
  },

  {
    -- If fake mm returned internal references instead of clones, mutating
    -- a returned note would silently corrupt state and half the invariants
    -- we test would be meaningless.
    name = 'getNote returns a shallow clone — mutation does not leak',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local n1 = h.fm:getNote(1)
      n1.pitch = 999
      n1.detune = 12345
      local n2 = h.fm:getNote(1)
      t.eq(n2.pitch, 60, 'pitch untouched by caller mutation')
      t.truthy(n2.detune ~= 12345, 'detune untouched by caller mutation')
    end,
  },

  {
    -- If reindex() were a no-op, insertion order would leak through and
    -- tm would see notes in an order that depends on how tests happened
    -- to seed them — false positives everywhere.
    name = 'notes are observed in ppq order regardless of seed order',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0,   endppq = 240, chan = 1, pitch = 64, vel = 100 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
          },
        },
      }
      local ppqs = {}
      for _, n in h.fm:notes() do ppqs[#ppqs + 1] = n.ppq end
      t.deepEq(ppqs, { 0, 240, 480 }, 'iteration yields ppq-ordered notes')
    end,
  },

  {
    -- If harness.mk leaked state between scenarios (shared mm, shared cm,
    -- shared reaper), a test that expected a fresh take would see stale
    -- data from an earlier test and pass for the wrong reason.
    name = 'scenarios are isolated — fresh mk gives a clean mm',
    run = function(harness)
      local a = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      t.eq(#a.fm:dump().notes, 1, 'scenario A seeded')

      local b = harness.mk()
      t.eq(#b.fm:dump().notes, 0, 'scenario B starts empty')
      t.eq(#b.tm:getChannel(1).columns.notes, 0, 'tm in B has no columns')
    end,
  },

  {
    -- If the fake reaper ext-state stubs were broken, cm would read and
    -- write to /dev/null and config-driven tests would pass by accident.
    name = 'cm write → read round-trips through fake reaper ext-state',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'rowPerBeat', 7)
      t.eq(h.cm:get('rowPerBeat'), 7, 'cm:get returns what was set')

      -- And the fake reaper really stored it somewhere we can inspect.
      local stored = false
      for k, v in pairs(h.reaper._state.takeExt) do
        if v:find('rowPerBeat') and v:find('7') then stored = true end
      end
      t.truthy(stored, 'reaper takeExt holds the serialised config')
    end,
  },

  {
    -- If mm:resolution() returned a hardcoded default matching our usual
    -- 240 ppq/QN, seed-time overrides would be ignored and every ppq
    -- arithmetic test would pass by coincidence.
    name = 'mm resolution and length reflect the seed',
    run = function(harness)
      local h = harness.mk{
        seed = { resolution = 480, length = 9600 },
      }
      t.eq(h.fm:resolution(), 480, 'fake mm honours seed resolution')
      t.eq(h.tm:resolution(), 480, 'tm pulls resolution from mm')
      t.eq(h.fm:length(),     9600, 'fake mm honours seed length')
      t.eq(h.tm:length(),     9600, 'tm pulls length from mm')
    end,
  },

  {
    -- If tm:play weren't really calling reaper.Main_OnCommand, it would
    -- look like it worked. Inspect the call log to prove the wire exists.
    name = 'tm:play routes to reaper.Main_OnCommand',
    run = function(harness)
      local h = harness.mk()
      h.reaper:clearCalls()
      h.tm:play()
      local calls = h.reaper._state.calls
      t.eq(#calls, 1, 'one call recorded')
      t.eq(calls[1].fn, 'Main_OnCommand')
      t.eq(calls[1].cmd, 1007, 'REAPER transport: play')
    end,
  },

  {
    -- If vm weren't attached to tm (or tm weren't attached to mm), seeding
    -- mm wouldn't propagate and the grid would stay empty.
    name = 'mm → tm → vm callback chain delivers data to the grid',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)

      -- Seed mm AFTER construction — this exercises the live callback path,
      -- not the factory-body initial rebuild.
      h.fm:seed{
        notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq = 0, endppq = 240, chan = 5, pitch = 64, vel = 100 },
        },
      }

      -- Both channels should now be reachable via vm's channel selection.
      h.vm:selectChannel(1)
      local _, col1 = h.vm:cursor()
      h.vm:selectChannel(5)
      local _, col5 = h.vm:cursor()
      t.truthy(col1 > 0, 'channel 1 column exists after post-hoc seed')
      t.truthy(col5 > col1, 'channel 5 column lies after channel 1')
    end,
  },

  {
    -- If the assertion helpers were broken — eq comparing addresses, or
    -- deepEq short-circuiting — other failing tests would look green.
    -- Run the helpers against themselves.
    name = 'assertion helpers distinguish equal from unequal',
    run = function(harness)
      t.eq(1 + 1, 2)
      t.deepEq({ a = { b = 3 } }, { a = { b = 3 } })

      local ok = pcall(function() t.eq(1, 2) end)
      t.falsy(ok, 't.eq(1, 2) must raise')

      local ok2 = pcall(function() t.deepEq({ a = 1 }, { a = 2 }) end)
      t.falsy(ok2, 't.deepEq on differing tables must raise')

      local ok3 = pcall(function() t.deepEq({ a = 1 }, { a = 1, b = 2 }) end)
      t.falsy(ok3, 't.deepEq must catch missing-key asymmetry')
    end,
  },
}
