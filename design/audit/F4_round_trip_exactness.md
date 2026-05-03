# F4 — Round-trip exactness

> **Resolution (2026-05-01):** the original invariant overclaimed
> "matched rounding on both directions". Restated in
> `swing_delay_invariants.md` as two corners: direction 1 uses the
> recovery operator (`ctx:snapRow ∘ ctx:rowToPPQ = id` on integer rows);
> direction 2 (on-grid `p` → row → `p`) holds exactly. The walk below is
> kept as the historical record of the falsification.

---


**Invariant**: for integer row `r` in `[0, numRows)`,
`ctx:ppqToRow(ctx:rowToPPQ(r, c), c) == r`. For an on-grid intent ppq
`p`, `ctx:rowToPPQ(ctx:ppqToRow(p, c), c) == p`.

**Falsifying test (per the doc)**: under any composite swing (including
odd rpb), iterate r = 0..numRows and check both round-trips.

---

## Verdict summary

**Direction 2 (ppq → row → ppq for on-grid p) holds.** ✓

**Direction 1 (row → ppq → row for integer r) FAILS under non-divisor
rpb (e.g. rpb=7).** ❌ The doc's "Held by float `rowPPQs[r] = r ·
logPerRow` plus matched `floor(x + 0.5)` rounding on both directions"
overclaims — `ppqToRow` has **no** rounding to match `rowToPPQ`'s
`floor(ppqI + 0.5)`. The asymmetry breaks strict equality whenever
`r · ppqPerRow` is fractional.

The drift is small (< 0.5) so any caller that rounds the result of
`ppqToRow` is unaffected — `util.round` recovers the original integer.
The on-grid check at vm:1872 also works because both sides go through
`rowToPPQ(integer)`, which is deterministic. So the bug is real but
mostly latent in practice.

---

## Detailed walk

### rowPPQs construction — vm:1828–1838

```lua
rowPPQs = {}
local r = 0
while true do
  local ppq = r * ppqPerRow
  if ppq >= length and r > 0 then break end
  rowPPQs[r] = ppq
  r = r + 1
end

local numRows = r
```

`rowPPQs[r] = r · ppqPerRow` exactly (floats, no rounding). Comment at
vm:1823–1827 confirms: floats are deliberate to avoid the
ε-compounding under non-divisor rpb that rounded rowPPQs would seed.

`ppqPerRow = (resolution * 4 / denom) / rpb` — fractional under
non-divisor rpb (e.g. rpb=7 with denom=4, resolution=240 gives
ppqPerRow = 960/7 ≈ 137.14).

### `ctx:rowToPPQ` — vm:61–71

```lua
function ctx:rowToPPQ(row, chan)
  if row <= 0 then return 0 end
  if row >= numRows then return length end
  local r        = math.floor(row)
  local frac     = row - r
  local rowStart = rowPPQs[r]
  local rowEnd   = rowPPQs[r + 1] or length
  local ppqL     = rowStart + frac * (rowEnd - rowStart)
  local ppqI     = swing.fromLogical(chan, ppqL)
  return math.floor(ppqI + 0.5)
end
```

For integer row r in (0, numRows): `frac = 0`, `ppqL = rowPPQs[r] = r ·
ppqPerRow`. Then `ppqI = swing.fromLogical(c, r · ppqPerRow)`. Returns
**`floor(ppqI + 0.5)` — rounded to integer.**

### `ctx:ppqToRow` — vm:47–59

```lua
function ctx:ppqToRow(ppqI, chan)
  local ppqL = swing.toLogical(chan, ppqI)
  if ppqL <= 0 then return 0 end
  if ppqL >= length then return numRows end
  local lo, hi = 0, numRows - 1
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if rowPPQs[mid] <= ppqL then lo = mid else hi = mid - 1 end
  end
  local rowStart = rowPPQs[lo]
  local rowEnd   = rowPPQs[lo + 1] or length
  return lo + (rowEnd > rowStart and (ppqL - rowStart) / (rowEnd - rowStart) or 0)
