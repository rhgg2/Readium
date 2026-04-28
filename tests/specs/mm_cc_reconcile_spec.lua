-- Integration spec: real midiManager + midi-extended fakeReaper, exercising
-- the load-time sidecar reconciliation pipeline end-to-end. Per-tier logic
-- is pinned in sidecar_tier{1,2,3,4}_spec; this spec covers the wiring:
-- bind → cc.uuid attachment, sidecar rewrite/delete, ccsReconciled signal,
-- and post-load index hygiene (cc.uuidIdx still resolves a sidecar after
-- mid-load deletions).

local t = require('support')

_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')
local realMM = require('realMidiManager')()

local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

-- Build a fresh take + reaper. Returns (take, reaper).
local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-cc-reconcile'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

-- Cc-shaped record → REAPER's (chanmsg, msg2, msg3) packing. Mirrors
-- midiManager.lua's reconstruct(). chan stays 1-indexed here; convert at the
-- seed-call site.
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

-- Spec for an event-row plus optional metadata. Sidecar specs that include
-- a `metadata` field also get an rdm_<uuid> ext-data entry. uuids must be
-- explicit and globally unique within the take.
local function seed(take, reaper, spec)
  local notes, ccs, texts = {}, {}, {}
  for _, n in ipairs(spec.notes or {}) do
    notes[#notes+1] = { ppq = n.ppq, endppq = n.endppq, chan = (n.chan or 1) - 1,
                        pitch = n.pitch, vel = n.vel, muted = n.muted }
  end
  for _, c in ipairs(spec.ccs or {}) do
    local chanmsg, msg2, msg3 = packCc(c)
    ccs[#ccs+1] = { ppq = c.ppq, chanmsg = chanmsg, chan = (c.chan or 1) - 1,
                    msg2 = msg2, msg3 = msg3, muted = c.muted }
  end
  for _, sc in ipairs(spec.sidecars or {}) do
    local body = t.encodeSidecar{ uuid = sc.uuid, msgType = sc.msgType, chan = sc.chan,
                                  cc = sc.cc, pitch = sc.pitch, val = sc.val }
    texts[#texts+1] = { ppq = sc.ppq, eventtype = -1, msg = body }
  end
  for _, n in ipairs(spec.notations or {}) do
    texts[#texts+1] = { ppq = n.ppq, eventtype = 15, msg = n.msg }
  end
  reaper:seedMidi(take, { notes = notes, ccs = ccs, texts = texts })

  -- Lay down rdm_<uuid> ext-data and rdm_keys for any sidecar carrying metadata.
  local keys = {}
  local function uuidTxt(u)
    local s, n = '', u
    if n == 0 then return '0' end
    local b36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    while n > 0 do s = b36:sub((n % 36) + 1, (n % 36) + 1) .. s; n = n // 36 end
    return s
  end
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

-- Subscribe to all signals on a fresh mm and return the load-time payloads
-- keyed by signal name. Construction calls mm:load() internally, so signals
-- fire during mm = realMM(take). We use a thunk to attach subscribers right
-- before construction triggers them.
local function loadWithCapture(take)
  local captured = { reload = false }
  local mm = realMM(nil)
  mm:subscribe('reload',         function()      captured.reload         = true end)
  mm:subscribe('takeSwapped',    function()      captured.takeSwapped    = true end)
  mm:subscribe('notesDeduped',   function(d)     captured.notesDeduped   = d.events end)
  mm:subscribe('uuidsReassigned',function(d)     captured.uuidsReassigned= d.events end)
  mm:subscribe('ccsReconciled',  function(d)     captured.ccsReconciled  = d.events end)
  mm:load(take)
  return mm, captured
end

return {
  {
    name = 'tier 1: matching sidecar+cc binds silently, no ccsReconciled fire',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 0, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        sidecars = { { ppq = 0, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { foo = 'bar' } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(captured.ccsReconciled, nil, 'no signal on tier-1 silent bind')
      local cc = mm:getCC(1)
      t.eq(cc.uuid, 1, 'cc bound to sidecar uuid')
      t.eq(cc.foo, 'bar', 'metadata merged from rdm_<uuid>')
    end,
  },

  {
    name = 'tier 2: value drift produces valueRebound, sidecar body rewritten',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 80 } },
        sidecars = { { ppq = 100, uuid = 7, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { label = 'kept' } } },
      })
      local mm, captured = loadWithCapture(take)
      t.truthy(captured.ccsReconciled, 'signal fires')
      t.eq(#captured.ccsReconciled, 1)
      local e = captured.ccsReconciled[1]
      t.eq(e.kind, 'valueRebound')
      t.eq(e.uuid, 7); t.eq(e.oldVal, 64); t.eq(e.newVal, 80)
      t.eq(mm:getCC(1).label, 'kept', 'metadata preserved across val drift')

      -- Reload should now be silent (sidecar body matches cc).
      local _, again = loadWithCapture(take)
      t.eq(again.ccsReconciled, nil, 'rewritten sidecar makes next load tier-1 clean')
    end,
  },

  {
    name = 'tier 3: uniform group drag, consensus rebinds all',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 20,  msgType = 'cc', chan = 1, cc = 7, val = 0  },
          { ppq = 120, msgType = 'cc', chan = 1, cc = 7, val = 64 },
          { ppq = 220, msgType = 'cc', chan = 1, cc = 7, val = 99 },
        },
        sidecars = {
          { ppq = 0,   uuid = 11, msgType = 'cc', chan = 1, cc = 7, val = 0,  metadata = { tag = 'a' } },
          { ppq = 100, uuid = 12, msgType = 'cc', chan = 1, cc = 7, val = 64, metadata = { tag = 'b' } },
          { ppq = 200, uuid = 13, msgType = 'cc', chan = 1, cc = 7, val = 99, metadata = { tag = 'c' } },
        },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsReconciled, 3)
      for _, e in ipairs(captured.ccsReconciled) do
        t.eq(e.kind, 'consensusRebound')
        t.eq(e.offset, 20)
      end
      local tags = {}
      for loc, c in mm:ccs() do tags[loc] = c.tag end
      t.deepEq(tags, { 'a', 'b', 'c' })

      -- Next load should be silent.
      local _, again = loadWithCapture(take)
      t.eq(again.ccsReconciled, nil, 'consensus-bound sidecars rewritten, next load silent')
    end,
  },

  {
    name = 'tier 4: orphan deletes sidecar, drops metadata, fires orphaned',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = {},  -- no candidate at all
        sidecars = { { ppq = 100, uuid = 42, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { gone = 1 } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsReconciled, 1)
      t.eq(captured.ccsReconciled[1].kind, 'orphaned')
      t.eq(captured.ccsReconciled[1].lastPpq, 100)

      -- Sidecar gone from the take.
      local _, _, _, txtCount = reaper.MIDI_CountEvts(take)
      t.eq(txtCount, 0, 'orphan sidecar removed')

      -- Ext-data slot purged by saveMetadata's stale-key sweep.
      local _, keys = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_keys', '', false)
      t.eq(keys, '', 'rdm_keys cleared')
    end,
  },

  {
    name = 'tier 4: single candidate yields guessedRebound and binds',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 130, msgType = 'cc', chan = 1, cc = 7, val = 99 } },
        sidecars = { { ppq = 100, uuid = 5, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { keep = true } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsReconciled, 1)
      t.eq(captured.ccsReconciled[1].kind, 'guessedRebound')
      t.eq(captured.ccsReconciled[1].ppq, 130)
      t.eq(mm:getCC(1).keep, true)
    end,
  },

  {
    name = 'tier 4: multi-candidate is ambiguous, sidecar deleted, metadata dropped',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq = 80,  msgType = 'cc', chan = 1, cc = 7, val = 64 },
          { ppq = 130, msgType = 'cc', chan = 1, cc = 7, val = 64 },
        },
        sidecars = { { ppq = 100, uuid = 9, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { drop = 1 } } },
      })
      local mm, captured = loadWithCapture(take)
      t.eq(#captured.ccsReconciled, 1)
      local e = captured.ccsReconciled[1]
      t.eq(e.kind, 'ambiguous')
      t.deepEq(e.candidatePpqs, { 80, 130 })
      for _, c in mm:ccs() do t.eq(c.uuid, nil, 'no cc takes the orphaned uuid') end
      local _, _, _, txtCount = reaper.MIDI_CountEvts(take)
      t.eq(txtCount, 0, 'ambiguous sidecar removed')
    end,
  },

  {
    name = 'cc.uuidIdx survives mid-load orphan deletions and points at the right sysex',
    run = function()
      -- Two stamped ccs: one tier-1 binds (stays), one orphans (sidecar gets
      -- deleted at idx 0 — the surviving sidecar's idx in REAPER shifts
      -- down). After load, mutating the surviving cc must rewrite the right
      -- sidecar — which only works if cc.uuidIdx tracked the shift.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = { { ppq = 200, msgType = 'cc', chan = 1, cc = 7, val = 64 } },
        sidecars = {
          { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 11, val = 0,
            metadata = { gone = true } },             -- orphaned (no cc11 candidate)
          { ppq = 200, uuid = 2, msgType = 'cc', chan = 1, cc = 7,  val = 64,
            metadata = { kept = true } },             -- tier 1
        },
      })
      local mm = loadWithCapture(take)
      local cc = mm:getCC(1)
      t.eq(cc.uuid, 2)
      t.eq(cc.kept, true)

      -- Structural assignCC rewrites the sidecar via cc.uuidIdx. If that
      -- idx is stale (failure to fix up after orphan deletion), this would
      -- mutate some unrelated sysex or fail.
      mm:modify(function() mm:assignCC(1, { val = 100 }) end)
      local m = reaper:dumpMidi(take)
      t.eq(#m.texts, 1, 'one sidecar survives')
      local decoded = t.decodeSidecar(m.texts[1].msg)
      t.eq(decoded.uuid, 2, 'right sidecar')
      t.eq(decoded.val, 100, 'sidecar body tracks the new cc val')
    end,
  },

  {
    name = 'reconcile fires before reload (signal ordering)',
    run = function()
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs      = { { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 80 } },
        sidecars = { { ppq = 100, uuid = 1, msgType = 'cc', chan = 1, cc = 7, val = 64,
                       metadata = { foo = 'x' } } },
      })
      local mm = realMM(nil)
      local order = {}
      mm:subscribe('ccsReconciled', function() order[#order+1] = 'reconcile' end)
      mm:subscribe('reload',        function() order[#order+1] = 'reload'    end)
      mm:load(take)
      t.deepEq(order, { 'reconcile', 'reload' })
    end,
  },
}
