# microtuning

Pure module: tuning library plus conversions between MIDI coordinates
`(pitch, detune)` and scale coordinates `(step, octave)` under a given
tuning. All functions take an explicit tuning argument; no module-level
state.

## Coordinate systems

Two views on the same cents line:

- **MIDI**: `(pitch, detune)` — pitch in 0..127, detune in cents.
- **Scale**: `(step, octave)` — step is 1-indexed into `tuning.cents`.

Cents 0 corresponds to `C-1` (MIDI 0). The first step of every tuning
is `C`. Octave labels follow the ASCII-MIDI convention (C4 = MIDI 60).

## Tuning shape

```
tuning = {
  name       = '31EDO',
  period     = 1200,          -- cents per octave (always 1200 for EDO)
  cents      = { 0, 39, 77, ... },  -- ascending, length = step count
  stepNames  = { 'C-', 'C↑', ... }, -- one per step
  octaveStep = <index>,       -- derived; see below
}
```

`edo(n, names)` builds an equal-division-of-octave tuning by rounding
`i * 1200 / n` at each step.

## The `octaveStep` derivation

Some tunings have steps near the end of the period whose note name is
enharmonically the *next* C (e.g. `C↓` in 31EDO, `C↓` in 53EDO). Those
steps belong to the octave above by label convention.

`octaveStep` is the first step index from which this octave bump
applies. It is auto-derived by scanning `stepNames` from the end and
finding the last non-C name — every step past it is a C-variant that
reads as the next octave. Derivation lives next to the tuning table so
the two stay in sync.

`stepToText` adds 1 to the displayed octave when `step >= octaveStep`.

## Snapping and clamping

- `midiToStep` snaps to the nearest scale point **including the period
  boundary**: step 1 of the next period sits at `cents = period`, so a
  near-boundary input rounds to step 1 of `octave+1` rather than the
  last step of the current octave.
- `stepToMidi` wraps out-of-range step indices by adjusting octave,
  then **clamps the resulting MIDI note to 0..127** by folding the
  overflow into detune. A very-low step does not silently disappear; it
  returns `(0, <large negative detune>)`.

## Display

```
M / 0 / 1 / 2 ...                -- octave labels
```

Octave -1 renders as `"M"` so the cell width stays fixed at 3 chars
(e.g. `C-M` for MIDI 0 vs `C-4` for MIDI 60).

## Conventions

- **Octave param is MIDI-relative** (C4 → 4, C-1 → -1), not
  period-index. Conversions between the two live inside this module;
  callers see MIDI octaves.
- **All functions are pure.** Pass the tuning; no module-level current
  tuning. vm/tm read `cm:get('tuning')` and forward it.
- **First step is always C.** Tuning construction assumes this when
  deriving `octaveStep`.

---

## API reference

### Library

```
microtuning.tunings              -- { name = tuning }; built-in: 12/19/31/53 EDO
microtuning.findTuning(name)     -> tuning or nil
```

### Coordinate conversion

```
microtuning.midiToStep(tuning, midi, detune)   -> step, octave
microtuning.stepToMidi(tuning, step, octave)   -> midi, detune
microtuning.snap(tuning, midi, detune)         -> midi, detune
microtuning.transposeStep(tuning, midi, detune, n) -> midi, detune
```

`detune` is optional on `midiToStep` (defaults to 0).
`transposeStep` moves by `n` scale steps, carrying the octave.

### Display

```
microtuning.stepToText(tuning, step, octave)   -> string
```
