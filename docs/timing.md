# timing

Pure module: swings as piecewise-linear orientation-preserving
homeomorphisms of `[0,1]` fixing the endpoints, with composition,
inversion, and tiled extension along a periodic PPQ axis. No
module-level state; every function takes its operands explicitly.

## Shape representation

A swing shape is a sorted array of control points, starting at `{0,0}`
and ending at `{1,1}`, with strictly increasing x and y:

```
S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
```

Evaluation `S(x)` and inversion `S⁻¹(y)` are O(log n) via binary search.
Shapes form a group under composition; the identity is `{ {0,0}, {1,1} }`.

Strict monotonicity is the invariant that makes inversion well-defined.
The atoms document their `|a|` bound explicitly; pushing past it
collapses a segment. Atoms do **not** clamp — callers read
`timing.atomMeta[name].range` and clamp there.

**Smooth atoms are sampled.** `arc`, `pocket`, `lilt`, `shuffle`, `tilt`
are continuous parametric curves that emit dense PWL approximations
(240 segments per unit square). The runtime treats them identically to
hand-built PWL — eval/invert/tile/compose all consume the canonical
control-point form. Smoothness is a property of how the shape is
generated, not of the runtime. The sample count is a multiple of 12 so
the principal-pulse breakpoints (x = 1/4, 1/3, 1/2, 2/3, 3/4) all land
on exact sample points — the cross-atom drop-in invariant stays
algebraic.

## Tiled extension

To act on a time axis, attach a period T:

```
tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
```

Every multiple of T is a fixed point. `T <= 0` degrades to identity so
callers can drive the transform from a possibly-empty composite without
special cases.

**Period unit is quarter notes**, scalar or `{num, den}`. QN is
preferred over "beat" because a beat is denominator-dependent (6/8 vs
4/4), whereas one quarter note is always one quarter note. `periodQN`
normalises both shapes; other inputs are a caller bug and raise.

## Composite model

A user-facing swing is an ordered array of factors:

```
composite = { {atom = 'classic', shift = 0.12, period = 1}, ... }
```

`atom` names an entry in `timing.atoms`, `period` is the *user pulse*
in QN, and `shift` is the principal pulse-1 breakpoint's displacement,
**also in QN**. The realised view transform is the composition of the
factors' tiled extensions — earlier factors are inner, later are outer
(`applyFactors`). An empty array is identity.

`shift` is **atom-independent**: at fixed `period`, the same numeric
`shift` lands the principal pulse-1 breakpoint at the same absolute
time across {classic, arc, pocket, lilt, shuffle, tilt}. Atoms become
drop-in replacements; switching `atom` preserves `shift` and only the
interior shape of the period changes. (`drag` is the documented
exception: same sign convention, but its non-linear x-shift means the
magnitude only agrees in the small-`shift` limit.)

### Tile period vs user period

```
T_tile(factor) = periodQN(factor.period) × atomMeta[atom].pulsesPerCycle
```

Only `lilt` has `pulsesPerCycle = 2` — its alternating push/pull
covers two user-pulses per atom cycle, so its actual repeat period is
double what the user picks. The unit-square parameter consumed by the
atom shape is `a = shift / T_tile`. `compositePeriodQN` and the
editor's per-factor preview both use `atomTilePeriod` so the displayed
repeat matches the realised one.

The runtime library lives in `cfg.swings` at project scope; slots in
`cfg` reference composites **by name only**. Name lookup is done via
`findShape(name, userLib)`; a missing name or missing library returns
nil, and callers treat nil as identity.

`timing.presets` is **seed data only** — it is never consulted at
slot-resolution time. Its role is to populate the UI's "copy into
library" menu.

## Delay ↔ PPQ

`delayToPPQ` / `ppqToDelay` convert between signed milli-QN delay
values and PPQ offsets. The forward direction rounds at source, making
the map an **integer bijection on ℤ**: every arithmetic use
(`intent ± delayToPPQ(d)`) stays in ℤ, so realise/strip round-trips
are algebraic rather than approximate.

## Conventions

- **Endpoints are pinned.** `compose` re-writes the first and last
  control points to exactly `{0,0}` / `{1,1}` after computation to
  absorb floating-point drift — downstream binary search depends on this.
- **Composite names resolve within the project library.** tm/vm never
  look into `presets`; resolution goes through `findShape`, nil is
  identity.
- **Factor order is inner-to-outer.** `applyFactors` walks forward,
  `unapplyFactors` walks backward — preserve the order when editing a
  composite.

---

## API reference

### Atoms

```
timing.atoms[name](a)            -> shape S    (a is unit-square; = shift/T_tile)
  PWL:    id, classic, drag
  smooth: arc, pocket, lilt, shuffle, tilt
timing.atomMeta[name]            -- { range = max |a|, pulsesPerCycle = N }
timing.atomTilePeriod(factor)    -- periodQN(factor.period) × pulsesPerCycle
```

| atom | shape | principal | range (max \|a\|) | pulsesPerCycle |
|---|---|---|---|---|
| `classic` | PWL tent: kink at x=0.5, height +a            | x = 0.5      | `0.5`           | 1 |
| `drag`    | PWL: kink slides along y=0.5 to x=0.5+a       | x ≈ 0.5      | `0.5` (loose)   | 1 |
| `arc`     | y = x + a·sin(πx)                             | x = 0.5      | `1/π ≈ 0.318`   | 1 |
| `pocket`  | y = x + a·(1 − (2x−1)⁶) — flat-topped bump    | x = 0.5      | `1/12 ≈ 0.083`  | 1 |
| `lilt`    | y = x + a·sin(2πx) — alternating push/pull    | x = 0.25 (peak), 0.75 (trough) | `1/(2π) ≈ 0.159` | 2 |
| `shuffle` | y = x + a·k·(−2sin(2πx)+sin(4πx)), k = 2/(3√3) — anti-symmetric, extrema on the triplet positions | x = 1/3 (trough), 2/3 (peak) | `9/(16π√3) ≈ 0.103` | 1 |
| `tilt`    | y = x + a·(27/4)·x·(1−x)² — asymmetric forward bump | x = 1/3 | `4/27 ≈ 0.148` | 1 |

The shift convention pins each atom's principal at exactly `x_principal + shift`
in tile units, so atoms drop in for one another at fixed `period` (the
interior of each pulse changes, not the principal's location).

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
with T in PPQ.

### Delay conversion

```
timing.delayToPPQ(d, res)        -- signed milli-QN → PPQ, rounds at source
timing.ppqToDelay(p, res)        -- inverse (float)
```

`res` is PPQ per quarter note (typically from `mm:resolution()`).

### Straight grid

```
timing.straightPPQPerRow(rpb, denom, resolution)   -- ppq width of one straight-grid row
```

Pure: `resolution * 4 / (denom * rpb)`. May be fractional under odd
`(rpb, denom)` combinations; callers store the result as a float and
compare with a small ε when checking row alignment.

The straight grid is the canonical authoring frame: a row at index `r`
sits at `r · straightPPQPerRow(rpb, denom, res)` PPQ. Swing realisation
applies on top — `apply(swing, straight)` produces the realised intent
ppq, and `delayToPPQ(delay)` shifts further into the realised+delay
frame stored by REAPER.
