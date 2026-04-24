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
The atoms document their `|amount|` bound explicitly; pushing past it
collapses a segment. Atoms do **not** clamp — callers (UI widgets,
config loaders) read `timing.atomRange` and clamp there.

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
composite = { {atom = 'classic', amount = 0.12, period = 1}, ... }
```

`atom` names an entry in `timing.atoms`, `amount` is that atom's shape
parameter, `period` is in QN. The realised view transform is the
composition of the factors' tiled extensions — earlier factors are
inner, later are outer (`applyFactors`). An empty array is identity.

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
timing.atoms[name](amount)       -> shape S
  names: id, classic, pocket, shuffle, drag, lilt
timing.atomRange[name]           -- max |amount| keeping S monotonic
```

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
