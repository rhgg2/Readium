# Microtuning

## Conceptual model

Two coordinate systems on the cents line:

- **MIDI:** `(pitch, detune)` — what's stored on the note. `detune` is the
  *intended* cents offset from the semitone, **tuning-independent**.
- **Scale:** `(step, octave)` — what's shown to the user under a tuning.

A tuning is a discrete subset of the cents line: a `period` (typically 1200)
and a sorted list `cents` of step offsets in `[0, period)`. The tuning is a
**pure view**, not a stored property of notes. Switching tunings does not
touch data — it just relabels what the user sees and changes how new edits
snap. Notes are points on the cents line; a tuning is a graticule overlaid
on top; labels follow from geometry.

```
MIDI  → cents:    c = 100·pitch + detune
cents → scale:    octave = ⌊c / period⌋ ;  res = c − octave·period
                  step = nearest step (snap, with period-boundary wraparound)
scale → cents:    c = (octave+1) · period + cents[step]
cents → MIDI:     pitch = round(c/100) ;  detune = c − 100·pitch
```

The `+1` in `scale → cents` is the MIDI octave convention: `C-1 = MIDI 0`.

A `step` is **never** stored. It is always derived from `(pitch, detune)`
under the active tuning. There is no scenario where a note "remembers it was
C↑ in 31EDO" — cents are the source of truth, labels follow.

### Two independent discrepancies

The view layer surfaces two genuinely different "off-ness" quantities, and
must not conflate them:

