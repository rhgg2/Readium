-- Pin-tests for sr:reconcile — the unified sidecar↔cc binding pass. Bucket
-- once by (msgType, chan, id) and run four stages within each bucket:
--   1. exact (ppq, val) match    → silent bind  (b.silent = true)
--   2. same ppq, val differs     → valueRebound
--   3. consensus offset          → consensusRebound (≥ 50% of bucket sidecars,
--                                  min 2 voters)
--   4. per-orphan 0/1/many       → orphaned / guessedRebound / ambiguous

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

  -- ---------- Stage 1: exact match (silent) ----------

  {
    name = 'exact (ppq, val) match → silent bind, no event',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 100,           msgType = 'cc', chan = 1, cc = 7, val = 64 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1, silent = true } })
      t.deepEq(r.events, {})
      t.deepEq(r.unboundSidecarIdxs, {})
      t.deepEq(r.unboundCcIdxs,      {})
    end,
  },

  {
    name = 'pa events bind on pitch (silent)',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 50, uuid = 9, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
        { cc     { ppq = 50,           msgType = 'pa', chan = 5, pitch = 60, val = 100 } })
      t.eq(#r.binds, 1)
      t.eq(r.binds[1].silent, true)
    end,
  },

  {
    name = 'pb fingerprint match (signed val) binds silently',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 0, uuid = 2, msgType = 'pb', chan = 1, val = -4096 } },
        { cc     { ppq = 0,           msgType = 'pb', chan = 1, val = -4096 } })
      t.eq(#r.binds, 1)
      t.eq(r.binds[1].silent, true)
    end,
  },

  {
    name = 'multiple coincident matches all bind silently',
    run = function()
      local r = sr:reconcile(
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
      t.eq(#r.binds, 3)
      for _, b in ipairs(r.binds) do t.eq(b.silent, true) end
      t.deepEq(r.events, {})
    end,
  },

  {
    name = 'two identical-fingerprint ccs are claimed in order (no double-bind)',
    run = function()
      -- Pre-dedup the loader can see duplicates; reconcile hands one to each
      -- sidecar and cc-dedup runs later.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        {
          cc{ ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          cc{ ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        })
      t.eq(#r.binds, 2)
      local claimed = {}
      for _, b in ipairs(r.binds) do
        t.falsy(claimed[b.ccIdx], 'cc claimed twice')
        claimed[b.ccIdx] = true
        t.eq(b.silent, true)
      end
    end,
  },

  -- ---------- Stage 2: same ppq, val differs (valueRebound) ----------

  {
    name = 'val differs at same ppq → valueRebound + non-silent bind',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 100,           msgType = 'cc', chan = 1, cc = 7, val = 80 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1, silent = false } })
      t.eq(#r.events, 1)
      local e = r.events[1]
      t.eq(e.kind, 'valueRebound')
      t.eq(e.uuid, 1)
      t.eq(e.ppq, 100)
      t.eq(e.chan, 1)
      t.eq(e.msgType, 'cc')
      t.eq(e.cc, 7)
      t.eq(e.oldVal, 64)
      t.eq(e.newVal, 80)
    end,
  },

  {
    name = 'pb val drift round-trips signed val into oldVal/newVal',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 0, uuid = 2, msgType = 'pb', chan = 1, val = -4096 } },
        { cc     { ppq = 0,           msgType = 'pb', chan = 1, val = 2048  } })
      t.eq(#r.binds, 1)
      t.eq(r.events[1].kind, 'valueRebound')
      t.eq(r.events[1].oldVal, -4096)
      t.eq(r.events[1].newVal, 2048)
    end,
  },

  {
    name = 'two sidecars same partKey, one val-differing cc → first binds, second orphans',
    run = function()
      -- First sidecar takes the cc by valueRebound; second has no remaining
      -- candidates in the bucket → stage 4 orphans it.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 0, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        { cc{ ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 90 } })
      t.eq(#r.binds, 1)
      t.eq(r.binds[1].sidecarIdx, 1)
      local kinds = {}
      for _, e in ipairs(r.events) do kinds[e.uuid] = e.kind end
      t.eq(kinds[1], 'valueRebound')
      t.eq(kinds[2], 'orphaned')
    end,
  },

  -- ---------- Stage 3: consensus offset (consensusRebound) ----------

  {
    name = 'two sidecars + two ccs at uniform +20 offset → consensus binds both',
    run = function()
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        {
          cc{ ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0  },
          cc{ ppq = 120, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        })
      t.eq(#r.binds, 2)
      for _, b in ipairs(r.binds) do t.eq(b.silent, false) end
      for _, e in ipairs(r.events) do
        t.eq(e.kind, 'consensusRebound')
        t.eq(e.offset, 20)
      end
    end,
  },

  {
    name = 'consensusRebound payload reports the bound cc\'s ppq + offset',
    run = function()
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        {
          cc{ ppq = -10, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          cc{ ppq = 90,  msgType = 'cc', chan = 1, cc = 7, val = 64 },
        })
      t.eq(#r.binds, 2)
      local byUuid = {}
      for _, e in ipairs(r.events) do byUuid[e.uuid] = e end
      t.eq(byUuid[1].ppq, -10)
      t.eq(byUuid[2].ppq,  90)
      t.eq(byUuid[1].offset, -10)
      t.eq(byUuid[2].offset, -10)
    end,
  },

  {
    name = 'three uniformly-drifted sidecars in one bucket bind despite cross-pair noise',
    run = function()
      -- Every sidecar sees every cc as a candidate; cross-pairing votes
      -- accumulate for noise offsets, but +20 wins outright (3 votes — the
      -- one offset every sidecar agrees on).
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        {
          cc{ ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 120, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 220, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        })
      t.eq(#r.binds, 3)
      for _, e in ipairs(r.events) do
        t.eq(e.kind, 'consensusRebound')
        t.eq(e.offset, 20)
      end
    end,
  },

  {
    name = 'tied top vote-getters drop through stage 3, fall to stage 4 (ambiguous)',
    run = function()
      -- 4 sidecars, 4 ccs: two at +10, two at +20. Each sidecar votes for
      -- both candidate offsets, so +10 has 2, +20 has 2 → tie. No consensus.
      -- Stage 4 sees every sidecar with all 4 ccs as candidates → ambiguous.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 300, uuid = 4, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        {
          cc{ ppq = 10,  msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 110, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 220, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 320, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        })
      t.deepEq(r.binds, {})
      t.eq(#r.events, 4)
      for _, e in ipairs(r.events) do t.eq(e.kind, 'ambiguous') end
    end,
  },

  -- ---------- Stage 4: per-orphan fallback ----------

  {
    name = 'no candidates → orphaned (no bind)',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        {})
      t.deepEq(r.binds, {})
      t.eq(#r.events, 1)
      local e = r.events[1]
      t.eq(e.kind, 'orphaned')
      t.eq(e.uuid, 1)
      t.eq(e.lastPpq, 100)
      t.eq(e.chan, 1)
      t.eq(e.msgType, 'cc')
      t.eq(e.cc, 7)
      t.eq(e.ppq, nil, 'orphans use lastPpq, never ppq (no bound cc to point at)')
      t.deepEq(r.unboundSidecarIdxs, { 1 })
    end,
  },

  {
    name = 'one candidate at drifted ppq → guessedRebound binds at the cc\'s ppq',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        { cc     { ppq = 130,           msgType = 'cc', chan = 1, cc = 7, val = 99 } })
      t.deepEq(r.binds, { { sidecarIdx = 1, ccIdx = 1, silent = false } })
      t.eq(#r.events, 1)
      local e = r.events[1]
      t.eq(e.kind, 'guessedRebound')
      t.eq(e.uuid, 1)
      t.eq(e.ppq, 130, 'event ppq points at the bound cc')
      t.eq(e.cc, 7)
    end,
  },

  {
    name = 'two candidates → ambiguous, no bind, candidatePpqs reported',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        {
          cc{ ppq = 50,  msgType = 'cc', chan = 1, cc = 7, val = 64 },
          cc{ ppq = 150, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        })
      t.deepEq(r.binds, {})
      t.eq(#r.events, 1)
      local e = r.events[1]
      t.eq(e.kind, 'ambiguous')
      t.eq(e.uuid, 1)
      t.deepEq(e.candidatePpqs, { 50, 150 })
    end,
  },

  {
    name = 'pa orphan reports pitch (not cc)',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 100, uuid = 9, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
        {})
      t.eq(#r.events, 1)
      t.eq(r.events[1].pitch, 60)
      t.eq(r.events[1].cc, nil)
    end,
  },

  {
    name = 'two sidecars, one cc same bucket → first guesses, second orphans',
    run = function()
      -- Stage 3: 2 sidecars, 1 cc; offsets +50 and -50 each get 1 vote → tie
      -- below threshold. Stage 4: first sidecar gets the cc as
      -- guessedRebound; second sees zero candidates → orphaned.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        { cc{ ppq = 50, msgType = 'cc', chan = 1, cc = 7, val = 0 } })
      t.eq(#r.binds, 1)
      t.eq(r.binds[1].sidecarIdx, 1)
      local kinds = {}
      for _, e in ipairs(r.events) do kinds[e.uuid] = e.kind end
      t.eq(kinds[1], 'guessedRebound')
      t.eq(kinds[2], 'orphaned')
    end,
  },

  -- ---------- Bucket isolation ----------

  {
    name = 'mismatched chan: separate buckets → orphaned + unbound cc',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 } },
        { cc     { ppq = 0,           msgType = 'cc', chan = 2, cc = 7, val = 0 } })
      t.deepEq(r.binds, {})
      t.eq(#r.events, 1)
      t.eq(r.events[1].kind, 'orphaned')
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'mismatched msgType: separate buckets (cc vs pb)',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 0, uuid = 1, msgType = 'pb', chan = 1, val = 0       } },
        { cc     { ppq = 0,           msgType = 'cc', chan = 1, cc = 0, val = 0 } })
      t.deepEq(r.binds, {})
      t.eq(#r.events, 1)
      t.eq(r.events[1].kind, 'orphaned')
      t.deepEq(r.unboundSidecarIdxs, { 1 })
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'mismatched cc#: separate buckets',
    run = function()
      local r = sr:reconcile(
        { sidecar{ ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0  } },
        { cc     { ppq = 0,           msgType = 'cc', chan = 1, cc = 11, val = 50 } })
      t.deepEq(r.binds, {})
      t.eq(#r.events, 1)
      t.eq(r.events[1].kind, 'orphaned')
    end,
  },

  {
    name = 'untouched cc with no sidecars in its bucket shows up in unboundCcIdxs',
    run = function()
      local r = sr:reconcile({}, { cc{ ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 0 } })
      t.deepEq(r.binds,              {})
      t.deepEq(r.events,             {})
      t.deepEq(r.unboundSidecarIdxs, {})
      t.deepEq(r.unboundCcIdxs,      { 1 })
    end,
  },

  {
    name = 'separate (chan, cc#) buckets resolve independently',
    run = function()
      -- chan=1 cc=7 bucket: 2 sidecars + 2 ccs at +20 → consensus.
      -- chan=1 cc=11 bucket: 1 sidecar + 1 cc at -5 → below stage-3
      -- threshold, falls to stage 4 → guessedRebound.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0  },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          sidecar{ ppq = 50,  uuid = 3, msgType = 'cc', chan = 1, cc = 11, val = 30 },
        },
        {
          cc{ ppq = 20,  msgType = 'cc', chan = 1, cc = 7,  val = 0  },
          cc{ ppq = 120, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          cc{ ppq = 45,  msgType = 'cc', chan = 1, cc = 11, val = 30 },
        })
      t.eq(#r.binds, 3)
      local kinds = {}
      for _, e in ipairs(r.events) do kinds[e.uuid] = e.kind end
      t.eq(kinds[1], 'consensusRebound')
      t.eq(kinds[2], 'consensusRebound')
      t.eq(kinds[3], 'guessedRebound')
    end,
  },

  {
    name = 'cross-msgType events live in different buckets — stage 4 each',
    run = function()
      -- A pb sidecar and a cc sidecar at the same chan are still different
      -- buckets. Each bucket has 1 sidecar + 1 cc → guessedRebound apiece.
      local r = sr:reconcile(
        {
          sidecar{ ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'pb', chan = 1,         val = 0 },
        },
        {
          cc{ ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0 },
          cc{ ppq = 120, msgType = 'pb', chan = 1,         val = 0 },
        })
      t.eq(#r.binds, 2)
      for _, e in ipairs(r.events) do t.eq(e.kind, 'guessedRebound') end
    end,
  },

  -- ---------- Mixed end-to-end ----------

  {
    name = 'mixed: silent + valueRebound + consensus + orphan in one call',
    run = function()
      -- Bucket cc=7 chan=1: sidecar 1 exact-matches cc 1 (silent); sidecars
      -- 2 & 3 + ccs 2 & 3 drift by +30 (consensus). Bucket cc=11 chan=1:
      -- sidecar 4 same ppq, val differs (valueRebound). Bucket cc=20 chan=1:
      -- sidecar 5, no ccs (orphaned).
      local r = sr:reconcile(
        {
          sidecar{ ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 10 },
          sidecar{ ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 20 },
          sidecar{ ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7,  val = 30 },
          sidecar{ ppq = 400, uuid = 4, msgType = 'cc', chan = 1, cc = 11, val = 50 },
          sidecar{ ppq = 500, uuid = 5, msgType = 'cc', chan = 1, cc = 20, val = 99 },
        },
        {
          cc{ ppq =   0, msgType = 'cc', chan = 1, cc = 7,  val = 10 },
          cc{ ppq = 130, msgType = 'cc', chan = 1, cc = 7,  val = 20 },
          cc{ ppq = 230, msgType = 'cc', chan = 1, cc = 7,  val = 30 },
          cc{ ppq = 400, msgType = 'cc', chan = 1, cc = 11, val = 77 },
        })
      local kinds, silentByUuid = {}, {}
      for _, e in ipairs(r.events) do kinds[e.uuid] = e.kind end
      for _, b in ipairs(r.binds) do
        local sc = ({ 1, 2, 3, 4, 5 })[b.sidecarIdx]
        silentByUuid[sc] = b.silent
      end
      t.eq(silentByUuid[1], true,  'sidecar 1 silent (exact match)')
      t.eq(silentByUuid[2], false, 'sidecar 2 noisy (consensus)')
      t.eq(silentByUuid[3], false, 'sidecar 3 noisy (consensus)')
      t.eq(silentByUuid[4], false, 'sidecar 4 noisy (valueRebound)')
      t.eq(kinds[1], nil, 'silent rebind has no event')
      t.eq(kinds[2], 'consensusRebound')
      t.eq(kinds[3], 'consensusRebound')
      t.eq(kinds[4], 'valueRebound')
      t.eq(kinds[5], 'orphaned')
      t.deepEq(r.unboundSidecarIdxs, { 5 })
    end,
  },
}
