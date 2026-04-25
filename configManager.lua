-- See docs/configManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util.print(...)
end

-- Array-of-pairs lets nil defaults (declared-but-null) coexist with
-- non-nil ones: pair[1] presence = declared; pair[2] = default.
local declarations = {
  -- numeric
  { 'pbRange',         2     },
  { 'rowPerBeat',      4     },
  { 'overlapOffset',   1/16  },
  { 'defaultVelocity', 100   },
  { 'currentOctave',   2     },
  { 'advanceBy',       1     },

  -- boolean
  { 'polyAftertouch',  true  },

  -- string choice
  { 'noteLayout',      'colemak' },

  -- null-defaulted (declared, no initial value)
  { 'tuning',          nil   },
  { 'swing',           nil   },

  -- table-valued
  { 'colSwing',        {}    },
  { 'swings',          {}    },
  { 'mutedChannels',   {}    },
  { 'soloedChannels',  {}    },
  { 'extraColumns',    {}    },
  { 'noteDelay',       {}    },

  -- colours (flat dotted keys preserve per-colour override across levels)
  { 'colour.bg',           {218/256, 214/256, 201/256, 1  } },
  { 'colour.text',         { 48/256,  48/256,  33/256, 1  } },
  { 'colour.offGrid',      { 86/256, 138/256,  64/256, 1  } },
  { 'colour.overflow',     {210/256,  90/256,  35/256, 1  } },
  { 'colour.negative',     {218/256,  48/256,  33/256, 1  } },
  { 'colour.textBar',      { 48/256,  48/256,  33/256, 1  } },
  { 'colour.header',       { 48/256,  48/256,  33/256, 1  } },
  { 'colour.inactive',     {138/256, 134/256, 121/256, 1  } },
  { 'colour.cursor',       { 37/256,  41/256,  54/256, 1  } },
  { 'colour.cursorText',   {207/256, 207/256, 222/256, 1  } },
  { 'colour.rowNormal',    {218/256, 214/256, 201/256, 0  } },
  { 'colour.rowBeat',      {181/256, 179/256, 158/256, 0.4} },
  { 'colour.rowBarStart',  {159/256, 147/256, 115/256, 0.4} },
  { 'colour.editCursor',   {1,       1,       0,       1  } },
  { 'colour.selection',    {247/256, 247/256, 244/256, 0.5} },
  { 'colour.scrollHandle', { 48/256,  48/256,  33/256, 1  } },
  { 'colour.scrollBg',     {218/256, 214/256, 201/256, 1  } },
  { 'colour.accent',       {159/256, 147/256, 115/256, 1  } },
  { 'colour.mute',         {218/256,  48/256,  33/256, 1  } },
  { 'colour.solo',         {220/256, 180/256,  50/256, 1  } },
  { 'colour.separator',    {159/256, 147/256, 115/256, 0.3} },
  { 'colour.tail',         {100/256, 130/256, 160/256, 0.15} },
  { 'colour.tailBord',     {140/256, 170/256, 200/256, 1  } },
  { 'colour.ghost',        {100/256, 130/256, 160/256, 0.9} },
  { 'colour.ghostNegative',{218/256, 130/256, 120/256, 0.9} },
}

local declared, defaults = {}, {}
for _, pair in ipairs(declarations) do
  declared[pair[1]] = true
  if pair[2] ~= nil then defaults[pair[1]] = pair[2] end
end

local function copy(v)
  if type(v) == 'table' then return util.deepClone(v) end
  return v
end