1. **Realisation gap** — `rawPbCents − activeDetune`. *"Is the actual
   sound realising the note's intent?"* This is what the existing pb column
   shows and is **independent of which tuning is active**. trackerManager
   computes it (it's part of pb realisation), and it never depends on the
   scale lens.

2. **Projection gap** — `note.cents − displayedStepCents`, where
   `displayedStepCents` is the absolute cents of the step the projection
   landed on. *"Is the note's intent landing exactly on the displayed
   step?"* This is **tuning-dependent** and lives entirely in the view
   layer (viewManager + renderManager). It is computed per note from the
   note's own `(pitch, detune)` and the active tuning. Zero by construction
   for notes that were entered or snapped under the current tuning.

These quantities can both be non-zero, both zero, or one of each. They mean
different things and are surfaced by different affordances:

- The **pb column** continues to show the realisation gap, exactly as today.
- A new **off-grid bar** above each pitch cell shows the projection gap.

### The off-grid bar

A thin horizontal strip drawn just above the pitch cell, present only when
`projectionGap ≠ 0`. A tick offset from the strip's centerline encodes the
gap: left of center = flat, right of center = sharp. Hidden entirely when
on-grid (the common case, especially after entry).

**Normalization.** Full deflection corresponds to *half the gap to the
nearest neighbouring step in the current tuning*. For 12EDO that's ±50¢; for
19EDO ±31.5¢; for 53EDO ±11.3¢. The meaning is "how close are you to being
snapped to a different step under this tuning". A 20¢ gap reads as "barely
off" in 12EDO but as "definitely wrong note, almost touching the next step"
in 53EDO — and the bar should communicate that, not a fixed cent value.

renderManager already calls `ImGui.DrawList_AddLine` directly for grid
decorations, so this is a new call site, not a new mechanism.

### Detune vs pitchbend (orthogonality)

`note.detune` is *what the note is*. Pitchbend (or, later, MTS) is *how it's
delivered*. They share a wire today, so trackerManager demixes on read and
remixes on write — but conceptually they're independent. The microtuning view
layer must live **above** the realisation line and care only about
`(pitch, detune)`. It must never look at pb events.

## Current state

`microtuning.lua` is rewritten and committed. ~135 lines, pure module, no
state. Public surface:

```
microtuning.tunings       -- table keyed by name: '12EDO', '19EDO', '31EDO', '53EDO'
microtuning.findTuning(name)
microtuning.midiToStep(tuning, midi, detune)        -> step, octave
microtuning.stepToMidi(tuning, step, octave)        -> midi, detune
microtuning.snap(tuning, midi, detune)              -> midi', detune'
microtuning.transposeStep(tuning, midi, detune, n)  -> midi', detune'
microtuning.stepToText(tuning, step, octave)        -> "C#4" / "C↑M" / etc
```

### Key decisions baked into the rewrite

- **C-anchored.** First step of every tuning is C; `cents 0` = MIDI 0 = C-1.
- **1-indexed** step arrays (matches Continuum convention).
- **`octaveStep` auto-derived** from the names: any trailing run of
  C-prefixed steps (e.g. `C↓` in 31EDO/53EDO) gets `octave+1` in display,
  because it's enharmonically the next C.
- **`'M'` octave label** for octave −1 only (so MIDI 0 renders as `C-M`).
- **Period-boundary wraparound** considered in `midiToStep` (a bug in the
  original — for cents in the top of the gap before the period boundary,
  step 1 of the next period is closer than step n of this one).
- **Microsymbols.** 31-EDO uses `↑` `↓`. 53-EDO uses `↑↓`, `⇑⇓`, `⇈⇊` for
  1, 2, 3 commas. All renderable in Source Code Pro.
- **Dropped:** `ccToCents`/`centsToCC` (pb is trackerManager's job),
  serialisation (persistence is just the tuning name string), module-level
  `activeTuning`, custom `setTuningFromData` for unknown tunings.

## What's next

The whole edit/display loop is unbuilt. The microtuning module is
infrastructure waiting to be wired in.

Pure view means **no mutation on tuning change**. Every slice below is
additive — none of them touch existing notes' `(pitch, detune)` except slices
that are explicitly destructive user commands (entry snap, step transpose,
snap-selection). Tuning change itself is a pure relabel.

### Slice 1 — display (projection lens + off-grid bar)

Goal: with a tuning configured, the grid renders pitch cells as step+octave,
and off-grid notes sprout a small bar above the cell showing the projection
gap. No editing changes yet. Should be visible end-to-end before touching
anything else.

1. Add `tuning` as a config key (track-level for now via cm). Default `nil` =
   no lens = current rendering. Hardcoded selection — no UI yet, edit cm by
   hand or via the Lua console.
2. viewManager reads the active tuning via cm and exposes, per pitch cell:
   - the projected step label (`stepToText` output)
   - the projection gap in cents (for the bar)
3. renderManager:
   - pitch cell text: `stepToText` output when tuning is active, else
     current formatting.
   - when `projectionGap ≠ 0`, draw a thin horizontal strip just above the
     cell via `ImGui.DrawList_AddLine` (already used elsewhere in the
     renderer). Tick offset from center encodes sign and magnitude,
     normalized to half the current tuning's nearest-neighbour step gap.
4. Smoke tests:
   - 12EDO: visually identity for on-grid notes; off-grid notes show a bar.
   - 19EDO with clean entry: every note on-grid, no bars.
   - 53EDO with 12EDO-origin notes: almost every note shows a small bar
     (because 12EDO semitones rarely coincide with 53EDO steps).
   - Switching tuning: data unchanged; labels relabel; bars appear/disappear
     according to the new projection. No mm:modify calls fire from the
     tuning change itself.

### Slice 2 — virtual keyboard snap

When the user enters a note via virtual keyboard, the new note enters as
`(pitch, detune=0)`. If a tuning is active, snap before insertion:

```lua
if tuning then
  pitch, detune = microtuning.snap(tuning, pitch, 0)
end
```

This is a one-liner at the insertion site in viewManager. Freshly-entered
notes have `projectionGap = 0` under the active tuning → no bar.

### Slice 3 — step transpose

Up/down arrow currently moves by semitone. Under an active tuning, move by
step instead:

```lua
if tuning then
  pitch, detune = microtuning.transposeStep(tuning, note.pitch, note.detune, delta)
else
  pitch = note.pitch + delta
end
```

No modifier for "raw semitone transpose" — switch to 12EDO if you want that.

### Slice 4 — "snap selection to tuning" (opt-in command)

Explicit command. Iterate selection, apply `microtuning.snap`, write back
inside one `mm:modify`. **Detune only** — does not touch pitchbend.

Under pure view this is no longer how tuning change works; it's a deliberate
user-initiated cleanup. Useful for:

- Importing 12EDO data into a 19EDO project and wanting to "commit" it.
- Re-snapping notes that have drifted off-grid due to manual edits.
- Bulk cleaning a take that's acquired lots of small off-grid bars.

### Slice 5 — "realise detunes as pitchbend" (opt-in command)

The inverse direction to snap: takes the current intent (whatever the notes'
`(pitch, detune)` already are) and writes raw pb events that zero out the
realisation gap. The pb column goes quiet for the realised notes.

Independent of any tuning — this operates on intent vs realisation, which
is tuning-agnostic. Under MTS mode later, this command will emit sysex
instead of pb events, but the interface is the same.

### Later (not in this thread)

- UI for picking a tuning per track / take.
- Project-level tuning library; user-defined tunings.
- `.scl` file import.
- MTS realisation mode (sysex per-note retuning) as an alternative to
  pitchbend mode. Once this exists, `logical = raw` for pb because detune is
  delivered out-of-band.
- Non-octave tunings (Bohlen-Pierce, period ≠ 1200). Module already takes
  `period` from the tuning, so the math is ready; only the labels and any
  "octave"-named UI need to relax.

## Open questions / things to flag

- **Octaves below −1.** `stepToMidi` clamps MIDI to 0..127, so this shouldn't
  happen organically, but if it does, `octaveLabel` falls back to `tostring`
  which gives `-2`, `-3`, … — not "M-prefixed". Fine in practice.
- **Untested.** No test runner in REAPER scripting land. The math is correct
  on paper but should be smoke-tested the moment slice 1 is wired in. Start
  with 12EDO round-trip (should be identity), then 19EDO.
- **What about wraparound in `transposeStep`?** Already handled by
  `stepToMidi`'s `while` loops on step. Step `n+1` becomes step `1` of next
  octave; step `0` becomes step `n` of previous octave.
- **53-EDO has 6 microsymbols + `#`/`b`.** That's 8 distinct alteration
  glyphs per natural. Worth a sanity check that `stepToText` output is
  legible at the grid's actual cell width — may need to think about whether
  the grid lays out 1 char or 2 chars after the letter.
- **Bar visual spec is still rough.** Position above the cell, color,
  thickness, and exact tick/needle shape all need to be decided once it's
  rendered in-situ. Start with a thin line and a single pixel-wide tick, then
  iterate against how it reads on an actual grid.
- **Projection gap computation in viewManager.** viewManager already sees the
  active tuning (for cell labels); computing the projection gap alongside is
  cheap — it's `note.cents − displayedStepCents`, where both quantities fall
  out of the same `midiToStep` / `stepToMidi` round-trip. Worth folding into
  the same call site rather than recomputing.
