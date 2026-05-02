-- Pins the take-properties dialog's commit path across all three modes:
--   resize  — events past the new end are deleted; spanning notes clamped.
--   rescale — logical-frame stretch: every event on row r goes to row f·r.
--             Under identity swing this scales ppq by f; ppqL scales by f.
--             delay scales by f. No events deleted.
--   tile    — replicates the [0, oldPpq) pattern at offsets k·oldPpq;
--             copies past newPpq dropped, endppqs clamped.
--
-- Layer split under test:
--   vm:applyTakeProperties — converts rows → ppq, dispatches by mode.
--   tm:setLength / rescaleLength / tileLength — own the event walk.
--   tm:setName             — proxies to mm:setName.

local t = require('support')

-- Default harness: resolution=240, rpb=4, length=3840 → ppqPerRow=60, 64 rows.
local PPR = 60

return {

  {
    name = 'rename only: name written, length untouched',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,   endppq = 60,  chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 600, endppq = 660, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
      }}
      h.fm:setName('Original')
      h.vm:applyTakeProperties{ name = 'Renamed', rows = h.vm.grid.numRows }

      t.eq(h.fm:name(),   'Renamed', 'name written')
      t.eq(h.fm:length(), 3840,      'length unchanged')
      t.eq(#h.fm:dump().notes, 2,    'no notes deleted')
    end,
  },

  {
    name = 'grow: setLength called, no events mutated',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 3780, endppq = 3840, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
      }}
      -- 64 → 128 rows
      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 128 }

      t.eq(h.fm:length(), 128 * PPR, 'length grown')
      local notes = h.fm:dump().notes
      t.eq(#notes,        2,         'no notes deleted')
      t.eq(notes[2].ppq,  3780,      'tail note untouched')
      t.eq(notes[2].endppq, 3840,    'tail endppq untouched')
    end,
  },

  {
    name = 'shrink: events past boundary deleted; spanning note clamped',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          -- entirely before new end (32 rows = ppq 1920)
          { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          -- spans the boundary: starts before, ends after
          { ppq = 1800, endppq = 2400, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
          -- starts at-or-past the boundary
          { ppq = 1920, endppq = 1980, chan = 1, pitch = 67, vel = 100, detune = 0, delay = 0 },
          { ppq = 3000, endppq = 3060, chan = 2, pitch = 60, vel = 100, detune = 0, delay = 0 },
        },
        ccs = {
          -- before boundary (kept)
          { ppq = 100,  msgType = 'cc', cc = 1, chan = 1, val = 64 },
          -- at boundary (deleted)
          { ppq = 1920, msgType = 'cc', cc = 1, chan = 1, val = 100 },
          -- past boundary (deleted)
          { ppq = 3000, msgType = 'cc', cc = 1, chan = 1, val = 0 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 32 }

      t.eq(h.fm:length(), 32 * PPR, 'length shrunk')

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'two notes survive')
      -- Note 1: untouched
      t.eq(notes[1].ppq,    0,    'note 1 onset')
      t.eq(notes[1].endppq, 60,   'note 1 end')
      -- Note 2: spanning note, endppq clamped to boundary
      t.eq(notes[2].ppq,    1800, 'spanning note onset preserved')
      t.eq(notes[2].endppq, 1920, 'spanning note endppq clamped to boundary')

      local ccs = h.fm:dump().ccs
      t.eq(#ccs, 1, 'only the pre-boundary cc survives')
      t.eq(ccs[1].ppq, 100, 'surviving cc is the early one')
    end,
  },

  ----- rescale ----------------------------------------------------------

  {
    name = 'rescale grow 2×: ppq + endppq scale, length doubles, no deletions',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 600,  endppq = 660,  chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
          { ppq = 3780, endppq = 3840, chan = 1, pitch = 67, vel = 100, detune = 0, delay = 0 },
        },
        ccs = {
          { ppq = 600, msgType = 'cc', cc = 1, chan = 1, val = 64 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 128, mode = 'rescale' }

      t.eq(h.fm:length(), 128 * PPR, 'length doubles')
      local notes = h.fm:dump().notes
      t.eq(#notes, 3, 'no notes deleted')
      t.eq(notes[1].ppq,    0,    'note 1 onset stays at 0')
      t.eq(notes[1].endppq, 120,  'note 1 end doubles')
      t.eq(notes[2].ppq,    1200, 'note 2 onset doubles')
      t.eq(notes[2].endppq, 1320, 'note 2 end doubles')
      t.eq(notes[3].ppq,    7560, 'note 3 onset doubles')
      t.eq(notes[3].endppq, 7680, 'note 3 end doubles')

      local ccs = h.fm:dump().ccs
      t.eq(#ccs, 1, 'cc preserved')
      t.eq(ccs[1].ppq, 1200, 'cc ppq doubles')
    end,
  },

  {
    name = 'rescale shrink 0.5×: ppq + endppq halve, length halves',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,    endppq = 120,  chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 1200, endppq = 1320, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 32, mode = 'rescale' }

      t.eq(h.fm:length(), 32 * PPR, 'length halves')
      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'no notes deleted (rescale never deletes)')
      t.eq(notes[1].endppq, 60,   'note 1 end halves')
      t.eq(notes[2].ppq,    600,  'note 2 onset halves')
      t.eq(notes[2].endppq, 660,  'note 2 end halves')
    end,
  },

  {
    name = 'rescale scales delay: realised stretch is uniform when swing is identity',
    run = function(harness)
      -- delay = 50 milli-QN at res=240 → delayToPPQ = round(240·50/1000) = 12.
      -- realised ppq = intent + 12 = 600 + 12 = 612.
      -- After 2× rescale: intent = 1200, delay = 100 milli-QN → delayToPPQ = 24.
      -- realised = 1200 + 24 = 1224 = 2 × 612 (uniform stretch). ✓
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 612, endppq = 660, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 50 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 128, mode = 'rescale' }

      local notes = h.fm:dump().notes
      t.eq(notes[1].delay,  100,  'delay doubles')
      t.eq(notes[1].ppq,    1224, 'realised onset = 2× original (intent 1200 + delayPPQ 24)')
      t.eq(notes[1].endppq, 1320, 'endppq doubles (no delay component)')
    end,
  },

  ----- tile -------------------------------------------------------------

  {
    name = 'tile grow 2×: pattern duplicated once at oldPpq offset',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 600,  endppq = 660,  chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
        ccs = {
          { ppq = 100, msgType = 'cc', cc = 1, chan = 1, val = 64 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 128, mode = 'tile' }

      t.eq(h.fm:length(), 128 * PPR, 'length doubles')
      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(#notes, 4, 'two originals + two copies')
      t.eq(notes[1].ppq, 0,    'original note 1 untouched')
      t.eq(notes[2].ppq, 600,  'original note 2 untouched')
      t.eq(notes[3].ppq, 3840, 'copy of note 1 at oldPpq')
      t.eq(notes[3].pitch, 60, 'copy preserves pitch')
      t.eq(notes[4].ppq, 4440, 'copy of note 2 at oldPpq + 600')
      t.eq(notes[4].pitch, 64, 'copy preserves pitch')

      local ccs = h.fm:dump().ccs
      table.sort(ccs, function(a, b) return a.ppq < b.ppq end)
      t.eq(#ccs, 2,           'cc duplicated')
      t.eq(ccs[1].ppq, 100,   'original cc')
      t.eq(ccs[2].ppq, 3940,  'cc copy at oldPpq + 100')
    end,
  },

  {
    name = 'tile non-multiple 1.5×: full tile + partial tail; events past newPpq dropped',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          -- early in tile: copy fits in partial tail (oldPpq + 600 = 4440 < 5760)
          { ppq = 600,  endppq = 660,  chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          -- late in tile: copy lands past newPpq (oldPpq + 3000 = 6840 > 5760) — dropped
          { ppq = 3000, endppq = 3060, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
      }}

      -- 64 → 96 rows = 1.5 tiles. ceil(96/64)=2, so k=1 only.
      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 96, mode = 'tile' }

      t.eq(h.fm:length(), 96 * PPR, 'length 1.5×')
      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(#notes, 3, 'two originals + one in-bounds copy (other dropped)')
      t.eq(notes[1].ppq, 600,  'original 1')
      t.eq(notes[2].ppq, 3000, 'original 2')
      t.eq(notes[3].ppq, 4440, 'copy of note 1 at oldPpq + 600')
    end,
  },

  {
    name = 'tile clamps copy endppq at newPpq',
    run = function(harness)
      -- Note ends near tile boundary; copy's endppq would land past newPpq → clamp.
      -- newPpq = 96·60 = 5760. Copy at ppq=600+3840=4440, endppq would be 5800 → clamp to 5760.
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 600, endppq = 1960, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 96, mode = 'tile' }

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(#notes, 2, 'original + copy')
      t.eq(notes[1].endppq, 1960, 'original untouched')
      t.eq(notes[2].ppq,    4440, 'copy onset at oldPpq + 600')
      t.eq(notes[2].endppq, 5760, 'copy endppq clamped at newPpq')
    end,
  },

  {
    name = 'tile preserves cc number, fake-pb flag, and arbitrary metadata on copies',
    -- Pins the bug fix: the column projection drops cc.cc, pb.fake, and
    -- anything beyond a hardcoded field list. Tile must walk mm directly so
    -- copies are bit-for-bit replicas modulo the ppq shift.
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        },
        ccs = {
          -- distinct cc number — verifies col.cc isn't lost
          { ppq = 100, msgType = 'cc', cc = 74, chan = 1, val = 64 },
          -- fake pb — the marker the column projection drops
          { ppq = 200, msgType = 'pb', chan = 1, val = 1024, fake = true },
          -- cc with custom metadata field — verifies arbitrary fields ride along
          { ppq = 300, msgType = 'cc', cc = 1, chan = 1, val = 32, label = 'alpha' },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 128, mode = 'tile' }

      local ccs = h.fm:dump().ccs
      table.sort(ccs, function(a, b) return a.ppq < b.ppq end)
      t.eq(#ccs, 6, 'three originals + three copies')

      -- Copies live at oldPpq (3840) + source ppq: cc#74@3940, pb@4040, cc#1@4140.
      t.eq(ccs[4].ppq,     3940,    'cc#74 copy ppq')
      t.eq(ccs[4].cc,      74,      'cc number preserved')
      t.eq(ccs[4].msgType, 'cc',    'msgType preserved')

      t.eq(ccs[5].ppq,     4040,    'pb copy ppq')
      t.eq(ccs[5].msgType, 'pb',    'pb msgType preserved')
      t.eq(ccs[5].fake,    true,    'pb fake flag preserved')
      t.eq(ccs[5].val,     1024,    'pb val preserved verbatim')

      t.eq(ccs[6].ppq,     4140,    'cc#1 copy ppq')
      t.eq(ccs[6].cc,      1,       'cc#1 copy cc number')
      t.eq(ccs[6].label,   'alpha', 'custom metadata field rides along')
    end,
  },

  {
    name = 'tile shrink falls through to truncation (resize semantics)',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = {
          { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { ppq = 3000, endppq = 3060, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
        },
      }}

      h.vm:applyTakeProperties{ name = h.fm:name(), rows = 32, mode = 'tile' }

      t.eq(h.fm:length(), 32 * PPR, 'length shrunk')
      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'late note deleted (tile-shrink == resize-shrink)')
      t.eq(notes[1].ppq, 0, 'early note kept')
    end,
  },

}
