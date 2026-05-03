-- Pin-tests for fs.lua. The string helpers (isAudio/basename/parent/join)
-- are pure; the enumeration wrappers (listDirs/listAudioFiles) get their
-- input by stubbing reaper.Enumerate* on the fakeReaper, which the
-- harness installs as _G.reaper.

local t = require('support')
require('fs')

local function stubEnum(h, key, items)
  h.reaper[key] = function(_path, i)
    return items[i + 1]
  end
end

return {
  {
    name = "isAudio recognises common audio extensions case-insensitively",
    run = function(harness)
      t.eq(fs.isAudio('foo.wav'),  true)
      t.eq(fs.isAudio('FOO.WAV'),  true)
      t.eq(fs.isAudio('a.Aiff'),   true)
      t.eq(fs.isAudio('a.flac'),   true)
      t.eq(fs.isAudio('a.mp3'),    true)
      t.eq(fs.isAudio('a.ogg'),    true)
      t.eq(fs.isAudio('a.m4a'),    true)
    end,
  },
  {
    name = "isAudio rejects non-audio and missing extensions",
    run = function(harness)
      t.eq(fs.isAudio('readme.txt'), false)
      t.eq(fs.isAudio('README'),     false)
      t.eq(fs.isAudio(''),           false)
    end,
  },
  {
    name = "basename returns the last path component",
    run = function(harness)
      t.eq(fs.basename('/a/b/c.wav'), 'c.wav')
      t.eq(fs.basename('c.wav'),      'c.wav')
      t.eq(fs.basename('C:\\x\\y'),   'y')
    end,
  },
  {
    name = "parent strips the last component, '' for top-level",
    run = function(harness)
      t.eq(fs.parent('/a/b/c'), '/a/b')
      t.eq(fs.parent('/a'),     '')
      t.eq(fs.parent('a'),      '')
    end,
  },
  {
    name = "join inserts '/' unless the left already ends with a separator",
    run = function(harness)
      t.eq(fs.join('/a',  'b'), '/a/b')
      t.eq(fs.join('/a/', 'b'), '/a/b')
      t.eq(fs.join('C:\\x\\', 'y'), 'C:\\x\\y')
    end,
  },
  {
    name = "listDirs returns subdirectory names case-insensitively sorted",
    run = function(harness)
      local h = harness.mk()
      stubEnum(h, 'EnumerateSubdirectories', { 'Zeta', 'alpha', 'Mu' })
      t.deepEq(fs.listDirs('/anywhere'), { 'alpha', 'Mu', 'Zeta' })
    end,
  },
  {
    name = "listAudioFiles filters non-audio and sorts case-insensitively",
    run = function(harness)
      local h = harness.mk()
      stubEnum(h, 'EnumerateFiles',
        { 'README.txt', 'Sample.WAV', 'a.wav', 'm.flac', '.DS_Store' })
      t.deepEq(fs.listAudioFiles('/anywhere'),
        { 'a.wav', 'm.flac', 'Sample.WAV' })
    end,
  },
  {
    name = "listAudioFiles empty when no audio present",
    run = function(harness)
      local h = harness.mk()
      stubEnum(h, 'EnumerateFiles', { 'README.txt', 'notes.md' })
      t.deepEq(fs.listAudioFiles('/anywhere'), {})
    end,
  },
}
