-- Pure-Lua test harness for trackerManager and viewManager. Stubs out
-- REAPER and midiManager; loads the real tm/vm/cm modules unchanged.
--
-- Caller sets package.path (see run.lua) before requiring this module.

local harness = {}

local fakeReaper = require('fakeReaper').new()
_G.reaper = fakeReaper

-- loadModule is how the production modules resolve their dependencies.
-- We honour the call for real modules (via require) but swallow it for
-- midiManager — our fake has already installed newMidiManager.
_G.loadModule = function(name)
  if name == 'midiManager' then return end
  require(name)
end

require('fakeMidiManager')  -- installs newMidiManager global
require('util')
require('timing')
require('microtuning')
require('configManager')
require('trackerManager')
require('commandManager')
require('viewManager')

-- Build a fresh scenario. Keys:
--   seed      : seed payload for the fake mm (notes, ccs, sysexes, resolution, length, timeSigs)
--   config    : { [level] = { key = value, ... } } written via cm:assign
--   take      : override the opaque take token (default 'take1')
function harness.mk(opts)
  opts = opts or {}

  -- Fresh reaper state per scenario
  fakeReaper = require('fakeReaper').new()
  _G.reaper  = fakeReaper

  local take = opts.take or 'take1'
  local item, track = take .. '/item', take .. '/track'
  fakeReaper:bindTake(take, item, track)

  local mm = newMidiManager({
    take       = take,
    resolution = opts.seed and opts.seed.resolution or 240,
    length     = opts.seed and opts.seed.length     or 3840,
    timeSigs   = opts.seed and opts.seed.timeSigs,
  })

  local cm = newConfigManager()
  cm:setContext(take)
  if opts.config then
    for level, tbl in pairs(opts.config) do cm:assign(level, tbl) end
  end

  if opts.seed then mm:seed(opts.seed) end

  local tm = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)
  local vm = newViewManager(tm, cm, cmgr)

  return { fm = mm, cm = cm, tm = tm, vm = vm, cmgr = cmgr, reaper = fakeReaper }
end

return harness
