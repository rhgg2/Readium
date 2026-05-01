-- See docs/tuning.md for the model and API reference.
-- @noindex

tuning = {}
local M = tuning

----- Temperament presets

-- Scan from the end: every trailing C-variant step (e.g. C↓ in 31EDO)
-- is enharmonically the next C and belongs to the octave above.
local function computeOctaveStep(stepNames)
  for i = #stepNames, 1, -1 do
    if stepNames[i]:sub(1, 1) ~= 'C' then return i + 1 end
  end
  return 1
end

local function edo(n, names)
  local cents = {}
  for i = 1, n do cents[i] = math.floor((i - 1) * 1200 / n + 0.5) end
  return {
    name       = n .. 'EDO',
    period     = 1200,
    cents      = cents,
    stepNames  = names,
    octaveStep = computeOctaveStep(names),
  }
end

-- Seed only — never consulted at slot-resolution time. Populates the
-- "copy into library" UI menu, mirroring `timing.presets`.
M.presets = {
  ['12EDO'] = edo(12, {
    'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'
  }),
  ['19EDO'] = edo(19, {
    'C-','C#','Db','D-','D#','Eb','E-','E#','F-','F#','Gb',
    'G-','G#','Ab','A-','A#','Bb','B-','B#'
  }),
  ['31EDO'] = edo(31, {
    'C-','C↑','C#','Db','D↓','D-','D↑','D#','Eb','E↓','E-',
    'E↑','F↓','F-','F↑','F#','Gb','G↓','G-','G↑','G#','Ab',
    'A↓','A-','A↑','A#','Bb','B↓','B-','B↑','C↓'
  }),
  ['53EDO'] = edo(53, {
    'C-','C↑','C⇑','C⇈','Db','C#','D⇊','D⇓','D↓','D-','D↑',
    'D⇑','D⇈','Eb','D#','E⇊','E⇓','E↓','E-','E↑','E⇑','F↓',
    'F-','F↑','F⇑','F⇈','Gb','F#','G⇊','G⇓','G↓','G-','G↑',
    'G⇑','G⇈','Ab','G#','A⇊','A⇓','A↓','A-','A↑','A⇑','A⇈',
    'Bb','A#','B⇊','B⇓','B↓','B-','B↑','B⇑','C↓'
  }),
}

-- Resolve a temperament slot name within the project library. Mirrors
-- `timing.findShape`: presets are seed-only, never consulted here.
function M.findTemper(name, userLib)
  if not (name and userLib) then return nil end
  return userLib[name]
end

----- Coordinate conversions

function M.midiToStep(temper, midi, detune)
  detune = detune or 0
  local cents  = midi * 100 + detune
  local period = temper.period
  local octave = math.floor(cents / period)
  local res    = cents - octave * period
  local steps  = temper.cents

  local best, bestDist = 1, math.abs(res - steps[1])
  for i = 2, #steps do
    local d = math.abs(res - steps[i])
    if d < bestDist then best, bestDist = i, d end
  end
  -- Step 1 of the next period sits at cents = period.
  if math.abs(res - period) < bestDist then
    best, octave = 1, octave + 1
  end

  return best, octave - 1
end

function M.stepToMidi(temper, step, octave)
  local steps, n = temper.cents, #temper.cents
  while step < 1 do step = step + n; octave = octave - 1 end
  while step > n do step = step - n; octave = octave + 1 end

  local cents  = (octave + 1) * temper.period + steps[step]
  local midi   = math.floor(cents / 100 + 0.5)
  local detune = cents - midi * 100

  if midi < 0 then
    detune, midi = detune + 100 * midi, 0
  elseif midi > 127 then
    detune, midi = detune + 100 * (midi - 127), 127
  end

  return midi, detune
end

function M.snap(temper, midi, detune)
  return M.stepToMidi(temper, M.midiToStep(temper, midi, detune))
end

function M.transposeStep(temper, midi, detune, n)
  local step, oct = M.midiToStep(temper, midi, detune)
  return M.stepToMidi(temper, step + n, oct)
end

----- Display

-- Octave -1 renders as "M" so the cell width stays fixed.
local function octaveLabel(o)
  return o == -1 and 'M' or tostring(o)
end

function M.stepToText(temper, step, octave)
  if step >= temper.octaveStep then octave = octave + 1 end
  return temper.stepNames[step] .. octaveLabel(octave)
end

return M
