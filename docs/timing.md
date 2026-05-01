# timing

Cross-cutting reference for time in Readium: the three frames, who owns
them, and the transforms between them. Also the API reference for
`timing.lua`, the pure module that implements those transforms.

## The three frames

Time in Readium lives in three frames, stacked from authoring down to
storage:

- **logical** (`ppqL`) — the authoring grid. Row `r` sits at
  `r · logPerRow(rpb, denom, res)`. This is what the musician sees and
  edits.
- **intent** (`ppqI`) — the nominal placement after swing has been
  applied. Under identity swing, `ppqI = ppqL`. Otherwise swing
  reshapes how the grid lands in time.
- **realisation** (`ppqR`) — what REAPER stores: intent plus the
  per-note delay nudge. Only the note-*on* carries the offset; the
  note-*off* is intent in storage too.

The frames stack:

```
ppqL  --[ swing.fromLogical ]-->  ppqI  --[ + delayToPPQ(delay) ]-->  ppqR
ppqL  <--[ swing.toLogical  ]---  ppqI  <--[ - delayToPPQ(delay) ]---  ppqR
```

Each conversion is a separate concern: swing is global+per-column
state held in `cm`; delay is per-note metadata. The two compose, but
neither contaminates the other.

## Frame ownership

Each manager holds one or two frames natively and converts at its
boundary with neighbours.

| layer            | native frame                  | conversion duty                                                                                |
|------------------|-------------------------------|------------------------------------------------------------------------------------------------|
| `midiManager`    | realisation                   | none — REAPER's storage frame                                                                  |
| `trackerManager` | intent (public surface), realisation (`um` and rebuild) | `tidyCol` strips delay on read; `um:add/assignEvent` restores it on write to mm |
| `viewManager`    | intent (timing math), logical (authoring stamps) | `ctx:ppqToRow` / `ctx:rowToPPQ` run swing; `stamping` records `ppqL` on authored events     |
| `editCursor`     | logical (rows)                | none — talks to vm in row units                                                                |

The two conversion boundaries:

- **Delay boundary** lives inside tm. `tm:rebuild`'s `tidyCol` is the
  *sole* place that subtracts delay from `evt.ppq` to enter intent
  frame; `um:assignEvent` / `um:addEvent` add it back when writing to
  mm. Inside `tm:rebuild`, ppq comparisons run in realisation frame
  until `tidyCol`; from rebuild's exit onward everything tm exposes is
  intent.
- **Swing boundary** lives inside vm. `ctx:ppqToRow` runs
  `swing.toLogical` on its input; `ctx:rowToPPQ` runs
  `swing.fromLogical` on its output. Authored events are stamped with
  `ppqL` (and `endppqL` for notes) at write time so reswing can
  re-derive intent under a new swing without losing the
  authoring-frame coordinate.

`tm` itself never inspects `ppqL` — those fields ride through as
sidecar metadata. Their semantics are entirely vm's.

## Swing: logical ↔ intent

A *swing* is a piecewise-linear orientation-preserving homeomorphism
of `[0,1]` fixing the endpoints, tiled periodically along a QN axis.
Identity swing means logical equals intent.

```
ppqI = timing.applyFactors(factors, ppqL)
ppqL = timing.unapplyFactors(factors, ppqI)
```

`factors` is the resolved form of a composite (an array of `{S, T}`
with `T` in PPQ). Two layers of swing compose per channel — a
take-wide *global* and an optional *per-column* layer — with column
inside global:

```
E_c = global ∘ column
```

Both layers always apply when present; the per-column layer doesn't
replace global, it acts first and global acts on its output. Identity
in either slot is a no-op, so a channel with no per-column swing
sees only `global`, and a take with only per-column swing on some
channels sees those channels swung and the rest straight.

The helper is `tm:swingSnapshot()`, which freezes both layers against
the current cm config and returns ready-to-use `fromLogical` /
`toLogical` closures keyed by channel. vm captures one snapshot per
rebuild and routes all row math through it.

### Shape representation

A swing shape is a sorted array of control points starting at `{0,0}`
and ending at `{1,1}`, with strictly increasing x and y:

```
S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
```

Evaluation `S(x)` and inversion `S⁻¹(y)` are O(log n) via binary
search. Shapes form a group under composition; the identity is
`{ {0,0}, {1,1} }`. Strict monotonicity is the invariant that makes
inversion well-defined — atoms document their `|a|` bound explicitly,
and pushing past it collapses a segment.

