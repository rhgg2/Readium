-- Pin-tests for the signal-keyed util.installHooks. The contract:
--   subscribe(signal, fn)    registers fn under exactly one signal kind
--   fire(signal, data)       calls only callbacks registered for `signal`,
--                            forwarding `data` (no owner arg)
--   unsubscribe              is signal-scoped
--   forward(signal, source)  subscribes on source, re-fires on owner

local t = require('support')
require('util')

local function newOwner()
  local owner = {}
  local fire = util.installHooks(owner)
  return owner, fire
end

return {
  {
    name = 'installHooks: callback only fires for its own signal',
    run = function()
      local owner, fire = newOwner()
      local seenA, seenB = {}, {}
      owner:subscribe('alpha', function(d) table.insert(seenA, d) end)
      owner:subscribe('beta',  function(d) table.insert(seenB, d) end)

      fire('alpha', { n = 1 })
      fire('beta',  { n = 2 })
      fire('alpha', { n = 3 })

      t.eq(#seenA, 2,         'alpha listener saw two fires')
      t.eq(seenA[1].n, 1,     'first alpha payload')
      t.eq(seenA[2].n, 3,     'second alpha payload')
      t.eq(#seenB, 1,         'beta listener saw one fire')
      t.eq(seenB[1].n, 2,     'beta payload')
    end,
  },
  {
    name = 'installHooks: fire on unsubscribed signal is a no-op',
    run = function()
      local owner, fire = newOwner()
      local seen = 0
      owner:subscribe('alpha', function() seen = seen + 1 end)
      fire('beta',  {})    -- nothing registered
      fire('gamma', nil)   -- nothing registered
      t.eq(seen, 0, 'no callbacks fired')
    end,
  },
  {
    name = 'installHooks: callback receives data only, no owner arg',
    run = function()
      local owner, fire = newOwner()
      local args
      owner:subscribe('alpha', function(...) args = { n = select('#', ...), ... } end)
      fire('alpha', { x = 1 })
      t.eq(args.n, 1,    'callback received exactly one arg')
      t.eq(args[1].x, 1, 'arg is the data table')
    end,
  },
  {
    name = 'installHooks: multiple listeners on one signal all fire',
    run = function()
      local owner, fire = newOwner()
      local count = 0
      owner:subscribe('alpha', function() count = count + 1 end)
      owner:subscribe('alpha', function() count = count + 10 end)
      fire('alpha', {})
      t.eq(count, 11, 'both listeners fired')
    end,
  },
  {
    name = 'installHooks: unsubscribe is signal-scoped',
    run = function()
      local owner, fire = newOwner()
      local hits = 0
      local fn = function() hits = hits + 1 end
      owner:subscribe('alpha', fn)
      owner:subscribe('beta',  fn)

      owner:unsubscribe('alpha', fn)
      fire('alpha', {})  -- removed
      fire('beta',  {})  -- still wired
      t.eq(hits, 1, 'only the beta registration survived')
    end,
  },
  {
    name = 'installHooks: forward re-fires source signal on dest with same payload',
    run = function()
      local source, fireSrc = newOwner()
      local dest = {}
      util.installHooks(dest)
      dest:forward('alpha', source)

      local seen
      dest:subscribe('alpha', function(d) seen = d end)

      fireSrc('alpha', { n = 42 })
      t.eq(seen.n, 42, 'dest subscriber saw the source payload')
    end,
  },
  {
    name = 'installHooks: forward does not cross signal kinds',
    run = function()
      local source, fireSrc = newOwner()
      local dest = {}
      util.installHooks(dest)
      dest:forward('alpha', source)

      local seenAlpha, seenBeta = 0, 0
      dest:subscribe('alpha', function() seenAlpha = seenAlpha + 1 end)
      dest:subscribe('beta',  function() seenBeta  = seenBeta  + 1 end)

      fireSrc('beta', {})
      t.eq(seenAlpha, 0, 'forward only listens for the named signal')
      t.eq(seenBeta,  0, 'unforwarded signals never reach dest subscribers')
    end,
  },
}
