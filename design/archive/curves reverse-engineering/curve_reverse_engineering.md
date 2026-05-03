# Reverse-engineering REAPER CC interpolation curves

Instructions to future-Claude, for when the user returns with sampled CSVs.

## Background

REAPER's `MIDI_SetCCShape` accepts shape codes 0..5: step, linear, slow, fast-start, fast-end, bezier (with `beztension` ∈ ~[-1, 1]). The exact curve formulas are not in the ReaScript docs and have not been publicly reverse-engineered. We're recovering them empirically so the view layer can visualise them.

## How the data is captured

REAPER bakes shaped CC interpolation into discrete MIDI events when a track plays through a MIDI send. So the workflow is: play a "source" take with shaped CC points into a record-armed "destination" track, and the recorded take captures the baked stream.

The probe script `design/curve_probe.lua` handles seeding and dumping; the user handles routing and recording in REAPER.

### User workflow

1. **Seed** — select an empty MIDI item, run the script. It clears the item and inserts one CC pair (start val=0 with the shape, end val=127 with step) per (shape, tension) config, each on its own CC number 0..13, separated by `SEGMENT_PPQ` ticks.
2. **Record** — set up a second track with MIDI input routed from the source track, record-arm it, play through the seeded segment, stop.
3. **Dump** — select the recorded take, re-run the script. It writes one CSV per config to `design/curve_samples/<name>.csv` plus `manifest.csv`.

The script auto-detects mode from CC count: a freshly seeded take has exactly `2 * #CONFIGS` events; the recorded take will have many more.

## Reading the data

Each CSV: `ppq,val`. To normalise:

- `t = ppq / SEGMENT_PPQ` (from `manifest.csv`, currently 3840) → `t ∈ [0, 1]`
- `y = val / 127` → `y ∈ [0, 1]`

Endpoints should be (0, 0) and (1, 1). REAPER quantises to integer 0..127, so expect a visible staircase — fit through the centroids of each plateau rather than every raw sample, otherwise the staircase biases the residual.

The recorded ppq positions probably won't be tick-uniform — REAPER outputs events at audio-buffer boundaries during playback. That's fine; the (ppq, val) pairs still sample the curve correctly, just non-uniformly.

## What to fit

| shape | candidates to try |
| --- | --- |
| `step` | sanity: should jump 0→127 once; intermediate samples likely all 0 (or all 127 after the jump). |
| `linear` | sanity: `y = t`, near-zero residual. If not, something's wrong with the recording — stop and check with the user. |
| `slow` | smoothstep `3t² − 2t³`; smootherstep `6t⁵ − 15t⁴ + 10t³`; sine `0.5 − 0.5·cos(πt)` |
| `fast-start` | `1 − (1−t)ᵏ` for k=2, 3; `√t`; `sin(πt/2)` |
| `fast-end` | `tᵏ` for k=2, 3; `1 − cos(πt/2)` |
| `bezier` | cubic Bézier with handles at `(h, 0)` and `(1−h, 1)`; fit `h` per tension, then fit `tension → h` across the 9 samples (try linear first, then `h = 0.5 + 0.5·tanh(k·τ)`) |

Selection criterion: lowest mean-squared residual on normalised samples. Report the winner per shape. If two candidates are within ~10% of each other, report both — the user may have a preference based on what looks right next to REAPER's display.

## Tools

- **Simple closed-form fits**: do it in Lua with a coarse grid scan over the candidate's free parameter. No deps.
- **Bézier**: there's no closed form for `t` given `x` on a cubic Bézier. Either:
  - Sample the Bézier parameter densely (e.g. 1000 values of `s ∈ [0, 1]`), get `(x(s), y(s))` per `s`, and snap each data row to its nearest-`x` sample.
  - Or ask the user to run a small Python+scipy.optimize script — only if the Lua approach gives noisy residuals.

## Sanity checks before reporting

- `linear` residual ≈ 0. Otherwise abort.
- `bezier_0.00` — is it identical to linear, or already curved? Tells you whether `tension = 0` is the bezier neutral or just one point on the family. Worth calling out in the report.
- Long flat plateaus inside a "smooth" curve mean the recording was too sparse — ask the user to record at a higher sample rate or longer segment.

## What to produce

When the fit is done:

1. Write recovered formulas to `design/curves.md` as a short reference (one line per shape).
2. If the user wants visualisation wired in, add a `curveSample(shape, tension, t) → y` helper. Placement: probably `util.lua`, but check first — they may want it nearer the view layer.
3. If anything contradicts existing invariants (especially the detune/pb orthogonality memory), flag before writing code.
