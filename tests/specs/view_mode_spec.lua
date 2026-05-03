-- Pin-tests for the viewMode cm key and the toggleViewMode toggle. The
-- command itself is registered in continuum.lua's Main() (not in the
-- test harness), so the toggle test re-registers the same closure shape
-- inline. Pin-value here is the toggle invariant: 'tracker' ↔ 'sample'.

local t = require('support')

return {
  {
    name = "viewMode default is 'tracker'",
    run = function(harness)
      local h = harness.mk()
      t.eq(h.cm:get('viewMode'), 'tracker', "default surfaces from schema")
    end,
  },
  {
    name = "viewMode is writable to 'sample' at the transient tier",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('transient', 'viewMode', 'sample')
      t.eq(h.cm:get('viewMode'), 'sample', "transient write is effective")
      h.cm:remove('transient', 'viewMode')
      t.eq(h.cm:get('viewMode'), 'tracker', "after remove, schema default is back")
    end,
  },
  {
    name = "viewMode does not persist across cm reconstruction",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('transient', 'viewMode', 'sample')
      local cm2 = newConfigManager()
      cm2:setContext('take1')
      t.eq(cm2:get('viewMode'), 'tracker', "fresh cm starts at default")
    end,
  },
  {
    name = "toggleViewMode flips tracker ↔ sample",
    run = function(harness)
      local h = harness.mk()
      h.cmgr:register('toggleViewMode', function()
        h.cm:set('transient', 'viewMode',
          h.cm:get('viewMode') == 'sample' and 'tracker' or 'sample')
      end)
      t.eq(h.cm:get('viewMode'), 'tracker', "starts at default")
      h.cmgr:invoke('toggleViewMode')
      t.eq(h.cm:get('viewMode'), 'sample',  "first invoke → sample")
      h.cmgr:invoke('toggleViewMode')
      t.eq(h.cm:get('viewMode'), 'tracker', "second invoke → tracker")
    end,
  },
}
