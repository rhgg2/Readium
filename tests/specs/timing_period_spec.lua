-- Pin compositePeriodQN: smallest T at which all factor tiles complete.
-- Tile period = period × pulsesPerCycle, so lilt (pulsesPerCycle=2)
-- contributes double its declared period to the LCM. For rationals
-- nᵢ/dᵢ the result is lcm(nᵢ)/gcd(dᵢ).

local t = require('support')
require('util')
require('timing')

return {
  {
    name = 'empty composite falls back to 1 qn',
    run = function()
      t.eq(timing.compositePeriodQN({}), 1)
      t.eq(timing.compositePeriodQN(nil), 1)
    end,
  },
  {
    name = 'single classic factor: tile period = declared period',
    run = function()
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1, period = 2 },
      }, 2)
    end,
  },
  {
    name = 'single lilt factor: tile period doubles via pulsesPerCycle',
    run = function()
      t.eq(timing.compositePeriodQN{
        { atom = 'lilt', shift = 0.05, period = 2 },
      }, 4)
    end,
  },
  {
    name = 'lcm with lilt doubling: classic@2, lilt@3 → lcm(2,6) = 6',
    run = function()
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1, period = 2 },
        { atom = 'lilt',    shift = 0.05, period = 3 },
      }, 6)
    end,
  },
  {
    name = 'lcm with lilt doubling: classic@2, lilt@4 → lcm(2,8) = 8',
    run = function()
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1, period = 2 },
        { atom = 'lilt',    shift = 0.05, period = 4 },
      }, 8)
    end,
  },
  {
    name = 'fractional periods with lilt doubling: lcm(1,2)/gcd(2,3) = 2',
    run = function()
      -- classic {1,2} → tile n=1, d=2;  lilt {1,3} → tile n=2, d=3.
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1,  period = { 1, 2 } },
        { atom = 'lilt',    shift = 0.05, period = { 1, 3 } },
      }, 2)
    end,
  },
  {
    name = 'mixed: classic@1 + lilt@1/2 → lcm(1,2)/gcd(1,2) = 2',
    run = function()
      -- classic 1 → n=1, d=1;  lilt {1,2} → n=2, d=2.
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1,  period = 1 },
        { atom = 'lilt',    shift = 0.05, period = { 1, 2 } },
      }, 2)
    end,
  },
  {
    name = 'pocket doubles: classic@1 + pocket@1 → lcm(1,2) = 2',
    run = function()
      -- pocket has pulsesPerCycle=2, so its tile period doubles its
      -- declared period (matches lilt).
      t.eq(timing.compositePeriodQN{
        { atom = 'classic', shift = 0.1,  period = 1 },
        { atom = 'pocket',  shift = 0.05, period = 1 },
      }, 2)
    end,
  },
}
