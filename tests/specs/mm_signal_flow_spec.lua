-- Pin-tests for the mm → tm signal split landed in the callbacks revamp.
--
-- Contract under test:
--   * mm fires `takeSwapped` only when mm:load receives a different take,
--     and always BEFORE its `reload` fire on that load.
--   * mm fires `reload` on every load, with no payload.
--   * tm forwards `takeSwapped` to its own subscribers and consumes the
--     flag transiently, calling tm:rebuild(true) on the next reload.
--   * tm fires `rebuild` (no payload) on every rebuild.
--   * The takeSwapped flag is one-shot: a subsequent same-take reload
--     does not re-fire takeSwapped and tm:rebuild sees takeChanged=false.

local t = require('support')
local harness = require('harness')

-- Records the sequence of signals fired on a single owner. Listener order
-- across owners is non-deterministic (set iteration), so each owner gets
-- its own stream and ordering assertions stay within one source.
local function recordOn(owner, signals)
  local stream = {}
  for _, sig in ipairs(signals) do
    owner:subscribe(sig, function() stream[#stream+1] = sig end)
  end
  return stream
end

return {
  {
    name = 'mm:load with a different take fires mm.takeSwapped before mm.reload',
    run = function()
      local h = harness.mk()
      local mmStream = recordOn(h.fm, { 'takeSwapped', 'reload' })
      local tmStream = recordOn(h.tm, { 'takeSwapped', 'rebuild' })

      h.fm:load('different-take')

      t.eq(table.concat(mmStream, ','), 'takeSwapped,reload',
        'mm fires takeSwapped before reload')
      t.eq(table.concat(tmStream, ','), 'takeSwapped,rebuild',
        'tm forwards takeSwapped before its own rebuild')
    end,
  },

  {
    name = 'mm:load with the same take fires reload only',
    run = function()
      local h = harness.mk()
      local mmStream = recordOn(h.fm, { 'takeSwapped', 'reload' })
      local tmStream = recordOn(h.tm, { 'takeSwapped', 'rebuild' })

      h.fm:load(h.fm:take())

      t.eq(table.concat(mmStream, ','), 'reload', 'no takeSwapped on same-take reload')
      t.eq(table.concat(tmStream, ','), 'rebuild', 'tm forwards reload→rebuild only')
    end,
  },

  {
    name = 'takeSwapped is one-shot: next same-take reload sees takeChanged=false',
    run = function()
      local h = harness.mk()
      -- Spy on tm:rebuild's argument by wrapping the method.
      local seen = {}
      local orig = h.tm.rebuild
      h.tm.rebuild = function(self, takeChanged)
        seen[#seen+1] = takeChanged or false
        return orig(self, takeChanged)
      end

      h.fm:load('different-take')   -- expect tm:rebuild(true)
      h.fm:load('different-take')   -- same take — expect tm:rebuild(false)

      t.eq(seen[1], true,  'first load saw takeChanged=true')
      t.eq(seen[2], false, 'second load saw takeChanged=false')
    end,
  },

  {
    name = 'mm.reload payload is nil (no smuggled flags)',
    run = function()
      local h = harness.mk()
      local count, lastPayload = 0, 'unset'
      h.fm:subscribe('reload', function(data) count = count + 1; lastPayload = data end)
      h.fm:load(h.fm:take())
      t.eq(count, 1, 'reload fired exactly once')
      t.eq(lastPayload, nil, 'reload payload is nil')
    end,
  },

  {
    name = 'tm.rebuild payload is nil (takeSwapped travels via its own signal)',
    run = function()
      local h = harness.mk()
      local count, lastPayload = 0, 'unset'
      h.tm:subscribe('rebuild', function(data) count = count + 1; lastPayload = data end)
      h.fm:load('different-take')
      t.eq(count, 1, 'rebuild fired exactly once')
      t.eq(lastPayload, nil, 'rebuild payload is nil')
    end,
  },

  {
    name = 'multiple subscribers on the same signal both fire',
    run = function()
      local h = harness.mk()
      local a, b = 0, 0
      h.fm:subscribe('reload', function() a = a + 1 end)
      h.fm:subscribe('reload', function() b = b + 1 end)
      h.fm:load(h.fm:take())
      t.eq(a, 1)
      t.eq(b, 1)
    end,
  },
}
