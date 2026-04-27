-- Pin-tests for configManager's schema enforcement and ownership contract.
-- Covers: unknown-key rejection at every API entry; silent prune of unknown
-- keys on persistence load; deep-copy at read AND write boundaries so
-- callers never alias cm's internal state.

local t = require('support')

return {
  --------------------------------------------------------------------
  -- Unknown-key rejection at the API boundary
  --------------------------------------------------------------------
  {
    name = 'cm:get on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok, err = pcall(function() h.cm:get('nonsense') end)
      t.falsy(ok, 'get should raise on unknown key')
      t.truthy(tostring(err):find('nonsense'), 'error mentions the key, got: ' .. tostring(err))
    end,
  },
  {
    name = 'cm:set on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:set('take', 'nonsense', 1) end)
      t.falsy(ok, 'set should raise on unknown key')
    end,
  },
  {
    name = 'cm:remove on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:remove('take', 'nonsense') end)
      t.falsy(ok, 'remove should raise on unknown key')
    end,
  },
  {
    name = 'cm:assign rejects updates that contain unknown keys',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function()
        h.cm:assign('take', { pbRange = 4, nonsense = 1 })
      end)
      t.falsy(ok, 'assign should raise if any update key is unknown')
      -- And the partial update must not have been applied.
      t.eq(h.cm:get('pbRange'), 2, 'schema default survives rejected assign')
    end,
  },
  {
    name = 'cm:getAt on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:getAt('take', 'nonsense') end)
      t.falsy(ok, 'getAt with unknown key should raise')
    end,
  },
  {
    name = 'cm:getAt full-level read does not require a key',
    run = function(harness)
      local h = harness.mk{
        config = { take = { pbRange = 7 } },
      }
      local tbl = h.cm:getAt('take')
      t.eq(tbl.pbRange, 7, 'full-level read returns the cache for that level')
    end,
  },

  --------------------------------------------------------------------
  -- Schema defaults are the source of truth
  --------------------------------------------------------------------
  {
    name = 'schema defaults are returned when no level has set the key',
    run = function(harness)
      local h = harness.mk()
      t.eq(h.cm:get('pbRange'),         2,  'pbRange default')
      t.eq(h.cm:get('rowPerBeat'),      4,  'rowPerBeat default')
      t.eq(h.cm:get('defaultVelocity'), 100,'defaultVelocity default')
      t.eq(h.cm:get('polyAftertouch'),  true, 'polyAftertouch default')
      t.eq(h.cm:get('noteLayout'),      'colemak', 'noteLayout default')
    end,
  },
  {
    name = 'null-defaulted keys are declared but return nil',
    run = function(harness)
      local h = harness.mk()
      -- 'tuning' is declared with no default; should not raise, should return nil.
      local ok, v = pcall(function() return h.cm:get('tuning') end)
      t.truthy(ok,  'get on null-defaulted key does not raise')
      t.eq(v, nil, 'null-defaulted key returns nil')
    end,
  },

  --------------------------------------------------------------------
  -- Persistence load silently prunes unknown keys
  --------------------------------------------------------------------
  {
    -- A user's on-disk take may carry stale keys from a rename; we must
    -- be tolerant at load. Write raw ext-state that includes a stale key,
    -- then build a fresh cm and confirm it survives and has only declared
    -- keys in its cache.
    name = 'unknown keys in persisted data are pruned on load',
    run = function(harness)
      local h = harness.mk()
      -- Reach directly at the fake reaper's take ext-state to plant a
      -- stale key alongside a valid one.
      local serialised = util.serialise({ pbRange = 5, legacyKey = 'oops' })
      local take = 'take1'
      h.reaper._state.takeExt[take .. '/P_EXT:rdm_config'] = serialised

      -- Fresh cm sharing the same reaper state.
      local cm2 = newConfigManager()
      cm2:setContext(take)
      t.eq(cm2:get('pbRange'), 5, 'known key survived the load')
      local ok = pcall(function() return cm2:get('legacyKey') end)
      t.falsy(ok, 'stale key is not reachable through get (would raise if tried)')
      -- And a write to an unrelated valid key must not resurrect legacyKey.
      cm2:set('take', 'rowPerBeat', 9)
      local raw = h.reaper._state.takeExt[take .. '/P_EXT:rdm_config']
      t.falsy(raw:find('legacyKey'), 'legacyKey was pruned on load and did not round-trip: ' .. raw)
    end,
  },

  --------------------------------------------------------------------
  -- Ownership: cm:get returns a fresh deep copy
  --------------------------------------------------------------------
  {
    name = 'cm:get returns a deep copy — caller mutation does not leak',
    run = function(harness)
      local h = harness.mk{
        config = { take = { extraColumns = { [1] = { notes = 2 } } } },
      }
      local a = h.cm:get('extraColumns')
      a[1].notes = 999
      a[5] = { notes = 7 }
      local b = h.cm:get('extraColumns')
      t.eq(b[1].notes, 2,   'inner field is independent across get calls')
      t.eq(b[5], nil,       'outer key added by caller does not appear in cm')
    end,
  },
  {
    name = 'cm:get of a default table returns a fresh table each call',
    run = function(harness)
      local h = harness.mk()
      local a = h.cm:get('extraColumns')
      a[3] = { notes = 1 }
      local b = h.cm:get('extraColumns')
      t.eq(b[3], nil, 'mutation of one get return does not pollute the default')
    end,
  },
  {
    name = 'cm:set deep-copies the incoming value — caller mutation after set does not leak',
    run = function(harness)
      local h = harness.mk()
      local outer = { [1] = { notes = 3 } }
      h.cm:set('take', 'extraColumns', outer)
      outer[1].notes = 999
      outer[7] = { notes = 1 }
      local stored = h.cm:get('extraColumns')
      t.eq(stored[1].notes, 3, 'cm kept its own copy; post-set mutation by caller did not leak')
      t.eq(stored[7], nil,     'post-set addition by caller did not leak')
    end,
  },

  --------------------------------------------------------------------
  -- Level merge still works
  --------------------------------------------------------------------
  {
    name = 'more specific level overrides less specific',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { pbRange = 3 },
          take    = { pbRange = 5 },
        },
      }
      t.eq(h.cm:get('pbRange'), 5, 'take overrides project')
    end,
  },
  {
    name = 'remove at a level falls back to the next less-specific level',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { pbRange = 3 },
          take    = { pbRange = 5 },
        },
      }
      h.cm:remove('take', 'pbRange')
      t.eq(h.cm:get('pbRange'), 3, 'after take remove, project value is effective')
      h.cm:remove('project', 'pbRange')
      t.eq(h.cm:get('pbRange'), 2, 'after project remove, schema default is effective')
    end,
  },

  --------------------------------------------------------------------
  -- transient tier: most-specific, never persisted
  --------------------------------------------------------------------
  {
    name = 'transient is the most-specific level (overrides take)',
    run = function(harness)
      local h = harness.mk{
        config = {
          take      = { pbRange = 5 },
          transient = { pbRange = 7 },
        },
      }
      t.eq(h.cm:get('pbRange'), 7, 'transient overrides take')
      h.cm:remove('transient', 'pbRange')
      t.eq(h.cm:get('pbRange'), 5, 'after transient remove, take value is effective')
    end,
  },
  {
    name = 'transient writes do not persist across cm reconstruction',
    run = function(harness)
      local h = harness.mk{
        config = { take = { pbRange = 5 } },
      }
      h.cm:set('transient', 'pbRange', 9)
      t.eq(h.cm:get('pbRange'), 9, 'transient write is visible on this cm')
      -- Rebuild a cm against the same take: persisted tiers reload from
      -- ext-state, transient must come up empty.
      local cm2 = newConfigManager()
      cm2:setContext('take1')
      t.eq(cm2:get('pbRange'), 5, 'fresh cm sees take but no transient leak')
      t.eq(cm2:getAt('transient', 'pbRange'), nil, 'transient cache is empty on reload')
    end,
  },
  {
    name = 'cm fires changes with their level on the broadcast',
    run = function(harness)
      local h = harness.mk()
      local seen = {}
      h.cm:subscribe('configChanged', function(changed) table.insert(seen, changed) end)
      h.cm:set('take', 'pbRange', 4)
      h.cm:remove('take', 'pbRange')
      h.cm:assign('transient', { pbRange = 3 })
      t.eq(seen[1].level, 'take',      'set carries level=take')
      t.eq(seen[1].key,   'pbRange',   'set carries key=pbRange')
      t.eq(seen[2].level, 'take',      'remove carries level=take')
      t.eq(seen[3].level, 'transient', 'assign carries level=transient')
      t.eq(seen[3].key,   nil,         'assign has no key (keyless broadcast)')
    end,
  },
}
