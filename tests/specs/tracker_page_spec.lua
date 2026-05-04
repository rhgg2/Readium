-- Pin-tests for trackerPage's Page interface (bind / unbind / focusState).
-- render / handleInput / save / load are stubs wired in step 3 and
-- verified in REAPER rather than here.
--
-- trackerPage requires ImGui at module scope.  We stub it via
-- package.preload before the first require so the module loads cleanly
-- in the pure-Lua harness.

local t = require('support')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end
require('trackerPage')

return {
  {
    name = "bind(take) forwards take to cm:setContext",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.vm, h.cm, h.cmgr, nil)
      local got = {}
      h.cm.setContext = function(_, take) got[#got+1] = take end
      tp:bind('take99')
      t.eq(#got, 1,        "setContext called once")
      t.eq(got[1], 'take99', "called with the supplied take")
    end,
  },
  {
    name = "unbind() calls cm:setContext(nil)",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.vm, h.cm, h.cmgr, nil)
      local called, arg = false, 'unset'
      h.cm.setContext = function(_, take) called = true; arg = take end
      tp:unbind()
      t.eq(called, true, "setContext was called")
      t.eq(arg,    nil,  "called with nil")
    end,
  },
  {
    name = "focusState suppressKbd is false with no modal or picker",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.vm, h.cm, h.cmgr, nil)
      local fs = tp:focusState()
      t.eq(fs.suppressKbd, false, "no suppression at construction")
    end,
  },
}
