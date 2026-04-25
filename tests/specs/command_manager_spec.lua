-- commandManager: doBefore/doAfter accept either a single name or a
-- list. The list form is sugar; pin that it composes hooks in order
-- and that the single-name form still works.

local t = require('support')

require('commandManager')

local function fresh()
  local mgr = newCommandManager(nil)
  local log = {}
  mgr:registerAll{
    a = function() log[#log + 1] = 'A' end,
    b = function() log[#log + 1] = 'B' end,
    c = function() log[#log + 1] = 'C' end,
  }
  return mgr, log
end

return {
  {
    name = 'doBefore with a string still wraps a single command',
    run = function()
      local mgr, log = fresh()
      mgr:doBefore('a', function() log[#log + 1] = 'pre' end)
      mgr:invoke('a')
      mgr:invoke('b')
      t.deepEq(log, { 'pre', 'A', 'B' })
    end,
  },

  {
    name = 'doAfter with a list applies the hook to every named command',
    run = function()
      local mgr, log = fresh()
      mgr:doAfter({ 'a', 'b' }, function() log[#log + 1] = 'post' end)
      mgr:invoke('a')
      mgr:invoke('b')
      mgr:invoke('c')
      t.deepEq(log, { 'A', 'post', 'B', 'post', 'C' })
    end,
  },

  {
    name = 'doBefore with a list fires before each named command',
    run = function()
      local mgr, log = fresh()
      mgr:doBefore({ 'a', 'c' }, function() log[#log + 1] = 'pre' end)
      mgr:invoke('a')
      mgr:invoke('b')
      mgr:invoke('c')
      t.deepEq(log, { 'pre', 'A', 'B', 'pre', 'C' })
    end,
  },

  {
    name = 'list form composes with prior single-name wraps',
    run = function()
      local mgr, log = fresh()
      mgr:doAfter('a', function() log[#log + 1] = 'a-after' end)
      mgr:doAfter({ 'a', 'b' }, function() log[#log + 1] = 'shared-after' end)
      mgr:invoke('a')
      mgr:invoke('b')
      -- 'a' carries both wraps (inner 'a-after' set first, outer 'shared-after' stacks);
      -- 'b' carries only the shared one.
      t.deepEq(log, { 'A', 'a-after', 'shared-after', 'B', 'shared-after' })
    end,
  },
}
