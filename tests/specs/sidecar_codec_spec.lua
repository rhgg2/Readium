-- Pin-tests for the sidecar body codec — the wire format proved out by
-- design/cc-sidecar-spike.md. We're encoding what REAPER will frame with
-- F0/F7 on serialise; the codec deals only in the unframed body.

local t = require('support')
_G.loadModule = _G.loadModule or function(n) require(n) end
require('util')

-- midiManager.lua defines newMidiManager as a side-effect; the harness has
-- a fake under that name and we don't want to clobber it for later specs.
local saved = _G.newMidiManager
require('midiManager')
_G.newMidiManager = saved

local sr = newSidecarReconciler()

-- Spike payload: msgType=cc, chan=1 (=>0 on wire), cc=7, val=64, uuid='AB'=371.
local SPIKE_BODY = '\x7D\x52\x44\x4D\x0B\x00\x07\x40\x00\x41\x42'

return {
  {
    name = 'encode matches the spike payload byte-for-byte',
    run = function()
      local body = sr:encode{ uuid = 371, msgType = 'cc', chan = 1, cc = 7, val = 64 }
      t.eq(body, SPIKE_BODY)
    end,
  },

  {
    name = 'decode of the spike payload recovers all fields in cc shape',
    run = function()
      t.deepEq(sr:decode(SPIKE_BODY),
        { uuid = 371, msgType = 'cc', chan = 1, cc = 7, val = 64 })
    end,
  },

  {
    name = 'round-trip preserves cc / pa / pc / at fields',
    run = function()
      local cases = {
        { uuid = 1,    msgType = 'cc', chan = 1,  cc = 7,     val = 0   },
        { uuid = 35,   msgType = 'cc', chan = 16, cc = 64,    val = 127 },
        { uuid = 36,   msgType = 'pa', chan = 5,  pitch = 60, val = 100 },
        { uuid = 1295, msgType = 'pc', chan = 1,              val = 42  },
        { uuid = 1296, msgType = 'at', chan = 8,              val = 99  },
      }
      for _, c in ipairs(cases) do
        t.deepEq(sr:decode(sr:encode(c)), c, 'msgType=' .. c.msgType)
      end
    end,
  },

  {
    name = 'pb round-trips the full signed range',
    run = function()
      local cases = {
        { uuid = 1, msgType = 'pb', chan = 1, val = -8192 },
        { uuid = 2, msgType = 'pb', chan = 1, val = 0     },
        { uuid = 3, msgType = 'pb', chan = 1, val = 8191  },
        { uuid = 4, msgType = 'pb', chan = 9, val = -1    },
        { uuid = 5, msgType = 'pb', chan = 9, val = 4096  },
      }
      for _, c in ipairs(cases) do
        t.deepEq(sr:decode(sr:encode(c)), c, 'val=' .. c.val)
      end
    end,
  },

  {
    name = 'decode returns nil for non-Readium bytes',
    run = function()
      t.eq(sr:decode('\xF0\x43\x12\x00\xF7'), nil, 'manufacturer 0x43')
      t.eq(sr:decode('hello world'),          nil, 'random text')
      t.eq(sr:decode(''),                     nil, 'empty')
      t.eq(sr:decode(nil),                    nil, 'nil')
    end,
  },

  {
    name = 'decode rejects unknown type nibble',
    run = function()
      -- Magic + bad type byte (0x05, not in 0xA..0xE) + filler + uuid char
      local bad = '\x7D\x52\x44\x4D\x05\x00\x00\x00\x00\x41'
      t.eq(sr:decode(bad), nil)
    end,
  },

  {
    name = 'decode rejects too-short body',
    run = function()
      -- 9 bytes — one short of the minimum (4 magic + 5 fields + 1 uuid char)
      t.eq(sr:decode('\x7D\x52\x44\x4D\x0B\x00\x00\x00\x00'), nil)
    end,
  },

  {
    name = 'encode returns nil for unknown msgType',
    run = function()
      t.eq(sr:encode{ uuid = 1, msgType = 'bogus', chan = 1, val = 0 }, nil)
    end,
  },
}
