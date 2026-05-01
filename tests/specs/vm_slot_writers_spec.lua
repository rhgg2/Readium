-- Pin the dual-level write contract for slot selections (temper, swing,
-- colSwing). The view-picker UI depends on:
--   - temper / swing: write at project AND track, so a fresh take on a
--     new track inherits the most recent selection (project), while
--     siblings on an existing track inherit from their track.
--   - colSwing: track-only — per-channel maps shouldn't bleed across
--     tracks via the project mirror.

local t = require('support')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }
local classic67 = { { atom = 'classic', shift = 0.17, period = 1 } }

return {
  ----------------------------------------------------------------
  -- temper: project + track mirror
  ----------------------------------------------------------------
  {
    name = 'setTemperSlot writes the slot at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:setTemperSlot('19EDO')
      t.eq(h.cm:getAt('project', 'temper'), '19EDO', 'project mirror set')
      t.eq(h.cm:getAt('track',   'temper'), '19EDO', 'track  selection set')
    end,
  },
  {
    name = 'setTemperSlot(nil) clears at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { temper = '19EDO',
                      tempers = { ['19EDO'] = tuning.presets['19EDO'] } },
          track   = { temper = '19EDO' },
        },
      }
      h.vm:setTemperSlot(nil)
      t.eq(h.cm:getAt('project', 'temper'), nil, 'project cleared')
      t.eq(h.cm:getAt('track',   'temper'), nil, 'track  cleared')
    end,
  },
  {
    name = 'setTemperSlot("") clears at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { temper = '19EDO' }, track = { temper = '19EDO' } },
      }
      h.vm:setTemperSlot('')
      t.eq(h.cm:getAt('project', 'temper'), nil, 'project cleared on empty string')
      t.eq(h.cm:getAt('track',   'temper'), nil, 'track  cleared on empty string')
    end,
  },

  ----------------------------------------------------------------
  -- swing: project + track mirror
  ----------------------------------------------------------------
  {
    name = 'setSwingSlot writes the slot at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setSwingSlot('c58')
      t.eq(h.cm:getAt('project', 'swing'), 'c58', 'project mirror set')
      t.eq(h.cm:getAt('track',   'swing'), 'c58', 'track  selection set')
    end,
  },
  {
    name = 'setSwingSlot(nil) clears at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swing = 'c58', swings = { c58 = classic58 } },
          track   = { swing = 'c58' },
        },
      }
      h.vm:setSwingSlot(nil)
      t.eq(h.cm:getAt('project', 'swing'), nil, 'project cleared')
      t.eq(h.cm:getAt('track',   'swing'), nil, 'track  cleared')
    end,
  },

  ----------------------------------------------------------------
  -- colSwing: track-only, no project mirror
  ----------------------------------------------------------------
  {
    name = 'setColSwingSlot writes at track only — project is left alone',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local trackMap   = h.cm:getAt('track',   'colSwing') or {}
      local projectMap = h.cm:getAt('project', 'colSwing')
      t.eq(trackMap[3], 'c58', 'track holds the per-channel entry')
      t.eq(projectMap, nil,    'project is not mirrored — no cross-track bleed')
    end,
  },
  {
    name = 'setColSwingSlot preserves entries on other channels',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58, c67 = classic67 } },
          track   = { colSwing = { [1] = 'c58', [5] = 'c67' } },
        },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local map = h.cm:getAt('track', 'colSwing')
      t.eq(map[1], 'c58', 'channel 1 entry preserved')
      t.eq(map[3], 'c58', 'channel 3 entry written')
      t.eq(map[5], 'c67', 'channel 5 entry preserved')
    end,
  },
  {
    name = 'setColSwingSlot(chan, nil) removes only that channel',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58, c67 = classic67 } },
          track   = { colSwing = { [1] = 'c58', [3] = 'c58', [5] = 'c67' } },
        },
      }
      h.vm:setColSwingSlot(3, nil)
      local map = h.cm:getAt('track', 'colSwing') or {}
      t.eq(map[1], 'c58', 'siblings survive')
      t.eq(map[3], nil,   'target channel cleared')
      t.eq(map[5], 'c67', 'siblings survive')
    end,
  },

  ----------------------------------------------------------------
  -- Inheritance: the *point* of the project mirror
  ----------------------------------------------------------------
  {
    -- After picking on track A, a fresh track (no track-level value)
    -- should see the most recent selection through the project tier.
    name = 'project mirror lets a track with no own value inherit the most recent pick',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['31EDO'] = tuning.presets['31EDO'] } } },
      }
      h.vm:setTemperSlot('31EDO')

      -- Drop the track-level entry to simulate switching to a track that
      -- has never had an explicit pick. cm:get must fall through to project.
      h.cm:remove('track', 'temper')
      t.eq(h.cm:get('temper'), '31EDO',
           'fresh-track view sees the most recent selection via project')
    end,
  },
}
