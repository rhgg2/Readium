-- Algorithm pin-tests for the load-time sidecar↔cc reconciliation pass folded
-- into mm:load. Bucket once by (msgType, chan, id) and run four stages:
--   1. exact (ppq, val) match    → silent bind (no ccsReconciled event)
--   2. same ppq, val differs     → valueRebound
--   3. consensus offset          → consensusRebound (≥ 50% of bucket sidecars,
--                                  min 2 voters)
--   4. per-orphan 0/1/many       → orphaned / guessedRebound / ambiguous
--
-- Wiring (signal ordering, metadata merge, ext-data hygiene, post-load idx
-- fixup) is covered in mm_cc_reconcile_spec; this spec stays algorithm-only.

local t = require('support')
_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')
local realMM = require('realMidiManager')()

local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-sidecar-reconcile'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

-- Cc-shaped record → REAPER's (chanmsg, msg2, msg3) packing.
local function packCc(c)
  local msg2, msg3
  if c.msgType == 'pb' then
    local raw = (c.val or 0) + 8192
    msg2, msg3 = raw & 0x7F, (raw >> 7) & 0x7F
  elseif c.msgType == 'pa' then
    msg2, msg3 = c.pitch or 0, c.val or 0
  elseif c.msgType == 'pc' or c.msgType == 'at' then
    msg2, msg3 = c.val or 0, 0
  else
    msg2, msg3 = c.cc or 0, c.val or 0
  end
  return CHANMSG[c.msgType], msg2, msg3
end

