-- See docs/microtuning.md for the model and API reference.
-- @noindex

microtuning = {}
local M = microtuning

----- Tuning library

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

M.tunings = {
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

function M.findTuning(name)
  return M.tunings[name]
end

----- Coordinate conversions

function M.midiToStep(tuning, midi, detune)
  detune = detune or 0
  local cents  = midi * 100 + detune
  local period = tuning.period
  local octave = math.floor(cents / period)
  local res    = cents - octave * period
  local steps  = tuning.cents

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

function M.stepToMidi(tuning, step, octave)
  local steps, n = tuning.cents, #tuning.cents
  while step < 1 do step = step + n; octave = octave - 1 end
  while step > n do step = step - n; octave = octave + 1 end

  local cents  = (octave + 1) * tuning.period + steps[step]
  local midi   = math.floor(cents / 100 + 0.5)
  local detune = cents - midi * 100

  if midi < 0 then
    detune, midi = detune + 100 * midi, 0
  elseif midi > 127 then
    detune, midi = detune + 100 * (midi - 127), 127
  end

  return midi, detune
end

function M.snap(tuning, midi, detune)
  return M.stepToMidi(tuning, M.midiToStep(tuning, midi, detune))
end

function M.transposeStep(tuning, midi, detune, n)
  local step, oct = M.midiToStep(tuning, midi, detune)
  return M.stepToMidi(tuning, step + n, oct)
end

----- Display

-- Octave -1 renders as "M" so the cell width stays fixed.
local function octaveLabel(o)
  return o == -1 and 'M' or tostring(o)
end

function M.stepToText(tuning, step, octave)
  if step >= tuning.octaveStep then octave = octave + 1 end
  return tuning.stepNames[step] .. octaveLabel(octave)
end

return M
