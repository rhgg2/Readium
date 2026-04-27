-- Integration spec: real midiManager + midi-extended fakeReaper, exercising
-- the load-time cc dedup pass. Pins the sidecar-aware survivor heuristic
-- (prefer a cc whose ppq+val matches a sidecar — i.e. a stage-1 reconcile
-- candidate — else highest loc), the ccsDeduped signal payload, post-dedup
-- index hygiene (cc.uuidIdx still resolves a sidecar after mid-load
-- deletions), and ordering relative to ccsReconciled/reload.

local t = require('support')

_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')
local realMM, realSR = require('realMidiManager')()

local sr      = realSR()
local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-cc-dedup'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

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

local function uuidTxt(u)
  if u == 0 then return '0' end
  local s, n, b36 = '', u, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  while n > 0 do s = b36:sub((n % 36) + 1, (n % 36) + 1) .. s; n = n // 36 end
  return s
end

local function seed(take, reaper, spec)
  local ccs, texts = {}, {}
  for _, c in ipairs(spec.ccs or {}) do
    local chanmsg, msg2, msg3 = packCc(c)
    ccs[#ccs+1] = { ppq = c.ppq, chanmsg = chanmsg, chan = (c.chan or 1) - 1,
                    msg2 = msg2, msg3 = msg3 }
  end
  for _, sc in ipairs(spec.sidecars or {}) do
    local body = sr:encode{ uuid = sc.uuid, msgType = sc.msgType, chan = sc.chan,
                            cc = sc.cc, pitch = sc.pitch, val = sc.val }
    texts[#texts+1] = { ppq = sc.ppq, eventtype = -1, msg = body }
  end
  reaper:seedMidi(take, { ccs = ccs, texts = texts })

  local keys = {}
  for _, sc in ipairs(spec.sidecars or {}) do
    if sc.metadata then
      local txt = uuidTxt(sc.uuid)
      keys[#keys+1] = txt
      reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_' .. txt,
        util.serialise(sc.metadata, {}), true)
    end
  end
  if #keys > 0 then
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', table.concat(keys, ','), true)
  end
end

local function loadWithCapture(take)
  local captured = {}
  local mm = realMM(nil)
  mm:subscribe('reload',         function()  captured.reload = true end)
  mm:subscribe('ccsReconciled',  function(d) captured.ccsReconciled = d.events end)
  mm:subscribe('ccsDeduped',     function(d) captured.ccsDeduped    = d.events end)
  mm:load(take)
  return mm, captured
end

local function sidecarBodies(reaper, take)
  local out = {}
  for _, e in ipairs(reaper:dumpMidi(take).texts) do
    if e.msg:sub(1, 4) == '\x7D\x52\x44\x4D' then out[#out+1] = sr:decode(e.msg) end
  end
  return out
end

return {
  {
    name = 'sidecar-matched group: surviving cc picks up the sidecar metadata',
    run = function()
      -- Both dups share val=64 with the sidecar, so both are stage-1
      -- candidates; highest loc wins, then reconcile binds it.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { tag = 'kept' } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)
      local e = captured.ccsDeduped[1]
      t.eq(e.ppq, 100); t.eq(e.chan, 1); t.eq(e.msgType, 'cc')
      t.eq(e.cc, 7);    t.eq(e.pitch, nil)
      t.eq(e.droppedCount, 1)
      t.eq(e.keptHadUuid, nil, 'keptHadUuid retired with the post-reconcile dedup')

      local survivor; for _, c in mm:ccs() do survivor = c end
      t.eq(survivor.uuid, 1)
      t.eq(survivor.tag,  'kept')
      t.eq(#reaper:dumpMidi(take).ccs, 1, 'one cc remains in take')
    end,
  },

  {
    name = 'no sidecar in group: highest-loc cc wins',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 50, msgType = 'cc', chan = 1, cc = 7, val = 10 },
          { ppq = 50, msgType = 'cc', chan = 1, cc = 7, val = 90 },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)
      t.eq(captured.ccsDeduped[1].droppedCount, 1)

      local survivor; for _, c in mm:ccs() do survivor = c end
      t.eq(survivor.val, 90, 'latest (second-seeded) cc wins')
    end,
  },

  {
    name = 'sidecar val matches one dup: that dup wins over a higher-loc non-match',
    run = function()
      -- cc[1] (val=42) is the stage-1 candidate; cc[2] (val=99) is not.
      -- Without the candidate-preference, highest-loc would have kept the
      -- wrong cc and forced a value-rebind onto something the user didn't
      -- intend.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 42 },
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 99 },
        },
        sidecars = { { ppq = 100, uuid = 5, msgType = 'cc', chan = 1, cc = 7, val = 42,
                       metadata = { tag = 'kept' } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)

      local survivor; for _, c in mm:ccs() do survivor = c end
      t.eq(survivor.val, 42, 'val=42 cc preferred — matches the sidecar')
      t.eq(survivor.uuid, 5)
      t.eq(survivor.tag, 'kept')
      -- Reconciled silently (stage-1) — no events.
      t.eq(captured.ccsReconciled, nil, 'silent stage-1 bind, no reconcile event')
    end,
  },

  {
    name = 'sidecar val matches none: fall back to highest-loc, sidecar value-rebinds',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 42 },
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 99 },
        },
        sidecars = { { ppq = 100, uuid = 6, msgType = 'cc', chan = 1, cc = 7, val = 7,
                       metadata = { tag = 'drift' } } },
      })
      local mm, captured = loadWithCapture(take)
      local survivor; for _, c in mm:ccs() do survivor = c end
      t.eq(survivor.val, 99, 'no candidate matches → highest-loc fallback')
      t.eq(survivor.uuid, 6, 'sidecar value-rebound onto the survivor')

      t.eq(#captured.ccsReconciled, 1)
      local rec = captured.ccsReconciled[1]
      t.eq(rec.kind, 'valueRebound')
      t.eq(rec.oldVal, 7); t.eq(rec.newVal, 99)
    end,
  },

  {
    name = 'two sidecars match different dups: one binds, the other orphans cleanly',
    run = function()
      -- Old code: reconcile binds both stage-1 then dedup tosses one
      -- silently with keptHadUuid=true. New code: dedup leaves one cc, the
      -- "extra" sidecar surfaces as a typed orphan event from reconcile.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 200, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          { ppq = 200, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = {
          { ppq = 200, uuid = 11, msgType = 'cc', chan = 1, cc = 7, val = 64, metadata = { v = 'a' } },
          { ppq = 200, uuid = 12, msgType = 'cc', chan = 1, cc = 7, val = 64, metadata = { v = 'b' } },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)

      local survivor; for _, c in mm:ccs() do survivor = c end
      t.eq(#reaper:dumpMidi(take).ccs, 1, 'one cc remains in take')
      t.truthy(survivor.uuid == 11 or survivor.uuid == 12,
               'either sidecar may bind first — both are stage-1 candidates')
      local loserUuid = survivor.uuid == 11 and 12 or 11

      -- The sidecar that didn't get to bind surfaces as orphaned, not as a
      -- silent dedup-loss.
      t.truthy(captured.ccsReconciled, 'reconcile event present for the orphan')
      local orphanSeen = false
      for _, e in ipairs(captured.ccsReconciled) do
        if e.kind == 'orphaned' and e.uuid == loserUuid then orphanSeen = true end
      end
      t.truthy(orphanSeen, 'loser sidecar reported as orphaned via reconcile')

      local bodies = sidecarBodies(reaper, take)
      t.eq(#bodies, 1, 'loser sidecar deleted by reconcile orphan path')
      t.eq(bodies[1].uuid, survivor.uuid)

      local _, keys = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', '', false)
      t.eq(keys, uuidTxt(survivor.uuid), 'only winner uuid remains in rdm_keys')
      local _, loserSlot = reaper.GetSetMediaItemTakeInfo_String(
        take, 'P_EXT:rdm_' .. uuidTxt(loserUuid), '', false)
      t.eq(loserSlot, '', 'loser rdm_<uuid> slot purged')
    end,
  },

  {
    name = 'three-in-group: droppedCount = 2, only winner remains',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 1 },
          { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 2 },
          { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 3 },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)
      t.eq(captured.ccsDeduped[1].droppedCount, 2)
      local n = 0; for _ in mm:ccs() do n = n + 1 end
      t.eq(n, 1)
    end,
  },

  {
    name = 'multiple groups in one load fire one event each',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 0,   msgType = 'cc', chan = 1, cc = 7,  val = 1 },
          { ppq = 0,   msgType = 'cc', chan = 1, cc = 7,  val = 2 },
          { ppq = 100, msgType = 'cc', chan = 2, cc = 11, val = 30 },
          { ppq = 100, msgType = 'cc', chan = 2, cc = 11, val = 40 },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 2)
      local n = 0; for _ in mm:ccs() do n = n + 1 end
      t.eq(n, 2)
    end,
  },

  {
    name = 'no false dedup across (chan), (cc#), or (msgType) boundaries',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 0, msgType = 'cc', chan = 1, cc = 7,    val = 1 },
          { ppq = 0, msgType = 'cc', chan = 2, cc = 7,    val = 1 },  -- different chan
          { ppq = 0, msgType = 'cc', chan = 1, cc = 11,   val = 1 },  -- different cc#
          { ppq = 0, msgType = 'pa', chan = 1, pitch = 7, val = 1 },  -- different msgType (pa)
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(captured.ccsDeduped, nil, 'no dup groups → no signal')
      local n = 0; for _ in mm:ccs() do n = n + 1 end
      t.eq(n, 4)
    end,
  },

  {
    name = 'pa dedup: id is pitch, not cc',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 0, msgType = 'pa', chan = 1, pitch = 60, val = 100 },
          { ppq = 0, msgType = 'pa', chan = 1, pitch = 60, val = 110 },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)
      local e = captured.ccsDeduped[1]
      t.eq(e.msgType, 'pa'); t.eq(e.pitch, 60); t.eq(e.cc, nil)
    end,
  },

  {
    name = 'pb dedup: channel-wide id (id=0) collapses dups',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 0, msgType = 'pb', chan = 1, val = -100 },
          { ppq = 0, msgType = 'pb', chan = 1, val =  500 },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsDeduped, 1)
      t.eq(captured.ccsDeduped[1].msgType, 'pb')
    end,
  },

  {
    name = 'signal ordering: ccsDeduped → ccsReconciled → reload',
    run = function()
      local take, reaper = freshTake()
      -- One tier-2 valueRebound + one plain dup group, both in one load.
      seed(take, reaper, {
        ccs = {
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7,  val = 80 },
          { ppq = 200, msgType = 'cc', chan = 1, cc = 11, val = 1 },
          { ppq = 200, msgType = 'cc', chan = 1, cc = 11, val = 2 },
        },
        sidecars = { { ppq = 100, uuid = 7, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { kept = true } } },
      })
      local mm = realMM(nil)
      local order = {}
      mm:subscribe('ccsReconciled', function() order[#order+1] = 'reconcile' end)
      mm:subscribe('ccsDeduped',    function() order[#order+1] = 'dedup'     end)
      mm:subscribe('reload',        function() order[#order+1] = 'reload'    end)
      mm:load(take)
      t.deepEq(order, { 'dedup', 'reconcile', 'reload' })
    end,
  },

  {
    name = 'survivor cc.uuidIdx tracks sidecar across dedup deletions',
    run = function()
      -- Two dup groups: stamped+plain at ppq=100 (stamped survives) and
      -- two stamped at ppq=200 (latest survives, loser sidecar gone). Then
      -- mutate the survivor at ppq=100 — its sidecar body must rewrite via
      -- cc.uuidIdx, which is only valid if dedup repaired idxs after the
      -- mid-load deletes.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7,  val = 64 },
          { ppq = 200, msgType = 'cc', chan = 1, cc = 11, val = 50 },
          { ppq = 200, msgType = 'cc', chan = 1, cc = 11, val = 50 },
        },
        sidecars = {
          { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7,  val = 64, metadata = { tag = 'a' } },
          { ppq = 200, uuid = 2, msgType = 'cc', chan = 1, cc = 11, val = 50, metadata = { tag = 'b' } },
          { ppq = 200, uuid = 3, msgType = 'cc', chan = 1, cc = 11, val = 50, metadata = { tag = 'c' } },
        },
      })
      local mm = loadWithCapture(take)
      mm:modify(function()
        for loc, c in mm:ccs() do
          if c.cc == 7 then mm:assignCC(loc, { val = 99 }) end
        end
      end)

      local found
      for _, b in ipairs(sidecarBodies(reaper, take)) do
        if b.cc == 7 then found = b end
      end
      t.truthy(found, 'cc=7 sidecar present')
      t.eq(found.val, 99, 'sidecar body rewritten — cc.uuidIdx still resolved correct sysex')
    end,
  },
}
