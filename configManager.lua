--------------------
-- newConfigManager
--
-- Manages configuration at four levels of specificity, from least
-- to most specific:
--
--   1. global   – saved to a Lua file on disk
--   2. project  – saved to REAPER project extension data
--   3. track    – saved to REAPER track extension data
--   4. take     – saved to REAPER take extension data
--
-- When reading a config value, all four levels are merged, with
-- more specific levels overriding less specific ones. When writing,
-- the caller specifies which level to write to.
--
-- SCHEMA
--   The full set of valid config keys and their defaults is declared
--   inline below as `declarations`, an ordered array of
--   { 'key', default } pairs. Keys not in the schema are rejected by
--   get/set/remove/assign (raise). Keys found in persisted data that
--   are not in the schema are silently pruned on load — tolerant of
--   stale project/take ext-state, strict about in-code use.
--
-- OWNERSHIP
--   cm owns its internal state. Every read deep-copies out; every
--   write deep-copies in. Callers never alias cm's tables and never
--   need to clone — mutating a result from cm:get never affects cm.
--
-- CONSTRUCTION
--   local cm = newConfigManager()
--     Creates a config manager with no MIDI context. Global and
--     project config are available immediately. Track and take
--     config become available after cm:setContext(take).
--
-- CONTEXT
--   cm:setContext(take)             -- set or change the active take
--     Derives the track from the take automatically. Refreshes
--     all four cache tiers and fires callbacks. Pass nil to clear
--     the take/track context (global and project remain available).
--
-- READING
--   cm:get(key)                    -- merged value (most specific wins)
--   cm:getAt(level, key)           -- value at a specific level only
--   cm:getAt(level)                -- full table at a specific level
--   cm:getLevel(key)               -- which level currently defines key
--
-- WRITING
--   cm:set(level, key, value)      -- set a value at a specific level
--   cm:remove(level, key)          -- remove a key at a specific level
--   cm:assign(level, updates)      -- update via util:assign at a specific level
--
-- MESSAGING
--   cm:addCallback(fn)             -- fn(changed, cm) called on any change
--   cm:removeCallback(fn)          -- remove a callback
--     changed is of the form { config = true }
--
-- LEVELS (valid strings for the level parameter)
--   'global', 'project', 'track', 'take'
--------------------

loadModule('util')

local function print(...)
  return util:print(...)
end

--------------------
-- Schema. Ordered array of {key, default} pairs. The array form lets
-- nil defaults ('declared but null') coexist with non-nil ones without
-- ambiguity: pair[1] is always a truthy string (presence = declared);
-- pair[2] is the default (absence/nil = no initial value).
--------------------

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

  -- colours (flat dotted keys — preserves per-colour override semantics)
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
  if type(v) == 'table' then return util:deepClone(v) end
  return v
end

--------------------

function newConfigManager()

  ---------- PRIVATE DATA

  local CONFIG_PREFIX = 'rdm_'
  local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. 'rdm_cfg.txt'

  local take      = nil
  local track     = nil
  local fire  -- installed below, once cm exists

  local cache = {
    global  = nil,
    project = nil,
    track   = nil,
    take    = nil,
  }

  local levels = { 'global', 'project', 'track', 'take' }

  local levelSet = {}
  for _, l in ipairs(levels) do levelSet[l] = true end

  ---------- STORAGE BACKENDS

  -- Prune keys that are not in the schema. Tolerant on load — a user's
  -- on-disk config may carry stale keys from a rename; silently drop
  -- them rather than erroring.
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

  -- Level 1: global (Lua file on disk)

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
    f:write(util:serialise(tbl))
    f:close()
  end

  -- Level 2: project (project extension data)

  local function loadProject()
    local ok, val = reaper.GetProjExtState(0, 'rdm', 'config')
    return ok and parse(val)
  end

  local function saveProject(tbl)
    reaper.SetProjExtState(0, 'rdm', 'config', util:serialise(tbl))
  end

  -- Level 3: track (track extension data)

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
      track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', util:serialise(tbl), true)
  end

  -- Level 4: take (take extension data)

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
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:rdm_config', util:serialise(tbl), true)
  end

  -- Backend dispatch

  local loaders = {
    global  = loadGlobal,
    project = loadProject,
    track   = loadTrack,
    take    = loadTake,
  }

  local savers = {
    global  = saveGlobal,
    project = saveProject,
    track   = saveTrack,
    take    = saveTake,
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

  -- Returns a reference to the merged view. Callers MUST copy() any
  -- value they intend to return outward; the public get*() methods do
  -- this at the boundary.
  local function mergedTable()
    ensureCache()
    local merged = {}
    for k, v in pairs(defaults) do merged[k] = v end
    for _, level in ipairs(levels) do
      if cache[level] then
        util:assign(merged, cache[level])
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
  fire = util:installHooks(cm)

  -- Context: set the active take (and derived track)

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

  -- Reading

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
    return util:deepClone(tbl)
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

  -- Writing

  -- Callbacks receive { config = true, key = <name> } for targeted
  -- writes, letting consumers filter on keys they actually depend on.
  -- Bulk paths (setContext, assign) fire without a key — consumers that
  -- care must treat keyless fires as "any key might have changed".

  function cm:set(level, key, value)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    cache[level] = cache[level] or {}
    cache[level][key] = copy(value)
    savers[level](cache[level])
    fire({ config = true, key = key }, cm)
  end

  function cm:remove(level, key)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    if cache[level] then
      cache[level][key] = nil
      savers[level](cache[level])
      fire({ config = true, key = key }, cm)
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
    fire({ config = true }, cm)
  end

  ---------- FACTORY BODY

  return cm
end
