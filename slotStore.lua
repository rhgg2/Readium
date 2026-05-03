-- See docs/slotStore.md for the model and API reference.
--
-- Source-of-truth for sample slot assignments. cm holds the canonical
-- state at the track tier (P_EXT-persisted as `slotEntries`); the JSFX
-- is a decoded-audio cache fed via `loadSlot`. Files live in a
-- `Continuum/` subfolder under the project's media path; pre-save that
-- resolves to REAPER's default media folder, post-save to the project's
-- own. cm stores project-relative paths only — migration handles the
-- file move on save / Save As.
--
-- fileOps and loadSlot are injected so the module is testable in the
-- pure-Lua harness without REAPER or disk I/O.

loadModule('util')
loadModule('fs')

local function rand8()
  local h = {}
  for i = 1, 8 do h[i] = string.format('%x', math.random(0, 15)) end
  return table.concat(h)
end

local function relForSrc(srcBase)
  local stem, ext = srcBase:match('^(.*)%.([^.]+)$')
  stem = stem or srcBase
  return ext
    and 'Continuum/' .. stem .. '-' .. rand8() .. '.' .. ext
    or  'Continuum/' .. stem .. '-' .. rand8()
end

-- fileOps: { copy(src,dst)→bool, move(src,dst)→bool, mkdir(dir)→() }
-- loadSlot: (idx, absPath) → ()  -- the gmem load mailbox writer.
function newSlotStore(cm, fileOps, loadSlot)
  local store = {}

  local function setEntry(idx, fields)
    local entries = cm:get('slotEntries')
    entries[idx] = entries[idx] or {}
    for k, v in pairs(fields) do entries[idx][k] = v end
    cm:set('track', 'slotEntries', entries)
  end

  function store:assign(idx, srcPath, projectPath)
    local rel = relForSrc(fs.basename(srcPath))
    local abs = projectPath .. '/' .. rel
    fileOps.mkdir(projectPath .. '/Continuum')
    if not fileOps.copy(srcPath, abs) then return false end
    setEntry(idx, { path = rel })
    loadSlot(idx, abs)
    return true
  end

  function store:sweep(projectPath)
    local entries = cm:get('slotEntries')
    for idx, e in pairs(entries) do
      if e.path then loadSlot(idx, projectPath .. '/' .. e.path) end
    end
  end

  -- Move slot files when the project's media folder changes (typically
  -- the empty→saved transition). cm paths are relative so they survive
  -- the move untouched; only the bytes need to follow.
  function store:migrate(projectPath, oldProjectPath)
    if not oldProjectPath or oldProjectPath == projectPath then return false end
    local entries = cm:get('slotEntries')
    local anyMoved = false
    for _, e in pairs(entries) do
      if e.path then
        local oldAbs = oldProjectPath .. '/' .. e.path
        local newAbs = projectPath    .. '/' .. e.path
        if oldAbs ~= newAbs then
          fileOps.mkdir(projectPath .. '/Continuum')
          if fileOps.move(oldAbs, newAbs) then anyMoved = true end
        end
      end
    end
    return anyMoved
  end

  return store
end