end
```

**No rounding at the return.** Returns a float `lo + frac` in
[lo, lo+1).

### Direction 1: ppqToRow ∘ rowToPPQ — fails under non-divisor rpb ❌

Take rpb=7, denom=4, resolution=240, identity swing, r=1:

- `rowToPPQ(1, c)`:
  - rowStart = `rowPPQs[1] = 960/7 ≈ 137.142857`
  - frac = 0, ppqL = 137.142857
  - ppqI = ppqL (identity) = 137.142857
  - returns `floor(137.142857 + 0.5) = floor(137.642857) = 137`
- `ppqToRow(137, c)`:
  - ppqL = 137 (identity)
  - Binary search: `rowPPQs[1] ≈ 137.143 > 137` → lo = 0
  - rowStart = 0, rowEnd = 137.143
  - returns `0 + 137 / 137.143 ≈ 0.9990`

`0.9990 ≠ 1` → **F4 direction 1 falsified.** Drift = ~0.001, well below
0.5.

For rows where `r · ppqPerRow` happens to be integer (every 7th row
under rpb=7: r ∈ {0, 7, 14, 21, ...}), the round-trip is exact. For
all other r, it drifts by sub-ppq fractional amounts.

Under divisor rpb (e.g. rpb=4 with denom=4, resolution=240,
ppqPerRow=240) every `r · ppqPerRow` is integer, so direction 1 holds
trivially.

The doc's claim "matched `floor(x + 0.5)` rounding on both directions"
is wrong: `rowToPPQ` rounds at realisation, but `ppqToRow` returns a
fractional row directly, with no symmetric rounding step. The
asymmetry is the failure mode.

### Direction 2: rowToPPQ ∘ ppqToRow — holds for on-grid p ✓

"On-grid" means `p = rowToPPQ(integer_r, c)` for some integer r. Trace:

- `ppqToRow(p, c)`:
  - ppqL_recov = `swing.toLogical(c, p)`
  - Binary search finds some `lo`, returns
    `row_back = lo + (ppqL_recov - rowPPQs[lo]) / ppqPerRow_lo`
- `rowToPPQ(row_back, c)`:
  - `r' = floor(row_back) = lo`
  - `frac' = row_back - lo`
  - `ppqL' = rowPPQs[lo] + frac' · (rowPPQs[lo+1] - rowPPQs[lo])`
  - simplifies to `ppqL_recov` exactly (algebraic identity in
    `frac'`'s definition)
  - `ppqI' = swing.fromLogical(c, ppqL_recov) = swing.fromLogical(c,
    swing.toLogical(c, p)) = p` (swing is a bijection)
  - returns `floor(p + 0.5) = p` (since p is integer)

✓ Direction 2 holds, modulo float-arithmetic exactness of the swing
bijection (timing.lua's `eval`/`invert` lerp; PWL float math is
generally bit-exact for rational breakpoints, holds in practice).

### Practical impact

Where direction 1 round-trip is used:

- **`adjustPosition` (vm:977)** uses `ctx:snapRow` which
  `util.round`s the row. Drift < 0.5 means snapRow recovers the
  intended integer. ✓
- **`adjustPositionMulti` (vm:951)** uses raw `ctx:ppqToRow + rowDelta`
  fed back to `at(rowS, rowE)`. Drift propagates as a fractional row
  into the new ppqL. Already flagged in F1 as a non-issue for F1 but
  potentially relevant to G1 (off-grid preservation under non-divisor
  rpb).
- **`adjustDurationCore` (vm:887)** has a comment at vm:879–882
  acknowledging this exact issue: it reads `endppqL / logPerRow`
  *directly* off the note rather than via `ppqToRow` to avoid drift.
  The comment is the smoking gun:

  > Read the current end row exactly off `endppqL` (authored
  > row * logPerRow) so `curRow + rowDelta` stays integer; otherwise
  > the ppq round-trip drifts and the first press into a neighbour can
  > fail to reach the `nextD + lenient` overlap bound.

  So the developer already knows the round-trip drifts and works
  around it. F4's "held by" claim contradicts this.

- **On-grid check (vm:1872)** `ctx:rowToPPQ(y, chan) ~= evt.ppq` works
  because *both* sides go through `rowToPPQ(integer)` which is
  deterministic — it doesn't actually exercise the round-trip.

### Recommendation

Either:
- **Tighten ppqToRow** to round at realisation (return
  `lo + util.round((ppqL - rowStart) / (rowEnd - rowStart))` or
  similar), making the round-trip exact for integer r — but then
  fractional-row callers (lane drag, off-grid display) lose their
  fractional resolution.
- **Loosen F4** to "round-trip up to a sub-row drift, recoverable by
  `util.round`" and remove the "matched rounding" claim from the doc.

The second is closer to what the code actually delivers. The
adjustDurationCore comment already documents the workaround.
