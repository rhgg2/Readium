-- Multi-deleteCC in one mm:modify must resolve sidecar idxs against the
-- live sysex array, not against uuidIdx values stamped before the deletes
-- started shifting things. The latter goes wrong whenever a sidecar is
-- inserted mid-fn (e.g. assignCC stamping metadata on a previously-plain
-- cc) and a subsequent delete shifts down a sidecar idx that another
-- pending delete had already cached.
--
-- Reproduces the symptom the user hit during swing-slider drag under
-- microtuning: pbs reappearing as "real" because their fake-flag-bearing
-- sidecars were collateral-damaged.

local t = require('support')
_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')
local realMM = require('realMidiManager')()

local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

local function packCc(c)
  if c.msgType == 'pb' then
    local raw = (c.val or 0) + 8192
    return CHANMSG.pb, raw & 0x7F, (raw >> 7) & 0x7F
  end
  return CHANMSG[c.msgType], c.cc or c.pitch or 0, c.val or 0
end

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-deletecc-sidecar'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

local function seed(take, reaper, spec)
  local ccs, texts = {}, {}
  for _, c in ipairs(spec.ccs or {}) do
    local chanmsg, msg2, msg3 = packCc(c)
    ccs[#ccs+1] = { ppq = c.ppq, chanmsg = chanmsg, chan = (c.chan or 1) - 1,
                    msg2 = msg2, msg3 = msg3 }
  end
  for _, sc in ipairs(spec.sidecars or {}) do
    texts[#texts+1] = {
      ppq = sc.ppq, eventtype = -1,
      msg = t.encodeSidecar{ uuid = sc.uuid, msgType = sc.msgType, chan = sc.chan,
                             cc = sc.cc, pitch = sc.pitch, val = sc.val },
    }
  end
  reaper:seedMidi(take, { ccs = ccs, texts = texts })
end

return {
  {
    name = 'multi-deleteCC after mid-fn metadata stamp leaves unrelated sidecar intact',
    run = function()
      -- Setup: 5 ccs sorted by ppq.
      --   cc_A (ppq=50)  — plain (no sidecar)
      --   cc_E (ppq=75)  — plain (no sidecar)
      --   cc_B (ppq=100) — sidecar uuid=22
      --   cc_C (ppq=200) — sidecar uuid=33
      --   cc_D (ppq=300) — sidecar uuid=44
      -- After load, uuidIdxs are: 22→0, 33→1, 44→2 (sorted by ppq).
      --
      -- In ONE modify:
      --   1. assignCC(loc_A, fake=true) — stamps cc_A; sidecar appended at uuidIdx=3.
      --   2. assignCC(loc_E, fake=true) — stamps cc_E; sidecar appended at uuidIdx=4.
      --   3. deleteCC(loc_B) — deletes scB at uuidIdx=0; cc_C/D/A/E sidecar idxs all shift down by 1.
      --   4. deleteCC(loc_A) — uses cc_A's stale stored uuidIdx=3.
      --
      -- Stale-but-in-bounds: stale value 3 now points to scE (which shifted from idx=4 to 3).
      -- Without the fix, scE is wrongly deleted, and on reload cc_E loses its uuid + fake flag.
      local take, reaper = freshTake()
      seed(take, reaper, {
        ccs = {
          { ppq =  50, msgType = 'cc', chan = 1, cc = 7, val = 10 },  -- A: no sidecar
          { ppq =  75, msgType = 'cc', chan = 1, cc = 7, val = 20 },  -- E: no sidecar
          { ppq = 100, msgType = 'cc', chan = 1, cc = 7, val = 30 },  -- B
          { ppq = 200, msgType = 'cc', chan = 1, cc = 7, val = 40 },  -- C
          { ppq = 300, msgType = 'cc', chan = 1, cc = 7, val = 50 },  -- D
        },
        sidecars = {
          { ppq = 100, uuid = 22, msgType = 'cc', chan = 1, cc = 7, val = 30 },
          { ppq = 200, uuid = 33, msgType = 'cc', chan = 1, cc = 7, val = 40 },
          { ppq = 300, uuid = 44, msgType = 'cc', chan = 1, cc = 7, val = 50 },
        },
      })

      local mm = realMM(nil)
      mm:load(take)

      -- Find locs by ppq.
      local locByppq = {}
      for loc, c in mm:ccs() do locByppq[c.ppq] = loc end
      local locA, locE, locB = locByppq[50], locByppq[75], locByppq[100]

      mm:modify(function()
        mm:assignCC(locA, { tag = 'fromA' })  -- distinguishable per-cc tag
        mm:assignCC(locE, { tag = 'fromE' })
        mm:deleteCC(locB)
        mm:deleteCC(locA)
      end)

      -- Find the surviving cc_E (ppq=75, val=20) and verify its sidecar/metadata
      -- survived the multi-delete. Without the fix, scE is collateral-deleted
      -- (cc_A's stale uuidIdx points at scE after scB's delete shifts texts down);
      -- on reload, the orphan scA gets stage-4-rebound to the now-uuid-less cc_E,
      -- leaving cc_E carrying cc_A's metadata (tag='fromA') instead of its own.
      local ccE
      for _, c in mm:ccs() do
        if c.ppq == 75 then ccE = c end
      end
      t.truthy(ccE, 'cc_E survives the modify')
      t.eq(ccE.tag, 'fromE', "cc_E retains its own metadata, not cc_A's")

      -- Sanity: cc_C and cc_D still bound to their original sidecars.
      local ccC, ccD
      for _, c in mm:ccs() do
        if c.ppq == 200 then ccC = c
        elseif c.ppq == 300 then ccD = c end
      end
      t.eq(ccC.uuid, 33, 'cc_C still bound to its original sidecar')
      t.eq(ccD.uuid, 44, 'cc_D still bound to its original sidecar')
    end,
  },
}
