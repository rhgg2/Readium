-- Pinning specs for the column-parts shape: ec:decorateCol stamps
-- col.parts (ordered name list), col.stopPos (absolute char offsets per
-- stop), col.partAt (part name per stop), col.partStart (stop index of
-- first stop in this stop's part), and col.width (sum of part widths +
-- inter-part separators). Behaviour-preserving refactor — these pin the
-- shape so a future addition (e.g. tracker-mode `sample` part) can't
-- silently drift the layout of existing col types.

local t = require('support')

-- decorateCol only reads col.type, col.showDelay and col.trackerMode.
-- We don't need a full harness — a minimal shell is enough.
local function mkCol(type, showDelay, trackerMode)
  return { type = type,
           showDelay   = showDelay   or false,
           trackerMode = trackerMode or false }
end

-- Decorate a col through ec; ec needs deps but only `grid` is touched by
-- decorateCol. Pass an empty grid.
local function decorate(col)
  local ec = newEditCursor{ grid = { cols = {}, numRows = 1 },
                            cm = { get = function() return 0 end },
                            rowPerBar = function() return 4 end }
  ec:decorateCol(col)
  return col
end

return {

  {
    name = 'note (no delay): parts={pitch,vel}; stopPos={0,2,4,5}; width=6',
    run = function()
      local c = decorate(mkCol('note', false))
      t.deepEq(c.parts,   {'pitch', 'vel'},  'parts')
      t.deepEq(c.stopPos, {0, 2, 4, 5},      'stopPos')
      t.eq    (c.width,   6,                 'width')
    end,
  },

  {
    name = 'note+delay: parts={pitch,vel,delay}; stopPos={0,2,4,5,7,8,9}; width=10',
    run = function()
      local c = decorate(mkCol('note', true))
      t.deepEq(c.parts,   {'pitch', 'vel', 'delay'},     'parts')
      t.deepEq(c.stopPos, {0, 2, 4, 5, 7, 8, 9},         'stopPos')
      t.eq    (c.width,   10,                            'width')
    end,
  },

  {
    name = 'pb: parts={pb}; stopPos={0,1,2,3}; width=4',
    run = function()
      local c = decorate(mkCol('pb'))
      t.deepEq(c.parts,   {'pb'},          'parts')
      t.deepEq(c.stopPos, {0, 1, 2, 3},    'stopPos')
      t.eq    (c.width,   4,               'width')
    end,
  },

  {
    -- cc / pa / at / pc all share the scalar shape — one 'val' part, two
    -- stops. Pin one representative; the registry would have to break to
    -- diverge them.
    name = 'scalar (cc): parts={val}; stopPos={0,1}; width=2',
    run = function()
      local c = decorate(mkCol('cc'))
      t.deepEq(c.parts,   {'val'},   'parts')
      t.deepEq(c.stopPos, {0, 1},    'stopPos')
      t.eq    (c.width,   2,         'width')
    end,
  },

  {
    name = 'partAt mirrors stops: note+delay = {pitch,pitch,vel,vel,delay,delay,delay}',
    run = function()
      local c = decorate(mkCol('note', true))
      t.deepEq(c.partAt,
        {'pitch','pitch','vel','vel','delay','delay','delay'}, 'partAt')
    end,
  },

  {
    -- partStart is the ordering primitive: stops with the same partStart
    -- belong to the same part; partStart values are strictly increasing
    -- across parts. selectionStopSpan and selUpdate compare partStart
    -- values rather than carrying a parallel numeric ord table.
    name = 'partStart pins ordering: note+delay = {1,1,3,3,5,5,5}',
    run = function()
      local c = decorate(mkCol('note', true))
      t.deepEq(c.partStart, {1,1,3,3,5,5,5}, 'partStart')
    end,
  },

  ----- Tracker mode pins
  -- The 'sample' part slots between pitch and vel when col.trackerMode
  -- is on. Width grows by 3 (2 chars + 1 separator). Existing parts
  -- preserve their internal stop offsets — only their absolute char
  -- positions shift right.

  {
    name = 'note tracker (no delay): parts={pitch,sample,vel}; stopPos={0,2,4,5,7,8}; width=9',
    run = function()
      local c = decorate(mkCol('note', false, true))
      t.deepEq(c.parts,   {'pitch', 'sample', 'vel'}, 'parts')
      t.deepEq(c.stopPos, {0, 2, 4, 5, 7, 8},         'stopPos')
      t.eq    (c.width,   9,                          'width')
      t.deepEq(c.partAt,
        {'pitch','pitch','sample','sample','vel','vel'}, 'partAt')
      t.deepEq(c.partStart, {1,1,3,3,5,5}, 'partStart')
    end,
  },

  {
    name = 'note tracker + delay: parts={pitch,sample,vel,delay}; stopPos={0,2,4,5,7,8,10,11,12}; width=13',
    run = function()
      local c = decorate(mkCol('note', true, true))
      t.deepEq(c.parts,   {'pitch', 'sample', 'vel', 'delay'}, 'parts')
      t.deepEq(c.stopPos, {0, 2, 4, 5, 7, 8, 10, 11, 12},      'stopPos')
      t.eq    (c.width,   13,                                  'width')
      t.deepEq(c.partAt,
        {'pitch','pitch','sample','sample','vel','vel',
         'delay','delay','delay'}, 'partAt')
      t.deepEq(c.partStart, {1,1,3,3,5,5,7,7,7}, 'partStart')
    end,
  },
}
