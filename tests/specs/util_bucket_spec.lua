local t = require('support')
require('util')

return {
  {
    name = 'bucket: lazy-inits a fresh array on first key',
    run = function()
      local b = {}
      local bkt = util.bucket(b, 'a', 1)
      t.eq(b.a, bkt)
      t.eq(#bkt, 1)
      t.eq(bkt[1], 1)
    end,
  },
  {
    name = 'bucket: appends to an existing key, preserving order',
    run = function()
      local b = {}
      util.bucket(b, 'a', 1)
      util.bucket(b, 'a', 2)
      util.bucket(b, 'a', 3)
      t.eq(#b.a, 3)
      t.eq(b.a[1], 1); t.eq(b.a[2], 2); t.eq(b.a[3], 3)
    end,
  },
  {
    name = 'bucket: distinct keys do not interfere',
    run = function()
      local b = {}
      util.bucket(b, 'a', 1)
      util.bucket(b, 'b', 2)
      util.bucket(b, 'a', 3)
      t.eq(#b.a, 2); t.eq(b.a[1], 1); t.eq(b.a[2], 3)
      t.eq(#b.b, 1); t.eq(b.b[1], 2)
    end,
  },
  {
    name = 'bucket: returns the bucket so callers can keep operating on it',
    run = function()
      local b = {}
      local bkt1 = util.bucket(b, 'k', 'x')
      local bkt2 = util.bucket(b, 'k', 'y')
      t.eq(bkt1, bkt2)             -- same array, not a fresh one
      t.eq(bkt2[2], 'y')
    end,
  },
  {
    name = 'bucket: false is a usable value (not treated as missing)',
    run = function()
      local b = {}
      util.bucket(b, 'k', false)
      util.bucket(b, 'k', false)
      t.eq(#b.k, 2)
      t.eq(b.k[1], false); t.eq(b.k[2], false)
    end,
  },
}
