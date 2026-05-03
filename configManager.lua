-- See docs/configManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util.print(...)
end

-- hex('#RRGGBB', alpha?) → {r,g,b,a} with components in [0,1].
-- Leading '#' optional; alpha defaults to 1. Used by the colour-atom
-- declarations below.
local function hex(s, alpha)
  s = s:gsub('^#', '')
  local r = tonumber(s:sub(1,2), 16) / 255
  local g = tonumber(s:sub(3,4), 16) / 255
  local b = tonumber(s:sub(5,6), 16) / 255
  return {r, g, b, alpha or 1}
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
  { 'currentSample',   0     },
  { 'advanceBy',       1     },

  -- boolean
  { 'polyAftertouch',  true  },
  { 'trackerMode',     false },

  -- string choice
  { 'noteLayout',      'colemak' },
  { 'viewMode',        'tracker' },

  -- null-defaulted (declared, no initial value)
  { 'temper',          nil   },
  { 'swing',           nil   },
  { 'sampleBrowserRoot', nil },

  -- table-valued
  { 'colSwing',        {}    },
  { 'swings',          {}    },
  { 'tempers',         {}    },
  { 'mutedChannels',   {}    },
  { 'soloedChannels',  {}    },
  { 'extraColumns',    {}    },
  { 'noteDelay',       {}    },
  { 'samplerNames',    {}    },
  { 'slotEntries',     {}    },

  -- Colour table: a flat keyspace whose entries take three forms.
  -- Atoms live under `palette.*` (parchment, used by the tracker grid)
  -- and `chrome.*` (neutral, used by toolbar/popups/modals); they're the
  -- only place RGB values live. Roles live under `colour.*` and name the
  -- *function* a colour plays — they alias an atom (or another role) by
  -- its full cm key, optionally overriding alpha. One-off colours that
  -- earn no good function name live inline at the role.
  --
  -- Entry forms (resolved by renderManager's resolveColour):
  --   {r,g,b,a}     atom — terminal RGBA
  --   'fullKey'     pure alias — recursive cm:get, alpha inherited
  --   {'fullKey',a} alias with alpha override (outermost wins)

  -- Atoms — parchment palette
  { 'palette.bg',        hex('#dad6c9') },  -- cream paper
  { 'palette.shade',     hex('#303021') },  -- dark ink
  { 'palette.mid',       hex('#9f9373') },  -- warm tan (accents, separators, bar markers)
  { 'palette.highlight', hex('#b5b39e') },  -- lighter tan (beat-row tone)
  { 'palette.inactive',  hex('#8a8679') },  -- muted olive-grey
  { 'palette.danger',    hex('#da3021') },
  { 'palette.caution',   hex('#d25a23') },
  { 'palette.positive',  hex('#568a40') },
  { 'palette.amber',     hex('#dcb432') },
  { 'palette.steel',     hex('#6482a0') },
  { 'palette.pale',      hex('#f7f7f4') },
  { 'palette.night',     hex('#252936') },
  { 'palette.nightText', hex('#cfcfde') },

  -- Atoms — chrome palette
  { 'chrome.bg',        hex('#79829f') },              -- slate
  { 'chrome.shade',     hex('#5e6678') },              -- deeper slate
  { 'chrome.highlight', hex('#d6d9df') },              -- warm fog on slate

  -- Grid roles
  { 'colour.bg',               'palette.bg'                       },
  { 'colour.text',             'palette.shade'                    },
  { 'colour.offGrid',          'palette.positive'                 },
  { 'colour.overflow',         'palette.caution'                  },
  { 'colour.negative',         'palette.danger'                   },
  { 'colour.inactive',         'palette.inactive'                 },
  { 'colour.shadowed',         'colour.inactive'                  },
  { 'colour.cursor',           'palette.night'                    },
  { 'colour.cursorText',       'palette.nightText'                },
  { 'colour.rowNormal',        {'palette.bg',         0   }       },
  { 'colour.rowBeat',          {'palette.highlight',  0.4 }       },
  { 'colour.rowBarStart',      {'palette.mid',        0.4 }       },
  { 'colour.editCursor',       hex('#ffff00')                     },  -- one-off yellow
  { 'colour.selection',        {'palette.pale',       0.5 }       },
  { 'colour.scrollHandle',     'colour.text'                      },
  { 'colour.scrollBg',         'colour.bg'                        },
  { 'colour.accent',           'palette.mid'                      },
  { 'colour.mute',             'colour.negative'                  },
  { 'colour.solo',             'palette.amber'                    },
  { 'colour.separator',        {'palette.mid',        0.3 }       },
  { 'colour.tail',             {'palette.steel',      0.15}       },
  { 'colour.tailBord',         hex('#8caac8')                     },  -- one-off lighter steel
  { 'colour.ghost',            {'palette.steel',      0.9 }       },
  { 'colour.ghostNegative',    hex('#da8278', 0.9)                },  -- one-off faded red
  -- Lane strip (CC/PB/AT envelope visualiser above the tracker grid).
  { 'colour.laneAxis',         {'palette.inactive',   0.6 }       },
  { 'colour.laneRowDivider',   {'palette.inactive',   0.15}       },
  { 'colour.laneAnchor',       'colour.text'                      },
  { 'colour.laneAnchorActive', 'colour.negative'                  },
  { 'colour.laneEnvelope',     'colour.accent'                    },

  -- Chrome roles — toolbar (top band) and statusBar (bottom band).
  -- They share the chrome palette today; split aliases let either diverge.
  { 'colour.toolbar.bg',           {'palette.pale', 0.5}          },
  { 'colour.toolbar.text',         'palette.shade'                 },
  { 'colour.toolbar.button',       'palette.pale',                 },
  { 'colour.toolbar.buttonHover',  {'palette.pale',  0.42 }       },
  { 'colour.toolbar.buttonActive', {'palette.pale',  0.62 }       },
  { 'colour.toolbar.buttonBorder', {'palette.mid',    0.35  }       },
  { 'colour.toolbar.checkMark',    'palette.shade'                 },
  { 'colour.toolbar.popupBg',      'palette.pale'                  },
  { 'colour.statusBar.bg',         'chrome.bg'                    },
  { 'colour.statusBar.text',       'chrome.highlight'             },
  -- Floating editor windows (e.g. swing editor) want the *rendered*
  -- toolbar tone — opaque, matching what `{'palette.pale', 0.5}` looks
  -- like when blended over palette.bg. Pure palette.pale is too cool.
  -- Pre-computed blend: 0.5*pale + 0.5*bg ≈ #e9e7df.
  { 'colour.editor.bg',            hex('#e9e7df')                 },
  { 'laneStrip.rows',      4    },
  { 'laneStrip.visible',   true },
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

  local CONFIG_PREFIX = 'ctm_'
  local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. 'ctm_cfg.txt'

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
    local ok, result = pcall(util.unserialise, text)
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
    local ok, val = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', '', false)
    return ok and parse(val)
  end

  local function saveTake(tbl)
    if not take then
      print('Error! No take context for config storage')
      return
    end
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', util.serialise(tbl), true)
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
    fire('configChanged', {})
  end

  -- Drops the take half of the context, leaving track/global/project
  -- unchanged. Used by sample view, which is take-independent: it keys
  -- track-tier reads against an explicitly chosen track (see setTrack)
  -- and has no business reading take-tier values.
  function cm:clearTake()
    take = nil
    cache.take = {}
    fire('configChanged', {})
  end

  -- Sets the track context independently of any take. Reloads the track
  -- cache so subsequent reads resolve against the new track's P_EXT.
  -- setContext continues to derive track from take for tracker view.
  function cm:setTrack(newTrack)
    track = newTrack
    cache.track = loaders.track()
    fire('configChanged', {})
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
    fire('configChanged', { key = key, level = level })
  end

  function cm:remove(level, key)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    if cache[level] then
      cache[level][key] = nil
      savers[level](cache[level])
      fire('configChanged', { key = key, level = level })
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
    fire('configChanged', { level = level })
  end

  return cm
end
