-- Pin-tests for the tier-1 reconciliation pass — the "nothing drifted"
-- common case. Tier 1 binds sidecars to ccs only when every fingerprint
-- field matches exactly; anything weaker falls through to later tiers
-- (handled in a follow-up phase).

local t = require('support')
_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')

-- midiManager.lua defines newMidiManager as a side-effect; the harness has
-- a fake under that name and we don't want to clobber it for later specs.
local saved = _G.newMidiManager
require('midiManager')
_G.newMidiManager = saved

local sr = newSidecarReconciler()

-- Sidecars and ccs share a record shape — sidecars come from sr:decode, with
-- the sysex event's ppq attached. Both sides carry { msgType, chan, [cc|pitch], val }.
local function sidecar(t) return t end
local function cc(t)      return t end

return {
  {
    name = 'one sidecar coincident with one matching cc binds',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 100,           msgType = 'cc', chan = 1, cc = 7, val = 64 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1 } })
      t.deepEq(r.unboundSidecarIdxs, {})
      t.deepEq(r.unboundCcIdxs,      {})
    end,
  },

  {
    name = 'pa events bind on pitch',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 50, uuid = 9, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
        { cc     { ppq = 50,           msgType = 'pa', chan = 5, pitch = 60, val = 100 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1 } })
    end,
  },

  {
    name = 'pb fingerprint match (signed val) binds',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 0, uuid = 2, msgType = 'pb', chan = 1, val = -4096 } },
        { cc     { ppq = 0,           msgType = 'pb', chan = 1, val = -4096 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1 } })
    end,
  },

  {
    name = 'value drift leaves both unbound (handed off to tier 2)',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 100,           msgType = 'cc', chan = 1, cc = 7, val = 65 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'ppq drift leaves both unbound (handed off to tier 3)',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 110,           msgType = 'cc', chan = 1, cc = 7, val = 64 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'multiple sidecars + ccs, all matching, all bind',
    run = function()
      local r = sr:tier1(
        {
          sidecar{ ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0   },
          sidecar{ ppq = 240, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 64  },
          sidecar{ ppq = 480, uuid = 3, msgType = 'cc', chan = 1, cc = 11, val = 100 },
        },
        {
          cc{ ppq =   0, msgType = 'cc', chan = 1, cc = 7,  val = 0   },
          cc{ ppq = 240, msgType = 'cc', chan = 1, cc = 7,  val = 64  },
          cc{ ppq = 480, msgType = 'cc', chan = 1, cc = 11, val = 100 },
        })
      t.eq(#r.binds, 3, 'all three bind')
      t.deepEq(r.unboundSidecarIdxs, {})
      t.deepEq(r.unboundCcIdxs,      {})
    end,
  },

  {
    name = 'sidecar with no cc at all becomes unbound',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        {})
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      {})
    end,
  },

  {
    name = 'untouched cc with no sidecar shows up in unboundCcIdxs',
    run = function()
      local r = sr:tier1({}, { cc{ ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 0 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, {})
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'two identical-fingerprint ccs are claimed by two sidecars in order',
    run = function()
      -- Pre-dedup the loader can see duplicates with identical fingerprints.
      -- Tier 1 hands one to each sidecar; cc-dedup runs later (different phase).
      local r = sr:tier1(
        {
          sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        {
          cc{ ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          cc{ ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        })
      t.eq(#r.binds, 2)
      t.eq(#r.unboundSidecarIdxs, 0)
      t.eq(#r.unboundCcIdxs, 0)
      local claimed = {}
      for _, b in ipairs(r.binds) do
        t.falsy(claimed[b.ccIdx], 'cc claimed twice')
        claimed[b.ccIdx] = true
      end
    end,
  },

  {
    name = 'mismatched chan does not bind',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 } },
        { cc     { ppq = 0,           msgType = 'cc', chan = 2, cc = 7, val = 0 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'mismatched msgType does not bind (cc vs pb at same ppq/chan)',
    run = function()
      local r = sr:tier1(
        { sidecar{ ppq = 0, uuid = 1, msgType = 'pb', chan = 1, val = 0 } },
        { cc     { ppq = 0,           msgType = 'cc', chan = 1, cc = 0, val = 0 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },
}
