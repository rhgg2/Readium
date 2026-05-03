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
loadModule('slotStore')
loadModule('sampleView')
loadModule('renderManager')

math.randomseed(os.time())

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

-- Walks all tracks and returns those carrying the Continuum Sampler FX.
-- Returned shape: { { track = <track>, name = <track-name> }, ... } —
-- consumed by sampleView's track picker.
function listSamplerTracks()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    for j = 0, reaper.TrackFX_GetCount(t) - 1 do
      local _, fxName = reaper.TrackFX_GetFXName(t, j, '')
      if fxName:find(SAMPLER_FX, 1, true) then
        local _, trackName = reaper.GetTrackName(t)
        out[#out + 1] = { track = t,
                          name  = trackName ~= '' and trackName or '(unnamed)' }
        break
      end
    end
  end
  return out
end

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
--     [2..] rel-path bytes, 0-terminated (project-relative; prefix from PREFIX mailbox)
--   [NAMES_BASE..NAMES_BASE+N*STRIDE-1] names slab (sampler→Continuum)
--     one slot per sample: ASCII bytes then 0-terminator
--   [PREVIEW_BASE..PREVIEW_BASE+1023]  preview mailbox (Continuum→sampler)
--     [0]   magic
--     [1]   slot (0..N-1 = preview existing slot; PREVIEW_SLOT_IDX = path-load first)
--     [2]   bounds (0 full file, 1 honour SH_START/SH_END)
--     [3..] absolute path bytes, 0-terminated (preview is project-agnostic)
--   [PREFIX_BASE..PREFIX_BASE+1023]    project-prefix mailbox (Continuum→sampler)
--     [0]   magic
--     [1..] absolute project root bytes, 0-terminated. JSFX caches in SER_PREFIX_STR.
-- All constants must match the JSFX side.
local CTM_GMEM_NS            = 'Continuum_sampler'
local CTM_GMEM_MAGIC         = 1717658484   -- 'CTML' as 32-bit ASCII
local CTM_GMEM_NAMES_BASE    = 1024
local CTM_GMEM_NAME_STRIDE   = 64
local CTM_N_SAMPLES          = 64
local CTM_GMEM_PREVIEW_BASE  = 5120         -- = NAMES_BASE + N_SAMPLES * NAME_STRIDE
local CTM_GMEM_PREFIX_BASE   = 6144         -- = PREVIEW_BASE + 1024
local CTM_PREVIEW_SLOT_IDX   = CTM_N_SAMPLES

local function writeGmemPath(base, path)
  for i = 1, #path do reaper.gmem_write(base + i - 1, path:byte(i)) end
  reaper.gmem_write(base + #path, 0)
end

function samplerLoadSlot(slot, relPath)
  reaper.gmem_attach(CTM_GMEM_NS)
  if reaper.gmem_read(0) ~= 0 then return false end
  writeGmemPath(2, relPath)
  reaper.gmem_write(1, slot)
  reaper.gmem_write(0, CTM_GMEM_MAGIC)
  return true
end

-- Push the project root to the sampler so it can compose abs paths from
-- rel-path loads and persist the prefix in @serialize. Idempotent; sweep
-- writes it on every (re-)attach.
function samplerSetPrefix(prefix)
  reaper.gmem_attach(CTM_GMEM_NS)
  if reaper.gmem_read(CTM_GMEM_PREFIX_BASE) ~= 0 then return false end
  writeGmemPath(CTM_GMEM_PREFIX_BASE + 1, prefix)
  reaper.gmem_write(CTM_GMEM_PREFIX_BASE, CTM_GMEM_MAGIC)
  return true
end

-- Filesystem ops for slotStore. Stream-copy in 64KB chunks so big samples
-- don't allocate a single Lua string the size of the file. os.rename
-- fails across filesystems, so move falls back to copy+delete.
local function copyFileBytes(src, dst)
  local fin = io.open(src, 'rb');  if not fin  then return false end
  local fout = io.open(dst, 'wb'); if not fout then fin:close(); return false end
  while true do
    local chunk = fin:read(64 * 1024)
    if not chunk then break end
    fout:write(chunk)
  end
  fin:close(); fout:close()
  return true
end

local fileOps = {
  copy  = copyFileBytes,
  move  = function(src, dst)
    if os.rename(src, dst) then return true end
    if copyFileBytes(src, dst) then os.remove(src); return true end
    return false
  end,
  mkdir = function(dir) reaper.RecursiveCreateDirectory(dir, 0) end,
}

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
  -- An empty fresh on a tick where JSFX briefly hasn't republished (e.g. transport
  -- gating, or a race with @serialize) would otherwise blank cur and the slot
  -- list flickers '(empty)' between every populated read. JSFX wiping all 64
  -- names in one go isn't a real workflow, so prefer stickiness.
  if next(fresh) == nil and next(cur) ~= nil then return end
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
  local vm = newViewManager(tm, cm, cmgr)
  local slotStore = newSlotStore(cm, fileOps, samplerLoadSlot)
  local function assignSlot(slot, srcPath)
    return slotStore:assign(slot, srcPath, reaper.GetProjectPath(0))
  end
  cmgr:register('loadSampleAtCurrentSlot', function()
    if not cm:get('trackerMode') then return end
    local rv, path = reaper.GetUserFileNameForRead('', 'Load sample into current slot', '')
    if rv and path ~= '' then
      assignSlot(cm:get('currentSample'), path)
    end
  end)
  cmgr:register('toggleViewMode', function()
    cm:set('transient', 'viewMode',
      cm:get('viewMode') == 'sample' and 'tracker' or 'sample')
  end)

  local sv = newSampleView(cm, assignSlot, samplerPreviewSlot, samplerPreviewPath,
                           listSamplerTracks)
  local renderer = newRenderManager(vm, cm, cmgr, sv)
  probeTrackerMode(mm, cm)
  renderer:init()

  -- Sample mode is take-independent: cm drops the take and rebinds its
  -- track to whatever the picker (or the default) selected. Tracker mode
  -- restores the take context so take-tier reads work again. prevMode
  -- seeds to 'tracker' (the post-Main state); a 'sample' boot is then
  -- caught by the mismatch on the first iteration.
  local prevMode = 'tracker'
  local function applyViewMode(mode)
    if mode == 'sample' then
      cm:clearTake()
      sv:setTrack(reaper.GetMediaItemTake_Track(take))
    else
      cm:setContext(take)
    end
  end

  -- sweptForTracker re-arms when trackerMode goes false: a fresh FX needs
  -- a fresh push of every slot since @serialize starts empty.
  local sweptForTracker, lastProjectPath = false, nil
  local function loop()
    probeTrackerMode(mm, cm)
    local pp = reaper.GetProjectPath(0)
    if cm:get('trackerMode') then
      if lastProjectPath and lastProjectPath ~= pp then
        slotStore:migrate(pp, lastProjectPath)
      end
      if not sweptForTracker then
        samplerSetPrefix(pp)
        slotStore:sweep()
        sweptForTracker = true
      end
      readSamplerNames(cm)
    else
      sweptForTracker = false
    end
    lastProjectPath = pp

    local mode = cm:get('viewMode')
    if mode ~= prevMode then
      applyViewMode(mode)
      prevMode = mode
    end

    if renderer:loop() then
      reaper.defer(loop)
    end
  end
  loop()
end

run(Main)
