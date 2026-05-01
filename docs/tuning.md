# tuning

Cross-cutting reference for pitch in Readium: how a note's tuning is
*authored* (the coordinate system) and how it is *realised* (the
intent / realisation split). Also the API reference for `tuning.lua`,
the pure module that owns the coordinate-system layer.

The module is named `tuning` (matching the user-facing word). The
entity it operates on is called a **temper** in code (short for
*temperament*) — a tuning system such as 12-EDO, 31-EDO, or a future
Just-Intonation lattice. The shorter form avoids prolixity at call
sites without losing precision in headings and comments.

## The pitch model

Pitch in Readium splits into two concerns that don't contaminate each
other:

- **Coordinate system** — how a note's pitch is *named*. The MIDI
  view is `(pitch, detune-in-cents)`; the scale view is
  `(step, octave)` under a temperament. `tuning.lua` converts
  between them; this is a pure layer with no take state.
- **Intent vs realisation** — how a note's tuning is *delivered*.
  Detune is the musician's intent (per-note metadata); the
  channel-wide pitchbend stream is the realisation (what REAPER
  stores and plays). tm reconciles the two.

These layers are orthogonal. The temperament chosen for display does
not change what's stored on the wire, and a pb edit does not retro-
mutate a note's authored detune.

## Intent vs realisation

Three views of the same channel-wide cents line coexist:

- **Raw pb** — what REAPER stores on the wire: signed `-8192..8191`,
  centred on 0, channel-wide.
- **Logical pb** — what the musician authored: cents relative to
  prevailing detune. The smooth stream the user "drew."
- **Detune** — per-note metadata (signed cents). Every note carries
  a `detune` field, but pb is channel-wide so only *one* note column
  per channel can drive tuning realisation; by convention that is
  **lane 1** (the first note column of the channel). Higher lanes'
  detune values are still stored — and consulted by display layers
  like the temperament lens — but they don't contribute to the pb
  stream. Higher lanes simply inherit whatever pb is in force.

The relationship between the two pb views is

```
logical(chan, ppq) = raw(chan, ppq) − detune(chan, ppq)
```

where `detune(chan, ppq)` is the detune of the latest lane-1 note
starting at or before `ppq` (0 if none).

### The fake-pb absorber

When a lane-1 note's detune differs from the prevailing detune just
before it, a pb must seat at the note boundary to absorb the raw
step while keeping the logical stream unchanged. That pb is tagged
`fake=true` (persisted as cc metadata) and is hidden from the pb
column unless an interp shape pulls it into view.

The absorber invariant — **both directions**:

- **Detune jump at a note seat ⇒ a fake pb seats at that seat.**
  Without it, a step in the raw stream would surface as a step in
  the logical stream too. The whole point of the absorber is to
  keep logical smooth across detune changes.
- **No detune jump at a seat ⇒ no fake pb at that seat.** Stale
  absorbers are noise; they survive only as long as they are
  needed.

Mutations reconcile both ends bidirectionally — "drop redundant" and
"seat missing" both run after every detune mutation that crosses the
seat. The implementation lives in tm's `reconcileBoundary`; see
`docs/trackerManager.md` for the call sites.

### Orthogonality

The view layer above the realisation line never touches pb directly.
Detune drives pb seating; pb does not drive detune. Editing a lane-1
note's detune seats / removes / shifts absorbers (tm handles this);
editing a pb event does not retro-mutate detune.

This keeps detune as the durable intent: re-temper, re-render, or
re-export from intent and realisation falls out cleanly. It also
keeps the *realisation mechanism itself* swappable. pb is the
current implementation; another mechanism — MTS (MIDI Tuning
Standard) is the obvious candidate — could substitute beneath the
intent line without disturbing anything above it. Each mechanism
brings its own limitations:

- **pb** is channel-wide and single-voice, so only lane 1
  contributes to realisation. A lane-2 note with `detune ≠ 0`
  displays as its microtone via the temperament lens but sounds at
  ambient pb.
- **MTS** retunes the 128-pitch grid rather than extending it: each
  scale step has to be assigned to a MIDI pitch, so a cluster of
  microtones near the same pitch forces an artificial allocation
  across neighbouring MIDI numbers — and those neighbours then can't
  be played at their nominal tuning simultaneously.

The point of the orthogonality is that those limits live entirely
below the intent line.

Concretely:

- vm authoring sets `(pitch, detune)` on a note; pb realisation is
  tm's job.
- Inside tm's `um`, `pb.val` is **always cents**; conversion to raw
  happens only at load (`rawToCents`) and at flush (`centsToRaw`).
  The cents window is `cm:get('pbRange') * 100` per side.
- mm holds raw pb only — it has no notion of detune. The raw/cents
  conversion is tm's boundary, parallel to tm's role on the timing
  side (see `docs/timing.md`).

