-- spike_sidecar.lua
--
-- Verification spike for the cc-sidecar carrier proposed in
-- design/cc-sidecar-spike.md. Run as a ReaScript action.
--
-- Phase A (first run):  exercises ops 1, 5-10, 12 against scratch items,
--                       lays down phase-B probe items, prints partial table.
-- Phase B (second run): re-reads the probe items, asserts ops 2/3/4,
--                       prints op 13 grep-snippet, prints final table.
--
-- Between runs the user must save the project, close REAPER, reopen, and
-- re-run the script. State carries across via reaper ExtState ("rdm_spike").
--
-- The spike adds two scratch tracks ("rdm_spike_scratch", "rdm_spike_probes")
-- and a destination track for op 12 ("rdm_spike_dest"). Phase B deletes them
-- on completion. Run on a scratch project — your work will be wrapped in an
-- undo block but you should not run this on a real session.

local reaper = reaper
local fmt = string.format

----- Carrier under test (see design/cc-sidecar-spike.md)
--
-- We pass the body to MIDI_InsertTextSysexEvt without F0..F7 framing — REAPER
-- frames it internally per the API contract. On disk / on wire the sysex is
-- the full 13 bytes F0 7D 52 44 4D 0B 00 07 40 00 41 42 F7.

local payload = "\x7D\x52\x44\x4D\x0B\x00\x07\x40\x00\x41\x42"   -- 11-byte body, uuid "AB"
local magic   = "\x7D\x52\x44\x4D"                                -- }RDM, filter prefix

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = fmt("%02X", s:byte(i)) end
  return table.concat(t, " ")
end