-- Seed ccs + sidecars onto the take. No metadata laid down — algorithm tests
-- don't need the ext-data side effects.
local function seed(take, reaper, spec)
  local ccs, texts = {}, {}
  for _, c in ipairs(spec.ccs or {}) do
    local chanmsg, msg2, msg3 = packCc(c)
    ccs[#ccs+1] = { ppq = c.ppq, chanmsg = chanmsg, chan = (c.chan or 1) - 1,
                    msg2 = msg2, msg3 = msg3 }
  end
  for _, sc in ipairs(spec.sidecars or {}) do
    local body = t.encodeSidecar{ uuid = sc.uuid, msgType = sc.msgType, chan = sc.chan,
                                  cc = sc.cc, pitch = sc.pitch, val = sc.val }
    texts[#texts+1] = { ppq = sc.ppq, eventtype = -1, msg = body }
  end
  reaper:seedMidi(take, { ccs = ccs, texts = texts })
end

-- Returns (mm, events_by_uuid, events_array). `events_by_uuid` collapses
-- ccsReconciled entries by uuid for compact assertions; the array preserves
-- order.
local function load(take)
  local mm = realMM(nil)
  local events = {}
  mm:subscribe('ccsReconciled', function(d)
    for _, e in ipairs(d.events) do events[#events+1] = e end
  end)
  mm:load(take)
  local byUuid = {}
  for _, e in ipairs(events) do byUuid[e.uuid] = e end
  return mm, byUuid, events
end

-- All ccs on the loaded mm, by location.
local function ccsByLoc(mm)
  local out = {}
  for loc, c in mm:ccs() do out[loc] = c end
  return out
end

return {

  -- ---------- Stage 1: exact match (silent) ----------

  {
    name = 'exact (ppq, val) match → silent bind, no event',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
      })
      local mm, _, evts = load(take)
      t.deepEq(evts, {})
      t.eq(mm:getCC(1).uuid, 1)
    end,
  },

  {
    name = 'pa events bind on pitch (silent)',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 50, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
        sidecars = { { ppq = 50, uuid = 9, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
      })
      local mm, _, evts = load(take)
      t.deepEq(evts, {})
      t.eq(mm:getCC(1).uuid, 9)
    end,
  },

  {
    name = 'pb fingerprint match (signed val) binds silently',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'pb', chan = 1, val = -4096 } },
        sidecars = { { ppq = 0, uuid = 2, msgType = 'pb', chan = 1, val = -4096 } },
      })
      local mm, _, evts = load(take)
      t.deepEq(evts, {})
      t.eq(mm:getCC(1).uuid, 2)
    end,
  },

  {
    name = 'multiple coincident matches all bind silently',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =   0, msgType = 'cc', chan = 1, cc = 7,  val = 0   },
          { ppq = 240, msgType = 'cc', chan = 1, cc = 7,  val = 64  },
          { ppq = 480, msgType = 'cc', chan = 1, cc = 11, val = 100 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0   },
          { ppq = 240, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 64  },
          { ppq = 480, uuid = 3, msgType = 'cc', chan = 1, cc = 11, val = 100 },
        },
      })
      local mm, _, evts = load(take)
      t.deepEq(evts, {})
      local uuids = {}
      for _, c in mm:ccs() do uuids[c.ppq] = c.uuid end
      t.deepEq(uuids, { [0] = 1, [240] = 2, [480] = 3 })
    end,
  },

  -- ---------- Stage 2: same ppq, val differs (valueRebound) ----------

  {
    name = 'val differs at same ppq → valueRebound + non-silent bind',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 80 } },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
      })
      local mm, byUuid, evts = load(take)
      t.eq(#evts, 1)
      local e = byUuid[1]
      t.eq(e.kind, 'valueRebound')
      t.eq(e.ppq, 100)
      t.eq(e.chan, 1)
      t.eq(e.msgType, 'cc')
      t.eq(e.cc, 7)
      t.eq(e.oldVal, 64)
      t.eq(e.newVal, 80)
      t.eq(mm:getCC(1).uuid, 1)
    end,
  },

  {
    name = 'pb val drift round-trips signed val into oldVal/newVal',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'pb', chan = 1, val = 2048 } },
        sidecars = { { ppq = 0, uuid = 2, msgType = 'pb', chan = 1, val = -4096 } },
      })
      local _, byUuid, evts = load(take)
      t.eq(#evts, 1)
      t.eq(byUuid[2].kind, 'valueRebound')
      t.eq(byUuid[2].oldVal, -4096)
      t.eq(byUuid[2].newVal,  2048)
    end,
  },

  {
    name = 'two sidecars same partKey, one val-differing cc → first binds, second orphans',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 90 } },
        sidecars = {
          { ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 0, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[1].kind, 'valueRebound')
      t.eq(byUuid[2].kind, 'orphaned')
    end,
  },

  -- ---------- Stage 3: consensus offset ----------

  {
    name = 'two sidecars + two ccs at uniform +20 offset → consensus binds both',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0  },
          { ppq = 120, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = {
          { ppq = 0,   uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
      })
      local mm, _, evts = load(take)
      t.eq(#evts, 2)
      for _, e in ipairs(evts) do
        t.eq(e.kind, 'consensusRebound')
        t.eq(e.offset, 20)
      end
      local uuids = {}
      for _, c in mm:ccs() do uuids[c.ppq] = c.uuid end
      t.deepEq(uuids, { [20] = 1, [120] = 2 })
    end,
  },

  {
    name = "consensusRebound payload reports the bound cc's ppq + offset",
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = -10, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          { ppq =  90, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0  },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[1].ppq, -10)
      t.eq(byUuid[2].ppq,  90)
      t.eq(byUuid[1].offset, -10)
      t.eq(byUuid[2].offset, -10)
    end,
  },

  {
    name = 'three uniformly-drifted sidecars in one bucket bind despite cross-pair noise',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 120, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 220, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
      })
      local _, _, evts = load(take)
      t.eq(#evts, 3)
      for _, e in ipairs(evts) do
        t.eq(e.kind, 'consensusRebound')
        t.eq(e.offset, 20)
      end
    end,
  },

  {
    name = 'tied top vote-getters drop through stage 3, fall to stage 4 (ambiguous)',
    run = function()
      -- 4 sidecars, 4 ccs: two at +10, two at +20. Each sidecar votes for both
      -- offsets → tie. Stage 4 sees every sidecar with all 4 ccs as candidates.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =  10, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 110, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 220, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 320, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 300, uuid = 4, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
      })
      local mm, _, evts = load(take)
      t.eq(#evts, 4)
      for _, e in ipairs(evts) do t.eq(e.kind, 'ambiguous') end
      for _, c in mm:ccs() do t.eq(c.uuid, nil, 'no cc binds when all ambiguous') end
    end,
  },

  -- ---------- Stage 4: per-orphan fallback ----------

  {
    name = 'no candidates → orphaned (no bind)',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = {},
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
      })
      local mm, byUuid, evts = load(take)
      t.eq(#evts, 1)
      local e = byUuid[1]
      t.eq(e.kind, 'orphaned')
      t.eq(e.lastPpq, 100)
      t.eq(e.chan, 1)
      t.eq(e.msgType, 'cc')
      t.eq(e.cc, 7)
      t.eq(e.ppq, nil, 'orphans use lastPpq, never ppq')
      t.eq(next(ccsByLoc(mm)), nil, 'no ccs')
    end,
  },

  {
    name = "one candidate at drifted ppq → guessedRebound binds at the cc's ppq",
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 130, msgType = 'cc', chan = 1, cc = 7, val = 99 } },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
      })
      local mm, byUuid, evts = load(take)
      t.eq(#evts, 1)
      local e = byUuid[1]
      t.eq(e.kind, 'guessedRebound')
      t.eq(e.ppq, 130)
      t.eq(e.cc, 7)
      t.eq(mm:getCC(1).uuid, 1)
    end,
  },

  {
    name = 'two candidates → ambiguous, no bind, candidatePpqs reported',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =  50, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          { ppq = 150, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
      })
      local mm, byUuid, evts = load(take)
      t.eq(#evts, 1)
      local e = byUuid[1]
      t.eq(e.kind, 'ambiguous')
      t.deepEq(e.candidatePpqs, { 50, 150 })
      for _, c in mm:ccs() do t.eq(c.uuid, nil) end
    end,
  },

  {
    name = 'pa orphan reports pitch (not cc)',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = {},
        sidecars = { { ppq = 100, uuid = 9, msgType = 'pa', chan = 5, pitch = 60, val = 100 } },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[9].pitch, 60)
      t.eq(byUuid[9].cc, nil)
    end,
  },

  {
    name = 'two sidecars, one cc same bucket → first guesses, second orphans',
    run = function()
      -- Stage 3: 2 sidecars, 1 cc; offsets +50 and -50 each get 1 vote → tie
      -- below threshold. Stage 4: first sidecar guesses; second sees zero
      -- candidates → orphaned.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 50, msgType = 'cc', chan = 1, cc = 7, val = 0 } },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7, val = 0 },
        },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[1].kind, 'guessedRebound')
      t.eq(byUuid[2].kind, 'orphaned')
    end,
  },

  -- ---------- Bucket isolation ----------

  {
    name = 'mismatched chan: separate buckets → orphaned + unbound cc',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 2, cc = 7, val = 0 } },
        sidecars = { { ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 } },
      })
      local mm, _, evts = load(take)
      t.eq(#evts, 1)
      t.eq(evts[1].kind, 'orphaned')
      t.eq(mm:getCC(1).uuid, nil)
    end,
  },

  {
    name = 'mismatched msgType: separate buckets (cc vs pb)',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 1, cc = 0, val = 0 } },
        sidecars = { { ppq = 0, uuid = 1, msgType = 'pb', chan = 1, val = 0 } },
      })
      local mm, _, evts = load(take)
      t.eq(#evts, 1)
      t.eq(evts[1].kind, 'orphaned')
      t.eq(mm:getCC(1).uuid, nil)
    end,
  },

  {
    name = 'mismatched cc#: separate buckets',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 1, cc = 11, val = 50 } },
        sidecars = { { ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0  } },
      })
      local _, _, evts = load(take)
      t.eq(#evts, 1)
      t.eq(evts[1].kind, 'orphaned')
    end,
  },

  {
    name = 'cc with no sidecars stays uuid-less, no event',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 0 } },
        sidecars = {},
      })
      local mm, _, evts = load(take)
      t.deepEq(evts, {})
      t.eq(mm:getCC(1).uuid, nil)
    end,
  },

  {
    name = 'separate (chan, cc#) buckets resolve independently',
    run = function()
      -- chan=1 cc=7: 2 sidecars + 2 ccs at +20 → consensus.
      -- chan=1 cc=11: 1 sidecar + 1 cc at -5 → stage 4 → guessedRebound.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =  20, msgType = 'cc', chan = 1, cc = 7,  val = 0  },
          { ppq = 120, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          { ppq =  45, msgType = 'cc', chan = 1, cc = 11, val = 30 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 0  },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          { ppq =  50, uuid = 3, msgType = 'cc', chan = 1, cc = 11, val = 30 },
        },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[1].kind, 'consensusRebound')
      t.eq(byUuid[2].kind, 'consensusRebound')
      t.eq(byUuid[3].kind, 'guessedRebound')
    end,
  },

  {
    name = 'cross-msgType events live in different buckets — stage 4 each',
    run = function()
      -- cc + pb at the same chan are different buckets: 1 sidecar + 1 cc each
      -- → guessedRebound apiece.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =  20, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 120, msgType = 'pb', chan = 1,         val = 0 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 0 },
          { ppq = 100, uuid = 2, msgType = 'pb', chan = 1,         val = 0 },
        },
      })
      local _, _, evts = load(take)
      t.eq(#evts, 2)
      for _, e in ipairs(evts) do t.eq(e.kind, 'guessedRebound') end
    end,
  },

  -- ---------- Mixed end-to-end ----------

  {
    name = 'mixed: silent + valueRebound + consensus + orphan in one load',
    run = function()
      -- Bucket cc=7 chan=1: sc1 exact-matches cc1 (silent); sc2 & sc3 + ccs 2
      -- & 3 drift +30 (consensus). Bucket cc=11 chan=1: sc4 same ppq, val
      -- differs (valueRebound). Bucket cc=20 chan=1: sc5, no ccs (orphaned).
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =   0, msgType = 'cc', chan = 1, cc = 7,  val = 10 },
          { ppq = 130, msgType = 'cc', chan = 1, cc = 7,  val = 20 },
          { ppq = 230, msgType = 'cc', chan = 1, cc = 7,  val = 30 },
          { ppq = 400, msgType = 'cc', chan = 1, cc = 11, val = 77 },
        },
        sidecars = {
          { ppq =   0, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 10 },
          { ppq = 100, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 20 },
          { ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 7,  val = 30 },
          { ppq = 400, uuid = 4, msgType = 'cc', chan = 1, cc = 11, val = 50 },
          { ppq = 500, uuid = 5, msgType = 'cc', chan = 1, cc = 20, val = 99 },
        },
      })
      local _, byUuid = load(take)
      t.eq(byUuid[1], nil, 'silent rebind has no event')
      t.eq(byUuid[2].kind, 'consensusRebound')
      t.eq(byUuid[3].kind, 'consensusRebound')
      t.eq(byUuid[4].kind, 'valueRebound')
      t.eq(byUuid[5].kind, 'orphaned')
    end,
  },
}