function newConfigManager()

  ---------- PRIVATE DATA

  local CONFIG_PREFIX = 'rdm_'
  local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. 'rdm_cfg.txt'

  local take      = nil
  local track     = nil
  local fire  -- installed below, once cm exists

  local cache = {
    global    = nil,
    project   = nil,
    track     = nil,
    take      = nil,
    transient = nil,
  }

  -- transient sits above take: most-specific, never persisted. Used for
  -- view-layer overrides that should auto-vanish when the script reloads.
  local levels = { 'global', 'project', 'track', 'take', 'transient' }

  local levelSet = {}
  for _, l in ipairs(levels) do levelSet[l] = true end

  ---------- STORAGE BACKENDS

  -- Tolerant on load: stale keys from a rename shouldn't error.
  local function pruneUnknown(tbl)
    for k in pairs(tbl) do
      if not declared[k] then tbl[k] = nil end
    end
    return tbl
  end

  local function parse(text)
    if not text or text == '' then return {} end
    local ok, result = pcall(util.unserialise, util, text)
    if ok and type(result) == 'table' then return pruneUnknown(result) end
    return {}
  end

  local function loadGlobal()
    local f = io.open(CONFIG_GLOBAL_PATH, 'r')
    if not f then return {} end
    local content = f:read('*a')
    f:close()
    return parse(content)
  end

  local function saveGlobal(tbl)
    local f = io.open(CONFIG_GLOBAL_PATH, 'w')
    if not f then
      print('Error! Could not write global config to ' .. CONFIG_GLOBAL_PATH)
      return
    end
    f:write(util.serialise(tbl))
    f:close()
  end

  local function loadProject()
    local ok, val = reaper.GetProjExtState(0, 'rdm', 'config')
    return ok and parse(val)
  end

  local function saveProject(tbl)
    reaper.SetProjExtState(0, 'rdm', 'config', util.serialise(tbl))
  end

  local function loadTrack()
    if not track then return {} end
    local ok, val = reaper.GetSetMediaTrackInfo_String(
      track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
    return ok and parse(val)
  end

  local function saveTrack(tbl)
    if not track then
      print('Error! No track context for config storage')
      return
    end
    reaper.GetSetMediaTrackInfo_String(
      track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', util.serialise(tbl), true)
  end

  local function loadTake()
    if not take then return {} end
    local ok, val = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_config', '', false)
    return ok and parse(val)
  end

  local function saveTake(tbl)
    if not take then
      print('Error! No take context for config storage')
      return
    end
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_config', util.serialise(tbl), true)
  end

  local loaders = {
    global    = loadGlobal,
    project   = loadProject,
    track     = loadTrack,
    take      = loadTake,
    transient = function() return {} end,
  }

  local savers = {
    global    = saveGlobal,
    project   = saveProject,
    track     = saveTrack,
    take      = saveTake,
    transient = function() end,
  }

  ---------- CACHE MANAGEMENT

  local function refreshCache()
    for _, level in ipairs(levels) do
      cache[level] = loaders[level]()
    end
  end

  local function ensureCache()
    if not cache.global then refreshCache() end
  end

  local function mergedTable()
    ensureCache()
    local merged = {}
    for k, v in pairs(defaults) do merged[k] = v end
    for _, level in ipairs(levels) do
      if cache[level] then
        util.assign(merged, cache[level])
      end
    end
    return merged
  end

  local function checkLevel(level)
    if not levelSet[level] then
      error('Unknown config level: ' .. tostring(level), 3)
    end
  end

  local function checkKey(key)
    if not declared[key] then
      error('Unknown config key: ' .. tostring(key), 3)
    end
  end

  ---------- PUBLIC INTERFACE

  local cm = {}
  fire = util.installHooks(cm)

  function cm:setContext(newTake)
    take = newTake
    track = nil

    if take then
      local item = reaper.GetMediaItemTake_Item(take)
      if item then
        track = reaper.GetMediaItemTrack(item)
      end
    end

    refreshCache()
    fire({ config = true }, cm)
  end

  ----- Reading

  function cm:get(key)
    checkKey(key)
    return copy(mergedTable()[key])
  end

  function cm:getAt(level, key)
    checkLevel(level)
    ensureCache()
    local tbl = cache[level] or {}
    if key ~= nil then
      checkKey(key)
      return copy(tbl[key])
    end
    return util.deepClone(tbl)
  end

  function cm:getLevel(key)
    checkKey(key)
    ensureCache()
    for i = #levels, 1, -1 do
      local level = levels[i]
      if cache[level] and cache[level][key] ~= nil then
        return level
      end
    end
    return
  end

  ----- Writing

  function cm:set(level, key, value)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    cache[level] = cache[level] or {}
    cache[level][key] = copy(value)
    savers[level](cache[level])
    fire({ config = true, key = key, level = level }, cm)
  end

  function cm:remove(level, key)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    if cache[level] then
      cache[level][key] = nil
      savers[level](cache[level])
      fire({ config = true, key = key, level = level }, cm)
    end
  end

  function cm:assign(level, updates)
    if type(updates) ~= 'table' then return end
    checkLevel(level)
    for k in pairs(updates) do checkKey(k) end
    ensureCache()

    cache[level] = cache[level] or {}
    for k, v in pairs(updates) do
      if v == util.REMOVE then cache[level][k] = nil
      else                     cache[level][k] = copy(v) end
    end
    savers[level](cache[level])
    fire({ config = true, level = level }, cm)
  end

  return cm
end