local results = {}
local function record(op, status, detail)
  results[#results+1] = { op = op, status = status, detail = detail or "" }
  out(fmt("op %-2s  %-4s  %s", tostring(op), status, detail or ""))
end
local function pass(op, d) record(op, "PASS", d) end
local function fail(op, d) record(op, "FAIL", d) end
local function info(op, d) record(op, "INFO", d) end

----- ExtState (phase only)

local NS = "rdm_spike"
local function getPhase()   return reaper.GetExtState(NS, "phase") end
local function setPhase(p)  reaper.SetExtState(NS, "phase", p, false) end
local function clearPhase() reaper.DeleteExtState(NS, "phase", false) end

----- Track / item helpers

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
end

local function ensureTrack(name)
  local tr = findTrack(name)
  if tr then return tr end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

local function deleteTrack(name)
  local tr = findTrack(name)
  if tr then reaper.DeleteTrack(tr) end
end

local function newItem(track, startSec, endSec)
  local item = reaper.CreateNewMIDIItemInProj(track, startSec, endSec, false)
  return item, reaper.GetActiveTake(item)
end

local function clearTrack(track)
  for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    reaper.DeleteTrackMediaItem(track, reaper.GetTrackMediaItem(track, i))
  end
end

local function selectOnly(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
end

----- MIDI helpers

local function insertSidecar(take, ppq, payload)
  reaper.MIDI_DisableSort(take)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, -1, payload)
  reaper.MIDI_Sort(take)
end

local function insertCC(take, ppq, ccnum, val)
  reaper.MIDI_DisableSort(take)
  reaper.MIDI_InsertCC(take, false, false, ppq, 0xB0, 0, ccnum, val)
  reaper.MIDI_Sort(take)
end

local function readSidecars(take)
  local _, _, _, txtCount = reaper.MIDI_CountEvts(take)
  local r = {}
  for i = 0, txtCount - 1 do
    local ok, _, _, ppq, etype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok and msg:find(magic, 1, true) then
      r[#r+1] = { idx = i, ppq = ppq, etype = etype, msg = msg }
    end
  end
  return r
end

local function readCCs(take)
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  local r = {}
  for i = 0, ccCount - 1 do
    local ok, _, _, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if ok then r[#r+1] = { idx = i, ppq = ppq, chanmsg = chanmsg, chan = chan, num = msg2, val = msg3 } end
  end
  return r
end

----- Phase A: ops 1, 5-12

local function op1_immediate_readback(scratch)
  clearTrack(scratch)
  local item, take = newItem(scratch, 0, 4)
  insertSidecar(take, 0,   payload)
  insertSidecar(take, 100, payload)
  local sx = readSidecars(take)
  if #sx ~= 2 then
    fail(1, fmt("expected 2 sidecars, got %d", #sx))
  else
    local byPpq = {}
    for _, e in ipairs(sx) do byPpq[e.ppq] = e end
    local ppqsOk  = byPpq[0] and byPpq[100]
    local bytesOk = ppqsOk and byPpq[0].msg == payload and byPpq[100].msg == payload
    if bytesOk then
      pass(1, fmt("readback = %s; ppqs preserved", hex(sx[1].msg)))
    else
      fail(1, fmt("ppqsOk=%s bytesOk=%s; [%s @ %d] [%s @ %d]",
        tostring(ppqsOk and true or false), tostring(bytesOk and true or false),
        hex(sx[1].msg), sx[1].ppq, hex(sx[2].msg), sx[2].ppq))
    end
  end
  reaper.DeleteTrackMediaItem(scratch, item)
end

local function op5_glue(scratch)
  clearTrack(scratch)
  local itemB, _     = newItem(scratch, 15, 16)  -- empty, on the LEFT (forces ppq translation)
  local itemA, takeA = newItem(scratch, 16, 17)
  insertSidecar(takeA, 0, payload)
  insertCC(takeA, 0, 7, 64)  -- coincident cc to compare ppq translation against

  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(itemA, true)
  reaper.SetMediaItemSelected(itemB, true)
  reaper.Main_OnCommand(40362, 0)  -- Item: Glue items

  -- After glue there's one item starting at 15; find it
  local glued
  for i = 0, reaper.CountTrackMediaItems(scratch) - 1 do
    local it = reaper.GetTrackMediaItem(scratch, i)
    if reaper.GetMediaItemInfo_Value(it, "D_POSITION") < 15.5 then glued = it end
  end
  if not glued then fail(5, "could not locate glued item"); return end

  local gtake = reaper.GetActiveTake(glued)
  local sx, ccs = readSidecars(gtake), readCCs(gtake)
  if #sx ~= 1 then
    fail(5, fmt("expected 1 sidecar in glued item, got %d", #sx))
  elseif sx[1].msg ~= payload then
    fail(5, fmt("byte mismatch: %s", hex(sx[1].msg)))
  elseif #ccs == 0 then
    fail(5, "coincident cc disappeared during glue")
  elseif sx[1].ppq ~= ccs[1].ppq then
    fail(5, fmt("ppq translation diverges from cc: sidecar=%d cc=%d", sx[1].ppq, ccs[1].ppq))
  else
    pass(5, fmt("sidecar+cc co-translated to ppq=%d", sx[1].ppq))
  end
  reaper.DeleteTrackMediaItem(scratch, glued)
end

local function splitSetup(scratch, sidecarSec, splitSec)
  clearTrack(scratch)
  local item, take = newItem(scratch, 16, 18)
  local ppq = math.floor(reaper.MIDI_GetPPQPosFromProjTime(take, 16 + sidecarSec) + 0.5)
  insertSidecar(take, ppq, payload)
  insertCC(take, ppq, 7, 64)
  reaper.SetEditCurPos(16 + splitSec, false, false)
  selectOnly(item)
  reaper.Main_OnCommand(40012, 0)  -- Item: Split items at edit cursor
  -- After split: two items on this track. Identify left/right by position.
  local left, right
  for i = 0, reaper.CountTrackMediaItems(scratch) - 1 do
    local it = reaper.GetTrackMediaItem(scratch, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if pos < 16 + splitSec - 0.001 then left = it
    else right = it end
  end
  return left, right
end

local function op6_split_sidecar_after(scratch)
  -- sidecar at 1.0s relative; split at 0.5s relative → sidecar lands in right half
  local left, right = splitSetup(scratch, 1.0, 0.5)
  if not (left and right) then fail(6, "split did not produce two items"); return end
  local sxR = readSidecars(reaper.GetActiveTake(right))
  local sxL = readSidecars(reaper.GetActiveTake(left))
  if #sxR == 1 and #sxL == 0 then
    pass(6, fmt("sidecar in right half at ppq=%d", sxR[1].ppq))
  else
    fail(6, fmt("expected R=1 L=0, got R=%d L=%d", #sxR, #sxL))
  end
  reaper.DeleteTrackMediaItem(scratch, left)
  reaper.DeleteTrackMediaItem(scratch, right)
end

local function op7_split_sidecar_before(scratch)
  -- sidecar at 0.25s; split at 0.5s → sidecar in left half
  local left, right = splitSetup(scratch, 0.25, 0.5)
  if not (left and right) then fail(7, "split did not produce two items"); return end
  local sxL = readSidecars(reaper.GetActiveTake(left))
  local sxR = readSidecars(reaper.GetActiveTake(right))
  if #sxL == 1 and #sxR == 0 then
    pass(7, fmt("sidecar in left half at ppq=%d", sxL[1].ppq))
  else
    fail(7, fmt("expected L=1 R=0, got L=%d R=%d", #sxL, #sxR))
  end
  reaper.DeleteTrackMediaItem(scratch, left)
  reaper.DeleteTrackMediaItem(scratch, right)
end

local function op8_split_straddle(scratch)
  -- sidecar at exactly the split point. Document where it ends up.
  local left, right = splitSetup(scratch, 0.5, 0.5)
  if not (left and right) then fail(8, "split did not produce two items"); return end
  local sxL = readSidecars(reaper.GetActiveTake(left))
  local sxR = readSidecars(reaper.GetActiveTake(right))
  local where
  if #sxL == 1 and #sxR == 0 then where = "LEFT only"
  elseif #sxL == 0 and #sxR == 1 then where = "RIGHT only"
  elseif #sxL == 1 and #sxR == 1 then where = "DUPLICATED to both"
  else where = fmt("anomalous (L=%d R=%d)", #sxL, #sxR) end
  info(8, fmt("straddle behaviour: %s", where))
  reaper.DeleteTrackMediaItem(scratch, left)
  reaper.DeleteTrackMediaItem(scratch, right)
end

local function op9_duplicate(scratch)
  clearTrack(scratch)
  local item, take = newItem(scratch, 20, 22)
  insertSidecar(take, 0, payload)
  selectOnly(item)
  reaper.Main_OnCommand(41295, 0)  -- Item: Duplicate items
  -- Two items now; both should carry the sidecar.
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(scratch) - 1 do
    items[#items+1] = reaper.GetTrackMediaItem(scratch, i)
  end
  if #items ~= 2 then fail(9, fmt("expected 2 items after dup, got %d", #items)); return end
  local n1 = #readSidecars(reaper.GetActiveTake(items[1]))
  local n2 = #readSidecars(reaper.GetActiveTake(items[2]))
  if n1 == 1 and n2 == 1 then
    pass(9, "both copies carry sidecar (note: shared uuid — flag for design)")
  else
    fail(9, fmt("sidecar counts: %d / %d", n1, n2))
  end
  for _, it in ipairs(items) do reaper.DeleteTrackMediaItem(scratch, it) end
end

local function op10_glue_two_stamped(scratch)
  clearTrack(scratch)
  -- Each item carries its own sidecar with a different uuid suffix.
  local payloadAB = payload
  local payloadCD = "\x7D\x52\x44\x4D\x0B\x00\x07\x40\x00\x43\x44"  -- uuid "CD"
  local itemA, takeA = newItem(scratch, 24, 25)
  insertSidecar(takeA, 0, payloadAB)
  insertCC(takeA, 0, 7, 64)
  local itemB, takeB = newItem(scratch, 25, 26)
  insertSidecar(takeB, 0, payloadCD)
  insertCC(takeB, 0, 7, 96)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(itemA, true)
  reaper.SetMediaItemSelected(itemB, true)
  reaper.Main_OnCommand(40362, 0)  -- glue
  local glued
  for i = 0, reaper.CountTrackMediaItems(scratch) - 1 do
    local it = reaper.GetTrackMediaItem(scratch, i)
    if reaper.GetMediaItemInfo_Value(it, "D_POSITION") < 24.5 then glued = it end
  end
  if not glued then fail(10, "could not locate glued item"); return end
  local sx = readSidecars(reaper.GetActiveTake(glued))
  local ccs = readCCs(reaper.GetActiveTake(glued))
  local seen = {}
  for _, e in ipairs(sx) do seen[e.msg] = e end
  if #sx == 2 and seen[payloadAB] and seen[payloadCD] and #ccs == 2 then
    pass(10, fmt("both sidecars+ccs preserved; sidecar ppqs = %d, %d",
      sx[1].ppq, sx[2].ppq))
  else
    fail(10, fmt("sx=%d ccs=%d", #sx, #ccs))
  end
  reaper.DeleteTrackMediaItem(scratch, glued)
end

local function op12_move_to_track(scratch, dest)
  clearTrack(scratch)
  clearTrack(dest)
  local item, take = newItem(scratch, 28, 30)
  insertSidecar(take, 0, payload)
  reaper.MoveMediaItemToTrack(item, dest)
  -- The item's take object should still resolve and still carry the sidecar.
  local sx = readSidecars(reaper.GetActiveTake(item))
  if #sx == 1 then
    pass(12, "sidecar followed item to new track")
  else
    fail(12, fmt("expected 1 sidecar after track move, got %d", #sx))
  end
  reaper.DeleteTrackMediaItem(dest, item)
end

----- Phase A: lay down probes for phase B

local function setupProbes(probesTrack)
  clearTrack(probesTrack)
  -- probe 2: single sidecar, vanilla save+reload check
  local _, t2 = newItem(probesTrack, 0, 2)
  insertSidecar(t2, 0, payload)
  -- probe 3: two sidecars at distinct ppqs
  local _, t3 = newItem(probesTrack, 4, 6)
  insertSidecar(t3, 0,   payload)
  insertSidecar(t3, 200, payload)
  -- probe 4: sidecar coincident with a cc at ppq 0
  local _, t4 = newItem(probesTrack, 8, 10)
  insertSidecar(t4, 0, payload)
  insertCC(t4, 0, 7, 64)
end

----- Phase B: read probes

local function phaseB(probesTrack)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(probesTrack) - 1 do
    items[#items+1] = reaper.GetTrackMediaItem(probesTrack, i)
  end

  -- probe 2
  if items[1] then
    local sx = readSidecars(reaper.GetActiveTake(items[1]))
    if #sx == 1 and sx[1].msg == payload and sx[1].ppq == 0 then
      pass(2, "save+reload preserves single sidecar (bytes + ppq intact)")
    else
      fail(2, fmt("sx count=%d, bytes=%s, ppq=%s",
        #sx, sx[1] and (sx[1].msg == payload and "ok" or hex(sx[1].msg)) or "n/a",
             sx[1] and tostring(sx[1].ppq) or "n/a"))
    end
  else
    fail(2, "probe 2 item missing")
  end

  -- probe 3
  if items[2] then
    local sx = readSidecars(reaper.GetActiveTake(items[2]))
    local ppqs = {}
    for _, e in ipairs(sx) do ppqs[e.ppq] = e.msg end
    local bytesOk = (ppqs[0] == payload) and (ppqs[200] == payload)
    if #sx == 2 and bytesOk then
      pass(3, "two sidecars survive save+reload at correct ppqs (0, 200)")
    else
      fail(3, fmt("count=%d ppqs=[%s] bytesOk=%s",
        #sx, table.concat({ tostring(sx[1] and sx[1].ppq), tostring(sx[2] and sx[2].ppq) }, ","),
        tostring(bytesOk)))
    end
  else
    fail(3, "probe 3 item missing")
  end

  -- probe 4
  if items[3] then
    local take = reaper.GetActiveTake(items[3])
    local sx, ccs = readSidecars(take), readCCs(take)
    local sameSpot = sx[1] and ccs[1] and sx[1].ppq == ccs[1].ppq
    if #sx == 1 and #ccs == 1 and sx[1].msg == payload and sameSpot then
      pass(4, "coincident sidecar+cc both survive at same ppq")
    else
      fail(4, fmt("sx=%d cc=%d coincident=%s", #sx, #ccs, tostring(sameSpot)))
    end
  else
    fail(4, "probe 4 item missing")
  end

  -- op 13: tell user how to grep the rpp. REAPER frames the sysex on serialise,
  -- so the on-disk byte sequence is F0 + body + F7.
  local _, projfn = reaper.EnumProjects(-1, "")
  local onDisk = "F0" .. hex(payload):gsub(" ", "") .. "F7"
  info(13, fmt("project file: %s", projfn ~= "" and projfn or "(unsaved)"))
  info(13, fmt("hex-grep for sidecar bytes: %s", onDisk))
  info(13, "(or run: xxd projfile.rpp | grep -i 'f07d5244 4d')")

  -- op 11 — non-pass per spec
  info(11, "skipped (non-pass per spec — apply-FX renders to audio)")
end

----- Driver

local function summarise()
  out("")
  out("===== summary =====")
  local pf = { PASS = 0, FAIL = 0, INFO = 0 }
  for _, r in ipairs(results) do pf[r.status] = (pf[r.status] or 0) + 1 end
  out(fmt("PASS=%d  FAIL=%d  INFO=%d", pf.PASS, pf.FAIL, pf.INFO))
end

local function runPhaseA()
  reaper.ShowConsoleMsg("")  -- clear
  out("===== rdm sidecar spike — phase A =====")
  reaper.Undo_BeginBlock()

  local scratch = ensureTrack("rdm_spike_scratch")
  local probes  = ensureTrack("rdm_spike_probes")
  local dest    = ensureTrack("rdm_spike_dest")

  op1_immediate_readback(scratch)
  op5_glue(scratch)
  op6_split_sidecar_after(scratch)
  op7_split_sidecar_before(scratch)
  op8_split_straddle(scratch)
  op9_duplicate(scratch)
  op10_glue_two_stamped(scratch)
  op12_move_to_track(scratch, dest)

  -- prep phase-B probes; clear scratch + dest tracks (probes track stays)
  setupProbes(probes)
  clearTrack(scratch)
  clearTrack(dest)
  deleteTrack("rdm_spike_scratch")
  deleteTrack("rdm_spike_dest")

  setPhase("B")
  reaper.Undo_EndBlock("rdm_spike phase A", -1)
  reaper.UpdateArrange()

  summarise()
  out("")
  out("Phase A complete. To run phase B:")
  out("  1. Save the project (Ctrl-S).")
  out("  2. Close REAPER.")
  out("  3. Reopen the project.")
  out("  4. Re-run this script.")
end

local function runPhaseB()
  reaper.ShowConsoleMsg("")
  out("===== rdm sidecar spike — phase B =====")
  reaper.Undo_BeginBlock()

  local probes = findTrack("rdm_spike_probes")
  if not probes then
    fail("?", "rdm_spike_probes track not found — was the project saved between phases?")
  else
    phaseB(probes)
  end

  -- Cleanup
  deleteTrack("rdm_spike_probes")
  clearPhase()

  reaper.Undo_EndBlock("rdm_spike phase B", -1)
  reaper.UpdateArrange()

  summarise()
  out("")
  out("Spike complete. Save again to remove the probe track from disk.")
end

----- main

local phase = getPhase()
if phase == "B" then
  runPhaseB()
else
  runPhaseA()
end
