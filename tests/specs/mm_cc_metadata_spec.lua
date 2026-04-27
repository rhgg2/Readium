-- Pin-tests for the cc-side of the per-event metadata contract — uuid
-- allocation on first stamp, lockless carve-out for subsequent metadata,
-- and clean-up on delete.

local t = require('support')

return {
  {
    name = 'metadata-only assignCC on a plain (un-uuid\'d) cc requires the lock',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      local ok, err = pcall(function() h.fm:assignCC(1, { foo = 1 }) end)
      t.falsy(ok, 'expected an assertion')
      t.truthy(tostring(err):find('modify'), 'error mentions modify lock')
    end,
  },

  {
    name = 'first metadata stamp allocates a uuid and persists the field',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assignCC(1, { foo = 'hello' }) end)
      local cc = h.fm:getCC(1)
      t.truthy(cc.uuid, 'uuid allocated')
      t.eq(cc.foo, 'hello')
    end,
  },

  {
    name = 'subsequent metadata writes on a stamped cc are lockless',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assignCC(1, { foo = 1 }) end)
      -- No modify wrapper this time — must not raise.
      h.fm:assignCC(1, { foo = 2 })
      t.eq(h.fm:getCC(1).foo, 2)
    end,
  },

  {
    name = 'mixed structural+metadata write under modify stamps in one go',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assignCC(1, { val = 100, label = 'tag' }) end)
      local cc = h.fm:getCC(1)
      t.eq(cc.val, 100)
      t.eq(cc.label, 'tag')
      t.truthy(cc.uuid, 'uuid stamped on the same write')
    end,
  },

  {
    name = 'pure-structural writes leave plain ccs un-uuid\'d',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assignCC(1, { val = 100 }) end)
      t.eq(h.fm:getCC(1).uuid, nil, 'no metadata, no uuid (sidecar-on-touch)')
    end,
  },

  {
    name = 'distinct first stamps get distinct uuids',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq =  0, msgType = 'cc', chan = 1, cc = 7, val = 0   },
            { ppq = 10, msgType = 'cc', chan = 1, cc = 7, val = 64  },
          },
        },
      }
      h.fm:modify(function()
        h.fm:assignCC(1, { foo = 1 })
        h.fm:assignCC(2, { foo = 2 })
      end)
      local u1, u2 = h.fm:getCC(1).uuid, h.fm:getCC(2).uuid
      t.truthy(u1 and u2, 'both got uuids')
      t.truthy(u1 ~= u2, 'and they differ')
    end,
  },

  {
    name = 'pre-seeded uuid is preserved and not re-issued',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64, uuid = 100, foo = 'old' } },
        },
      }
      -- Lockless carve-out path (uuid present, metadata-only)
      h.fm:assignCC(1, { foo = 'new' })
      local cc = h.fm:getCC(1)
      t.eq(cc.uuid, 100, 'pre-seeded uuid retained')
      t.eq(cc.foo, 'new')
    end,
  },

  {
    name = 'deleteCC removes both event and uuid identity',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assignCC(1, { foo = 'x' }) end)
      t.truthy(h.fm:getCC(1).uuid)
      h.fm:modify(function() h.fm:deleteCC(1) end)
      t.eq(h.fm:getCC(1), nil, 'cc gone')
    end,
  },

  {
    name = 'util.REMOVE clears a metadata field on a stamped cc (no lock)',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64,
                           uuid = 7, foo = 'present' } } },
      }
      h.fm:assignCC(1, { foo = util.REMOVE })
      t.eq(h.fm:getCC(1).foo, nil)
    end,
  },
}
