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
--   cm:get()                       -- full merged table
--   cm:getAt(level, key)           -- value at a specific level only
--   cm:getAt(level)                -- full table at a specific level
--   cm:getLevel(key)               -- which level currently defines key
--
-- WRITING
--   cm:set(level, key, value)      -- set a value at a specific level
--   cm:remove(level, key)          -- remove a key at a specific level
--   cm:assign(level, updates)      -- update via util:assign at a specific level
--
-- DEFAULTS
--   cm:setDefaults(tbl)            -- set default values; these sit below
--                                     all four levels in the merge order
--
-- MESSAGING
--   cm:addCallback(fn)             -- fn(changed, cm) called on any change
--   cm:removeCallback(fn)          -- remove a callback
--     changed is of the form { config = true }
--
-- LEVELS (valid strings for the level parameter)
--   "global", "project", "track", "take"
--------------------

loadModule('util')

local function print(...)
  return util:print(...)
end

--------------------

function newConfigManager()

  ---------- PRIVATE DATA

  local CONFIG_PREFIX = "rdm_"
  local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. "rdm_cfg.txt"

  local take      = nil
  local track     = nil
  local defaults  = {}
  local callbacks = {}

  local cache = {
    global  = nil,
    project = nil,
    track   = nil,
    take    = nil,
  }

  local levels = { "global", "project", "track", "take" }

  local levelSet = {}
  for _, l in ipairs(levels) do levelSet[l] = true end

  ---------- STORAGE BACKENDS

  local function parse(text)
    if not text or text == "" then return {} end
    local ok, result = pcall(util.unserialise, util, content)
    if ok and type(result) == "table" then return result end
    return {}
  end
  
  -- Level 1: global (Lua file on disk)

  local function loadGlobal()
    local f = io.open(CONFIG_GLOBAL_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    return parse(content)
  end

  local function saveGlobal(tbl)
    local f = io.open(CONFIG_GLOBAL_PATH, "w")
    if not f then
      print("Error! Could not write global config to " .. CONFIG_GLOBAL_PATH)
      return
    end
    f:write(util:serialise(tbl))
    f:close()
  end

  -- Level 2: project (project extension data)

  local function loadProject()
    local ok, val = reaper.GetProjExtState(0, "rdm", "config")
    return ok and parse(val)
  end

  local function saveProject(tbl)
    reaper.SetProjExtState(0, "rdm", "config", util:serialise(tbl))
  end

  -- Level 3: track (track extension data)

  local function loadTrack()
    if not track then return {} end
    local ok, val = reaper.GetSetMediaTrackInfo_String(
      track, "P_EXT:" .. CONFIG_PREFIX .. "config", "", false)
    return ok and parse(val)
  end

  local function saveTrack(tbl)
    if not track then
      print("Error! No track context for config storage")
      return
    end
    reaper.GetSetMediaTrackInfo_String(
      track, "P_EXT:" .. CONFIG_PREFIX .. "config", util:serialise(tbl), true)
  end

  -- Level 4: take (take extension data)

  local function loadTake()
    if not take then return {} end
    local ok, val = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_config", "", false)
    return ok and parse(val)
  end

  local function saveTake(tbl)
    if not take then
      print("Error! No take context for config storage")
      return
    end
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:rdm_config", util:serialise(tbl), true)
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

  local function mergedTable()
    ensureCache()
    local merged = util:assign({}, defaults)
    for _, level in ipairs(levels) do
      if cache[level] then
        util:assign(merged, cache[level])
      end
    end
    return merged
  end

  local function fireCallbacks()
    for fn, _ in pairs(callbacks) do
      fn({ config = true }, cm)
    end
  end

  local function checkLevel(level)
    if not levelSet[level] then
      print("Error! Unknown config level: " .. tostring(level))
      return false
    end
    return true
  end

  ---------- PUBLIC INTERFACE

  local cm = {}

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
    fireCallbacks()
  end

  -- Reading

  function cm:get(key)
    local merged = mergedTable()
    if key ~= nil then return merged[key] end
    return merged
  end

  function cm:getAt(level, key)
    if not checkLevel(level) then return nil end
    ensureCache()
    local tbl = cache[level] or {}
    if key ~= nil then return tbl[key] end
    return util:assign({}, tbl)
  end

  function cm:getLevel(key)
    ensureCache()
    for i = #levels, 1, -1 do
      local level = levels[i]
      if cache[level] and cache[level][key] ~= nil then
        return level
      end
    end
    return nil
  end

  -- Writing

  function cm:set(level, key, value)
    if not checkLevel(level) then return end
    ensureCache()

    cache[level] = cache[level] or {}
    cache[level][key] = value
    savers[level](cache[level])
    fireCallbacks()
  end

  function cm:remove(level, key)
    if not checkLevel(level) then return end
    ensureCache()

    if cache[level] then
      cache[level][key] = nil
      savers[level](cache[level])
      fireCallbacks()
    end
  end

  function cm:assign(level, updates)
    if type(updates) ~= "table" then return end
    if not checkLevel(level) then return end
    ensureCache()

    util:assign(cache[level], updates, true)
    savers[level](cache[level])
    fireCallbacks()
  end        

  -- Defaults

  function cm:setDefaults(tbl)
    defaults = util:assign({}, tbl)
  end

  -- Messaging

  function cm:addCallback(fn)
    callbacks[fn] = true
  end

  function cm:removeCallback(fn)
    callbacks[fn] = nil
  end

  ---------- FACTORY BODY

  return cm
end
