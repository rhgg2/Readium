-- Pin-tests for the numeric-edit primitives hoisted from viewManager into
-- util.lua (setDigit, snapTo, nudgedScalar) and the cmgr:noteChars lookup
-- (absorbed from the former noteInput module).
-- Each case encodes an invariant that the refactor must preserve; if any
-- fails, the hoist has changed observable behaviour.

local t = require('support')
require('util')
require('commandManager')

local function byte(c) return string.byte(c) end

-- Minimal cm stub: cmgr only calls cm:get('noteLayout').
local function stubCm(layout)
  return { get = function(_, _) return layout end }
end

return {
  --------------------------------------------------------------------
  -- util:setDigit
  --------------------------------------------------------------------
  {
    name = 'setDigit: places ones digit in decimal, zeroing below',
    run = function()
      -- pos=0 (ones), base=10: any existing ones are overwritten.
      t.eq(util:setDigit(47, 3, 0, 10, false), 43)
      t.eq(util:setDigit(9,  7, 0, 10, false), 7)
    end,
  },
  {
    name = 'setDigit: places tens digit in decimal, zeroing ones',
    run = function()
      -- pos=1 (tens) zeroes the ones place.
      t.eq(util:setDigit(47, 8, 1, 10, false), 80)
    end,
  },
  {
    name = 'setDigit: hex base, keeps places above the target',
    run = function()
      -- 0x7F = 127. pos=1 sets nibble 1 (high); low nibble cleared.
      t.eq(util:setDigit(0x7F, 0x3, 1, 16, false), 0x30)
      -- pos=0 sets nibble 0 (low); high nibble kept.
      t.eq(util:setDigit(0x7F, 0x3, 0, 16, false), 0x73)
    end,
  },
  {
    name = 'setDigit: half adds place/2 (shift-digit half-step entry)',
    run = function()
      -- With half=true at ones place in base 10, result = d*1 + 0 (1//2==0).
      t.eq(util:setDigit(0, 5, 0, 10, true), 5)
      -- At tens place, half adds 10//2 = 5.
      t.eq(util:setDigit(0, 5, 1, 10, true), 55)
    end,
  },

  --------------------------------------------------------------------
  -- util:snapTo
  --------------------------------------------------------------------
  {
    name = 'snapTo: positive dir snaps up; on-boundary values move a full step',
    run = function()
      t.eq(util:snapTo(13, 1, 8), 16)  -- between 8 and 16, snaps to 16
      t.eq(util:snapTo(16, 1, 8), 24)  -- on boundary, moves a full interval
      t.eq(util:snapTo(0,  1, 8), 8)
    end,
  },
  {
    name = 'snapTo: negative dir snaps down; on-boundary values move a full step',
    run = function()
      t.eq(util:snapTo(13, -1, 8), 8)
      t.eq(util:snapTo(16, -1, 8), 8)  -- on boundary, still moves down
      t.eq(util:snapTo(0,  -1, 8), -8)
    end,
  },

  --------------------------------------------------------------------
  -- util:nudgedScalar
  --------------------------------------------------------------------
  {
    name = 'nudgedScalar: no interval → unit step, clamped to bounds',
    run = function()
      t.eq(util:nudgedScalar(100, 1, 127,  1, nil), 101)
      t.eq(util:nudgedScalar(127, 1, 127,  1, nil), 127)  -- clamped
      t.eq(util:nudgedScalar(1,   1, 127, -1, nil), 1)    -- clamped
    end,
  },
  {
    name = 'nudgedScalar: with interval, snaps and then clamps',
    run = function()
      -- velocity-like: coarse=8
      t.eq(util:nudgedScalar(100, 1, 127,  1, 8), 104)  -- 13*8=104
      t.eq(util:nudgedScalar(120, 1, 127,  1, 8), 127)  -- snap 128 clamped
      t.eq(util:nudgedScalar(5,   1, 127, -1, 8), 1)    -- snap 0 clamped to 1
    end,
  },

  --------------------------------------------------------------------
  -- cmgr:noteChars (absorbed noteInput)
  --------------------------------------------------------------------
  {
    name = 'cmgr:noteChars colemak: Z-row maps base octave, semi 0',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('z')), { 0, 0 })
    end,
  },
  {
    name = 'cmgr:noteChars colemak: Q-row maps +1 octave',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('q')), { 0, 1 })
    end,
  },
  {
    name = 'cmgr:noteChars colemak: semi increments along the row',
    run = function()
      -- colemak Z-row: z,r,x,s,c,v,... → x is index 3, so semi=2.
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('x')), { 2, 0 })
    end,
  },
  {
    name = 'cmgr:noteChars azerty: accepts Unicode codepoints as keys',
    run = function()
      -- azerty row 2 has 233 ('é') at index 2 → {semi=1, octOff=1}.
      local cmgr = newCommandManager(stubCm('azerty'))
      t.deepEq(cmgr:noteChars(233), { 1, 1 })
    end,
  },
  {
    name = 'cmgr.layouts: all four layouts present',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      for _, name in ipairs{ 'qwerty', 'colemak', 'dvorak', 'azerty' } do
        t.truthy(cmgr.layouts[name], name .. ' layout present')
      end
    end,
  },
  {
    name = 'cmgr:noteChars: unbound char returns nil',
    run = function()
      local cmgr = newCommandManager(stubCm('qwerty'))
      t.eq(cmgr:noteChars(byte('`')), nil)
    end,
  },
}
