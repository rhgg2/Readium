-- See docs/continuum.md for the model and API reference.

function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('commandManager')
loadModule('editCursor')
loadModule('viewManager')
loadModule('sampleView')
loadModule('renderManager')

local function print(...)
  return util.print(...)
end

local function err_handler(err)
  reaper.ShowConsoleMsg('\nERROR:\n' .. tostring(err) .. '\n\n')
  reaper.ShowConsoleMsg(debug.traceback() .. '\n')
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

local SAMPLER_FX = 'Continuum Sampler'

function probeTrackerMode(mm, cm)
  local track = reaper.GetMediaItemTake_Track(mm:take())
  local detected = false
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    if name:find(SAMPLER_FX, 1, true) then detected = true; break end
  end
  if cm:get('trackerMode') ~= detected then
    cm:set('transient', 'trackerMode', detected)
  end
  -- Anticipative FX puts the sampler to sleep when idle; preview mailbox
  -- wake-up then takes 200–500 ms. I_PERFFLAGS bit 2 disables it on this
  -- track only. Persistent (saved with the project), set once.
  if detected then
    local pf = reaper.GetMediaTrackInfo_Value(track, 'I_PERFFLAGS')
    if (pf & 2) == 0 then
      reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', pf | 2)
    end
  end
end

-- gmem[Continuum_sampler] layout:
--   [0..1023]                          load mailbox (Continuum→sampler)
--     [0]   magic (0=empty, MAGIC=pending; written last so sampler never reads half)
--     [1]   slot index
--     [2..] path bytes, 0-terminated
--   [NAMES_BASE..NAMES_BASE+N*STRIDE-1] names slab (sampler→Continuum)
--     one slot per sample: ASCII bytes then 0-terminator
--   [PREVIEW_BASE..PREVIEW_BASE+1023]  preview mailbox (Continuum→sampler)
--     [0]   magic
--     [1]   slot (0..N-1 = preview existing slot; PREVIEW_SLOT_IDX = path-load first)
--     [2]   bounds (0 full file, 1 honour SH_START/SH_END)
--     [3..] path bytes, 0-terminated (only when slot == PREVIEW_SLOT_IDX)
-- All constants must match the JSFX side.
local CTM_GMEM_NS            = 'Continuum_sampler'
local CTM_GMEM_MAGIC         = 1717658484   -- 'CTML' as 32-bit ASCII
local CTM_GMEM_NAMES_BASE    = 1024
local CTM_GMEM_NAME_STRIDE   = 64
local CTM_N_SAMPLES          = 64
local CTM_GMEM_PREVIEW_BASE  = 5120         -- = NAMES_BASE + N_SAMPLES * NAME_STRIDE
local CTM_PREVIEW_SLOT_IDX   = CTM_N_SAMPLES

local function writeGmemPath(base, path)
  for i = 1, #path do reaper.gmem_write(base + i - 1, path:byte(i)) end
  reaper.gmem_write(base + #path, 0)
end

function samplerLoadSlot(slot, path)
  reaper.gmem_attach(CTM_GMEM_NS)
  if reaper.gmem_read(0) ~= 0 then return false end
  writeGmemPath(2, path)
  reaper.gmem_write(1, slot)
  reaper.gmem_write(0, CTM_GMEM_MAGIC)
  return true
end

function samplerPreviewSlot(slot, bounds)
  reaper.gmem_attach(CTM_GMEM_NS)
  if reaper.gmem_read(CTM_GMEM_PREVIEW_BASE) ~= 0 then return false end
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE + 1, slot)
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE + 2, bounds)
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE, CTM_GMEM_MAGIC)
  return true
end

function samplerPreviewPath(path)
  reaper.gmem_attach(CTM_GMEM_NS)
  if reaper.gmem_read(CTM_GMEM_PREVIEW_BASE) ~= 0 then return false end
  writeGmemPath(CTM_GMEM_PREVIEW_BASE + 3, path)
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE + 1, CTM_PREVIEW_SLOT_IDX)
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE + 2, 0)
  reaper.gmem_write(CTM_GMEM_PREVIEW_BASE, CTM_GMEM_MAGIC)
  return true
end

-- Pull sample names from the gmem names slab; only write back to cm when
-- they actually change so configChanged doesn't fire every frame. Names
-- are 0-indexed, matching JSFX slot index and MIDI PC values.
function readSamplerNames(cm)
  reaper.gmem_attach(CTM_GMEM_NS)
  local fresh = {}
  for idx = 0, CTM_N_SAMPLES - 1 do
    local base, chars = CTM_GMEM_NAMES_BASE + idx * CTM_GMEM_NAME_STRIDE, {}
    for j = 0, CTM_GMEM_NAME_STRIDE - 1 do
      local b = reaper.gmem_read(base + j)
      if not b or b == 0 then break end
      chars[#chars + 1] = string.char(math.floor(b))
    end
    if #chars > 0 then fresh[idx] = table.concat(chars) end
  end
  local cur = cm:get('samplerNames')
  for k, v in pairs(fresh) do
    if cur[k] ~= v then cm:set('transient', 'samplerNames', fresh); return end
  end
  for k, v in pairs(cur) do
    if fresh[k] ~= v then cm:set('transient', 'samplerNames', fresh); return end
  end
end

function Main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowConsoleMsg('Please select a MIDI item.\n')
    return
  end

  local take = reaper.GetActiveTake(item)
  local mm = newMidiManager(take)
  local cm = newConfigManager()
  cm:setContext(take)
  local tm = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)
  cmgr:register('loadSampleAtCurrentSlot', function()
    if not cm:get('trackerMode') then return end
    local rv, path = reaper.GetUserFileNameForRead('', 'Load sample into current slot', '')
    if rv and path ~= '' then
      samplerLoadSlot(cm:get('currentSample'), path)
    end
  end)
  cmgr:register('toggleViewMode', function()
    cm:set('transient', 'viewMode',
      cm:get('viewMode') == 'sample' and 'tracker' or 'sample')
  end)

  local vm = newViewManager(tm, cm, cmgr)
  local sv = newSampleView(cm, samplerLoadSlot, samplerPreviewSlot, samplerPreviewPath)
  local renderer = newRenderManager(vm, cm, cmgr, sv)
  probeTrackerMode(mm, cm)
  renderer:init()

  local function loop()
    probeTrackerMode(mm, cm)
    if cm:get('trackerMode') then readSamplerNames(cm) end
    if cm:get('viewMode') == 'sample' then
      sv:setTrack(reaper.GetSelectedTrack(0, 0))
    end
    if renderer:loop() then
      reaper.defer(loop)
    end
  end
  loop()
end

run(Main)