**Smooth atoms are sampled.** `classic`, `pocket`, `lilt`, `shuffle`,
`tilt` are continuous parametric curves that emit dense PWL
approximations (240 segments per unit square). The runtime treats
them identically to hand-built PWL — eval/invert/tile/compose all
consume the canonical control-point form. Smoothness is a property of
how the shape is generated, not of the runtime. The sample count is a
multiple of 12 so principal-pulse breakpoints (x = 1/4, 1/3, 1/2,
2/3, 3/4) all land on exact sample points — the cross-atom drop-in
invariant stays algebraic. `id` is the only atom that returns a
sparse 2-point shape.

### Tiled extension

To act on a time axis, attach a period `T`:

```
tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
```

Every multiple of `T` is a fixed point. `T <= 0` degrades to identity
so callers can drive the transform from a possibly-empty composite
without special cases.

**Period unit is quarter notes**, scalar or `{num, den}`. QN is
preferred over "beat" because a beat is denominator-dependent (6/8 vs
4/4), whereas one quarter note is always one quarter note.
`periodQN` normalises both shapes; other inputs are a caller bug and
raise.

### Composite model

A user-facing swing is an ordered array of factors:

```
composite = { {atom = 'classic', shift = 0.12, period = 1}, ... }
```

`atom` names an entry in `timing.atoms`, `period` is the *user pulse*
in QN, and `shift` is the QN-displacement of the atom's principal —
the principal lands at `principal_qn + shift` after the factor
applies, regardless of atom or period. The realised view transform is
the composition of the factors' tiled extensions — earlier factors
are inner, later are outer (`applyFactors`). An empty array is
identity.

`shift` is **atom-independent in QN**: switching `atom` preserves the
QN-amount of `shift`. The principal it shifts is atom-specific — its
unit-x location is in the atom table (API reference), and its
qn-position is `T_tile · x_principal`. Atoms with the same
`x_principal` *and* the same `pulsesPerCycle` are drop-in
replacements at fixed `period`.

#### Tile period vs user period

```
T_tile(factor) = periodQN(factor.period) × atomMeta[atom].pulsesPerCycle
```

`lilt` and `pocket` have `pulsesPerCycle = 2` — one atom cycle spans
two user-pulses, so the actual repeat period is double what the user
picks. The unit-square parameter consumed by the atom shape is
`a = shift / T_tile`. `compositePeriodQN` and the editor's
per-factor preview both use `atomTilePeriod` so the displayed repeat
matches the realised one.

The runtime library lives in `cfg.swings` at project scope; slots in
`cfg` reference composites **by name only**. Name lookup goes through
`findShape(name, userLib)`; a missing name or missing library returns
nil, and callers treat nil as identity.

`timing.presets` is **seed data only** — never consulted at
slot-resolution time. Its role is to populate the UI's "copy into
library" menu.

## Delay: intent ↔ realisation

`delay` is a per-note metadata field (signed milli-QN, defaulted to
0). It nudges only the note-on:

```
realised.ppq    = intent.ppq + delayToPPQ(delay)
realised.endppq = intent.endppq                  -- delay never shifts the end
```

A positive delay shrinks realised duration by exactly
`delayToPPQ(delay)`; a negative delay extends it. Classical tracker
sub-row note-on nudge.

`delayToPPQ` rounds at source, making the map an **integer bijection
on ℤ**: every arithmetic use (`intent ± delayToPPQ(d)`) stays in ℤ,
so realise/strip round-trips are algebraic rather than approximate.

## Cross-frame invariants

- **Delay does not affect column allocation.** `noteColumnAccepts`
  judges overlap in intent, so changing a note's delay can never push
  it into a different column or spring a new one.
- **Fake pbs inherit their host note's delay** at rebuild time so
  `tidyCol` shifts host and absorber into intent together. Without
  this, a delayed note and its absorber would desynchronise at the vm
  boundary. (Absorbers are the detune-realisation mechanism — see
  `docs/tuning.md`.)
- **`ppqL` is delay-independent.** Authored events stamp `ppqL` from
  row arithmetic; delay nudges shift `ppq` / `endppq` but never
  `ppqL`. This is what lets reswing reseat events without losing the
  user's authoring intent.
- **`endppq` is intent in storage** at every layer — mm, tm, vm. Only
  `ppq` has a realisation/intent distinction.
