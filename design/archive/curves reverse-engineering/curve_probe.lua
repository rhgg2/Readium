--------------------
-- curve_probe.lua
--
-- Reverse-engineer REAPER's CC interpolation curves by recording a
-- shaped CC stream into a second MIDI take. See curve_reverse_engineering.md.
--
-- Uses 14-bit CC encoding: each shape seeds MSB on CC N and LSB on CC N+32
-- at both endpoints. REAPER auto-pairs these and bakes a true 14-bit stream
-- (LSB sawtooths within each MSB step). Dump combines MSB+LSB samples to
-- (ppq, val_0..16383) rows — ~128× finer y-resolution than plain 7-bit.
--
-- Mode is auto-detected from the selected take's CC count:
--   ≤ 4 * #CONFIGS  → seed (clear and insert MSB/LSB pairs at endpoints)
--   >  4 * #CONFIGS → dump (write one CSV per config)
--
-- Workflow:
--   1. Select an empty MIDI item, run the script (seeds it).
--   2. In REAPER: route this track's MIDI to a second track, record-arm
--      that track, play through the seeded segment, stop.
--   3. Select the recorded take, run the script again (dumps CSVs to
--      design/curve_samples/).
--------------------

local SEGMENT_PPQ = 49152  -- 4 QN at this project's 12288 PPQ/QN (~2s at 120 BPM → ~130 samples per curve)
local MAX14 = 16383        -- 2^14 - 1; normalise y by this on dump

local CONFIGS = {
  { cc = 0, shape = 0, tension = 0, name = 'step' },
  { cc = 1, shape = 1, tension = 0, name = 'linear' },
  { cc = 2, shape = 2, tension = 0, name = 'slow' },
  { cc = 3, shape = 3, tension = 0, name = 'fast-start' },
  { cc = 4, shape = 4, tension = 0, name = 'fast-end' },
}
-- Bezier at τ = -1.0, -0.9, ..., +1.0 on CCs 5..25 (LSBs auto-paired on 37..57).
for i = -10, 10 do
  local tau = i / 10
  CONFIGS[#CONFIGS+1] = {
    cc = 15 + i, shape = 5, tension = tau,
    name = ('bezier_%.2f'):format(tau),
  }
end

local scriptDir = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]') or '.'
local OUT_DIR = scriptDir .. '/curve_samples'

local function getTake()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowMessageBox('Select a MIDI item first.', 'curve_probe', 0)
    return
  end
  return reaper.GetActiveTake(item)
end

local function seed(take)
  reaper.MIDI_DisableSort(take)

  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  for i = ccCount - 1, 0, -1 do reaper.MIDI_DeleteCC(take, i) end

  for _, c in ipairs(CONFIGS) do
    -- MSB pair (start event carries the shape; REAPER interpolates 14-bit).
    reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, 0, c.cc, 0)
    local _, _, n = reaper.MIDI_CountEvts(take)
    reaper.MIDI_SetCCShape(take, n - 1, c.shape, c.tension, true)
    reaper.MIDI_InsertCC(take, false, false, SEGMENT_PPQ, 0xB0, 0, c.cc, 127)
    -- LSB pair — REAPER auto-pairs CC N with CC N+32 into a 14-bit stream.
    reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, 0, c.cc + 32, 0)
    reaper.MIDI_InsertCC(take, false, false, SEGMENT_PPQ, 0xB0, 0, c.cc + 32, 127)
  end

  reaper.MIDI_Sort(take)

  reaper.ShowMessageBox(
    'Seeded ' .. #CONFIGS .. ' shape configs into the selected take.\n\n' ..
    'Next:\n' ..
    '  1. Add a second track; route this track\'s MIDI to it.\n' ..
    '  2. Set the second track\'s record input to the routed MIDI and arm it.\n' ..
    '  3. Play through the seeded segment, then stop.\n' ..
    '  4. Select the recorded take and re-run this script to dump CSVs.',
    'curve_probe: seeded',
    0
  )
end

local function dump(take)
  os.execute('mkdir -p "' .. OUT_DIR .. '"')

  -- Bucket every CC event by its msg2 (CC number).
  local byCC = {}
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  for i = 0, ccCount - 1 do
    local _, _, _, ppq, chanmsg, _, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if chanmsg == 0xB0 then
      byCC[msg2] = byCC[msg2] or {}
      table.insert(byCC[msg2], { ppq = ppq, val = msg3 })
    end
  end

  for _, c in ipairs(CONFIGS) do
    -- Merge MSB (CC N) and LSB (CC N+32) streams into one ppq-ordered list
    -- tagged with which lane each event updates, then reduce to 14-bit samples.
    local merged = {}
    for _, r in ipairs(byCC[c.cc] or {})       do merged[#merged+1] = { ppq = r.ppq, lane = 'msb', val = r.val } end
    for _, r in ipairs(byCC[c.cc + 32] or {})  do merged[#merged+1] = { ppq = r.ppq, lane = 'lsb', val = r.val } end
    table.sort(merged, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      if a.lane == b.lane then return false end
      return a.lane == 'msb'  -- MSB first at same ppq so the paired 14-bit value is emitted correctly
    end)

    -- Replay the merged stream, keeping one row per distinct ppq (the
    -- final (msb, lsb) state at that ppq).
    local rows, byppq = {}, {}
    local msb, lsb = 0, 0
    for _, e in ipairs(merged) do
      if e.lane == 'msb' then msb = e.val else lsb = e.val end
      local idx = byppq[e.ppq]
      if idx then
        rows[idx].val = msb * 128 + lsb
      else
        rows[#rows+1] = { ppq = e.ppq, val = msb * 128 + lsb }
        byppq[e.ppq] = #rows
      end
    end

    local f = assert(io.open(OUT_DIR .. '/' .. c.name .. '.csv', 'w'))
    f:write('ppq,val\n')
    for _, r in ipairs(rows) do f:write(r.ppq .. ',' .. r.val .. '\n') end
    f:close()
  end

  local mf = assert(io.open(OUT_DIR .. '/manifest.csv', 'w'))
  mf:write('cc,shape_code,shape_name,tension,segment_ppq,max_val\n')
  for _, c in ipairs(CONFIGS) do
    mf:write(string.format('%d,%d,%s,%g,%d,%d\n', c.cc, c.shape, c.name, c.tension, SEGMENT_PPQ, MAX14))
  end
  mf:close()

  reaper.ShowMessageBox('Dumped ' .. #CONFIGS .. ' CSVs (14-bit) to:\n' .. OUT_DIR, 'curve_probe: dumped', 0)
end

local take = getTake()
if take then
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  if ccCount > 4 * #CONFIGS then dump(take) else seed(take) end
end