### Invariants

The realisation layer's contract with everything above it. These
hold for every channel `c` and every ppq `P`, after every mutation:

- **I1 — Identity.** `logical(c, P) = raw(c, P) − detune(c, P)`,
  where `detune(c, P)` is the detune of the latest **lane-1** note
  onset at-or-before P.
- **I2 — Absorber, both directions.** At every lane-1 note seat S:
  - `detune(c, S) ≠ detuneBefore(c, S)` ⇒ ∃ pb at S (real or fake).
  - `detune(c, S) = detuneBefore(c, S)` ⇒ no **fake** pb at S.
    Real pbs are user-authored and never deleted by reconciliation.
- **I3 — Lane-1 monopoly.** Adding, editing, or deleting a
  lane-≥2 note never seats, removes, or moves any pb. Higher-lane
  detune is dead data for realisation; it persists as metadata so
  display layers and future lane-promotion paths can read it back.
- **I4 — Orthogonality.** Editing a pb never mutates any note's
  detune; editing a note's detune never demotes a real pb to fake
  nor seats a real pb. Detune drives pb seating; pb does not drive
  detune.
- **I5 — Cleanliness.** No two pbs share `(chan, ppq)`. Fake pbs
  exist only at lane-1 seats that have a detune jump.

I1-I5 are mechanism-independent: any future realisation layer (MTS
in place of pb, etc.) inherits the same contract. Tests pin them by
number in `tests/specs/tm_tuning_spec.lua`. tm-specific contracts
that fulfil these — frame, delay, persistence — live in
`docs/trackerManager.md`.

## Coordinate systems

Two views on the same cents line:

- **MIDI**: `(pitch, detune)` — pitch in 0..127, detune in cents.
- **Scale**: `(step, octave)` — step is 1-indexed into `temper.cents`.

Cents 0 corresponds to `C-1` (MIDI 0). The first step of every
temperament is `C`. Octave labels follow the ASCII-MIDI convention
(C4 = MIDI 60).

## Temper shape

```
temper = {
  name       = '31EDO',
  period     = 1200,                -- cents per octave (always 1200 for EDO)
  cents      = { 0, 39, 77, ... },  -- ascending, length = step count
  stepNames  = { 'C-', 'C↑', ... }, -- one per step
  octaveStep = <index>,             -- derived; see below
}
```

`edo(n, names)` builds an equal-division-of-octave temperament by
rounding `i * 1200 / n` at each step.

### The `octaveStep` derivation

Some temperaments have steps near the end of the period whose note
name is enharmonically the *next* C (e.g. `C↓` in 31EDO, `C↓` in
53EDO). Those steps belong to the octave above by label convention.

`octaveStep` is the first step index from which this octave bump
applies. It is auto-derived by scanning `stepNames` from the end and
finding the last non-C name — every step past it is a C-variant that
reads as the next octave. Derivation lives next to the temperament
table so the two stay in sync.

`stepToText` adds 1 to the displayed octave when `step >= octaveStep`.

### Snapping and clamping

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

## Slot registry

Mirrors the swing model in `docs/timing.md`:

- `tuning.presets` is **seed-only** — never consulted at slot
  resolution time. Its role is to populate the UI's "copy into
  library" menu.
- The runtime library lives in `cfg.tempers` at project scope; slots
  in `cfg.temper` reference temperaments **by name only**.
- `findTemper(name, userLib)` resolves only within the userLib. A
  missing name or missing lib returns nil; callers treat nil as
  "no temperament".

## Conventions

- **Octave param is MIDI-relative** (C4 → 4, C-1 → -1), not
  period-index. Conversions between the two live inside this module;
  callers see MIDI octaves.
- **All `tuning.lua` functions are pure.** Pass the temper; no
  module-level current temper. vm/tm read `cm:get('temper')` and
  forward it.
- **First step is always C.** Temper construction assumes this when
  deriving `octaveStep`.
- **Detune is cents** throughout (never raw 14-bit). Conversion to
  raw pb happens only inside tm's flush boundary.

---

## API reference

### Library

```
tuning.presets                   -- { name = temper }; built-in: 12/19/31/53 EDO
tuning.findTemper(name, userLib) -> temper or nil
```

### Coordinate conversion

```
tuning.midiToStep(temper, midi, detune)   -> step, octave
tuning.stepToMidi(temper, step, octave)   -> midi, detune
tuning.snap(temper, midi, detune)         -> midi, detune
tuning.transposeStep(temper, midi, detune, n) -> midi, detune
```

`detune` is optional on `midiToStep` (defaults to 0).
`transposeStep` moves by `n` scale steps, carrying the octave.

### Display

```
tuning.stepToText(temper, step, octave)   -> string
```