- **Float `rowPPQs`.** vm stores `rowPPQs[r] = r · logPerRow` without
  pre-rounding. Under non-divisor `rpb` (e.g. 7) the rounded form
  would seed ε that compounds through swing inversion; with floats,
  `rowToPPQ` / `ppqToRow` are mutually exact (single round only at
  realisation) and on-grid tests collapse to a clean integer compare
  against `evt.ppq`.

## Conventions for `timing.lua`

- **Endpoints are pinned.** `compose` re-writes the first and last
  control points to exactly `{0,0}` / `{1,1}` after computation to
  absorb floating-point drift — downstream binary search depends on
  this.
- **Composite names resolve within the project library.** tm/vm never
  look into `presets`; resolution goes through `findShape`, nil is
  identity.
- **Factor order is inner-to-outer.** `applyFactors` walks forward,
  `unapplyFactors` walks backward — preserve the order when editing a
  composite.
- **Atoms do not clamp.** Callers read `timing.atomMeta[name].range`
  and clamp there.

---

## API reference

`timing.lua` is a pure module: no module-level state; every function
takes its operands explicitly.

### Atoms

```
timing.atoms[name](a)            -> shape S    (a is unit-square; = shift/T_tile)
  PWL:    id
  smooth: classic, pocket, lilt, shuffle, tilt
timing.atomMeta[name]            -- { range = max |a|, pulsesPerCycle = N }
timing.atomTilePeriod(factor)    -- periodQN(factor.period) × pulsesPerCycle
```

| atom | shape | principal (unit-x) | range (max \|a\|) | pulsesPerCycle |
|---|---|---|---|---|
| `classic` | y = x + a·sin(πx) — single sin bump                                                                | x = 0.5                        | `1/π ≈ 0.318`     | 1 |
| `pocket`  | y = x + a·(1 − (2x−1)⁶) — flat-topped bump                                                          | x = 0.5                        | `1/12 ≈ 0.083`    | 2 |
| `lilt`    | y = x + a·sin(2πx) — alternating push/pull                                                          | x = 0.25 (peak), 0.75 (trough) | `1/(2π) ≈ 0.159`  | 2 |
| `shuffle` | y = x + a·k·(−2sin(2πx)+sin(4πx)), k = 2/(3√3) — anti-symmetric, extrema on the triplet positions   | x = 1/3 (trough), 2/3 (peak)   | `9/(16π√3) ≈ 0.103` | 1 |
| `tilt`    | y = x + a·(27/4)·x·(1−x)² — asymmetric forward bump                                                 | x = 1/3                        | `4/27 ≈ 0.148`    | 1 |

The shift convention pins each atom's principal at exactly
`(x_principal · T_tile) + shift` in QN — the displacement of the
principal is faithfully `shift` regardless of atom or period.

### Composite registry

```
timing.presets                   -- seed-only {name = composite}
timing.findShape(name, userLib)  -> composite or nil
timing.isIdentity(composite)     -- nil or empty
```

### Shape operations

```
timing.eval(S, x)                -- S(x)
timing.invert(S, y)              -- S⁻¹(y)
timing.inverse(S)                -> new shape
timing.compose(S, T)             -> S ∘ T
```

### Tiled extension

```
timing.periodQN(period)          -- number or {num,den} → scalar QN
timing.compositePeriodQN(comp)   -- smallest T at which all factors complete
                                 --   uses tile periods (pulsesPerCycle ×);
                                 --   empty ⇒ 1 qn
timing.tile(S, T, p)             -- forward at period T (in PPQ)
timing.tileInverse(S, T, p)      -- inverse
timing.applyFactors(factors, ppq)
timing.unapplyFactors(factors, ppq)
```

`factors` is the resolved form of a composite: an array of `{S, T}`
with `T` in PPQ.

### Delay conversion

```
timing.delayToPPQ(d, res)        -- signed milli-QN → PPQ, rounds at source
timing.ppqToDelay(p, res)        -- inverse (float)
```

`res` is PPQ per quarter note (typically from `mm:resolution()`).

### Logical grid

```
timing.logPerRow(rpb, denom, resolution)   -- ppq width of one logical row
```

Pure: `resolution * 4 / (denom * rpb)`. May be fractional under odd
`(rpb, denom)` combinations; callers store the result as a float and
compare with a small ε when checking row alignment.
