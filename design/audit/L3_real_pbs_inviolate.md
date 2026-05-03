# L3 — Real pbs are inviolate under note edits  ✅ HOLDS

**Invariant**: Any note operation (add / assign / delete on any lane,
any field) leaves every real pb (no `fake` flag) byte-identical in
`(chan, ppq, val, shape, tension, ppqL, frame)`. Only fake pbs may be
created, moved, or removed by note edits.

**Falsifying test**: seed a real pb among notes; perform every kind of
note edit including lane-≥2 edits; expect that pb byte-identical in
`mm:dump()` after each.

---

## Verdict

L3 holds. The mechanism is two independent safety nets, one per
field-class:

- **Identity fields** (`ppq`, `shape`, `tension`, `ppqL`, `frame`,
  `fake` flag): no note op writes these on existing pbs. The only
  pb-mutating helpers note ops can reach — `forcePb`, `markFake`,
  `unmarkFake`, `deleteLowlevel('pb', …)` — either gate on
  `pb == nil` (forcePb), gate on `pb.fake == true`
  (markFake/unmarkFake/conditional delete in resizeNote/deleteNote),
  or are simply not called.
- **`val` field**: `retuneLowlevel` writes raw `val` on every pb in a
  range, real and fake alike. Per the I1 identity in
  `docs/tuning.md`, `val` at tm-level is **logical**
  (`raw − detune`); at mm-level it is raw. The note-op contract is
  that the raw shift `retuneLowlevel` applies exactly mirrors the
  carry shift the note edit causes in the same range, so logical
  `val` (what L3's "byte-identical val" means at the tm surface) is
  preserved. The audit verifies this match for each note op below.

L3 corresponds tightly to invariants I2 (real pbs never deleted by
reconciliation), I3 (lane-≥2 monopoly), and I4 (no demotion of real
to fake) in `docs/tuning.md`.

### Rule to extract into docs

> **Real pbs are tm-managed only at the raw/logical conversion
> boundary.** The four tm helpers that touch pbs after a note edit —
> `forcePb`, `markFake`, `unmarkFake`,
> `deleteLowlevel('pb', …)` — are each gated against real-pb
> mutation: forcePb gates on absence, markFake/unmarkFake check the
> fake flag, deletePb branches on it. The only exception is
> `retuneLowlevel`, which rewrites raw `val` on every pb in a range
> (real and fake) — but the `delta` it receives is always the same
> as the carry shift the note edit caused over the same range, so
> tm-level logical `val` is preserved. Any future helper that
> rewrites pb fields must either match this gating pattern or fail
> L3.
>
> **Carry-shift / raw-shift correspondence is the load-bearing
> property.** It only holds when the note edit doesn't move the
> note's onset across an intervening lane-1 sibling (which would
> make `C1 ≠ C2` in resizeNote's "withdraw-and-reapply" math).
> vm-side bounds — `overlapBounds` for ppq edits, `delayRange` for
> delay edits — enforce this by clamping at the prev/next lane-1
> sibling. Any new editing path that writes ppq through tm must
> route through one of these or supply equivalent bounds.

---

## Detailed walk

### tm pb-mutating helpers — gating summary

| Helper                        | What it writes              | Real-pb gate                                                   |
|-------------------------------|-----------------------------|----------------------------------------------------------------|
| `retuneLowlevel(c, P1, P2, δ)`| `val += δ` on every pb in `[P1, P2)` | None — *but* δ matches carry shift, so logical preserved      |
| `forcePb(c, P, extras)`       | adds new pb at P            | Returns false (no-op) if a pb already exists at P              |
| `markFake(c, P)`              | sets `fake = true`          | Only acts if pb already exists; called only after forcePb succeeded |
| `unmarkFake(c, P)`            | sets `fake = REMOVE`        | Early-returns if `not (pb and pb.fake)` — real pbs untouched   |
| `deletePb(pb)` (high-level op)| del or markFake             | Called by `um:deleteEvent('pb', …)` only — not from note ops   |
| `reconcileBoundary(c, P)`     | conditional delete / forcePb+markFake | `delete` arm gated on `pb.fake`; `forcePb+markFake` arm gated on `not pb` — real pbs untouched on both arms |

So among the helpers note ops can call, the only one that touches
existing real pbs is `retuneLowlevel`, and only via `val`. Logical
preservation is the question for each note op below.

### `addNote` — tm:298–311

```lua
local function addNote(n)
  local D = n.detune
  if lastMuteSet[n.chan] then n.muted = true end
  if n.lane == 1 then
    local C     = detuneAt(n.chan, n.ppq)
    local nextP = nextNotePPQ(n.chan, n.ppq)
    if D ~= C and forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
    retuneLowlevel(n.chan, n.ppq, nextP, D - C)
    addLowlevel('note', util.assign(n, { detune = D }))
    reconcileBoundary(n.chan, nextP)
  else
    addLowlevel('note', util.assign(n, { detune = D }))
  end
end
```

- **Lane ≥2**: only `addLowlevel('note', …)` — no pb interaction. ✓
  (I3 monopoly.)
- **Lane 1**:
  - `forcePb(n.ppq)` only seats if no pb exists; if a real pb already
    sits at `n.ppq`, forcePb returns false → no markFake fires →
    real pb unchanged. ✓
  - `retuneLowlevel(n.ppq, nextP, D − C)`: pre-add carry on
    `[n.ppq, nextP)` was C (no note here yet); post-add it is D.
    Carry shift = D − C, exactly the δ passed. Logical preserved
    for every real pb in the range. Real pbs outside the range
    untouched. ✓
  - `reconcileBoundary(nextP)`: real-safe per the table.

### `deleteNote` — tm:313–323

```lua
local function deleteNote(n, keepPAs)
  if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel('pa', evt) end) end
  if n.lane ~= 1 then deleteLowlevel('note', n); return end
  local D1, D2 = detuneBefore(n.chan, n.ppq), detuneAt(n.chan, n.ppq)
  local nextP  = nextNotePPQ(n.chan, n.ppq)
  local pb     = pbAt(n.chan, n.ppq)
  if pb and pb.fake then deleteLowlevel('pb', pb) end
  deleteLowlevel('note', n)
  retuneLowlevel(n.chan, n.ppq, nextP, D1 - D2)
  reconcileBoundary(n.chan, nextP)
end
```

- **Lane ≥2**: PA cleanup + deleteLowlevel — no pb. ✓
- **Lane 1**:
  - `if pb and pb.fake then delete` — real pb at `n.ppq` survives
    (the `fake` test gates the delete). ✓
  - `retuneLowlevel(n.ppq, nextP, D1 − D2)`: pre-delete carry on
    `[n.ppq, nextP)` was D2 (= n's detune); post-delete it is D1
    (prev detune since n is gone). Carry shift = D1 − D2, exactly
    the δ. ✓
  - `reconcileBoundary(nextP)`: real-safe.

  Note that the surviving real pb at `n.ppq` (now host-less) gets
  its raw shifted by D1 − D2. Carry at its ppq pre-delete was D2,
  post-delete is D1. Shift matches. Logical preserved. ✓

### `assignNote` — detune branch — tm:395–408

```lua
if n.lane == 1 and update.detune ~= nil and update.detune ~= n.detune then
  local nextP = nextNotePPQ(n.chan, n.ppq)
  if forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
  retuneLowlevel(n.chan, n.ppq, nextP, update.detune - n.detune)
  assignLowlevel('note', n, { detune = update.detune })
  update.detune = nil
  reconcileBoundary(n.chan, n.ppq)
  reconcileBoundary(n.chan, nextP)
end
```

- Lane ≥2 detune writes skip this branch entirely (`n.lane == 1`
  guard) → just `assignLowlevel('note', …, { detune = … })`. No pb
  interaction. ✓ I3.
- `forcePb` conditional: if real pb already at `n.ppq`, forcePb
  returns false → no markFake → real pb stays real. ✓
- `retuneLowlevel(n.ppq, nextP, newD − oldD)`: range carry shifts
  from oldD (= n.detune) to newD (= update.detune). Match. ✓
- Both `reconcileBoundary` calls: real-safe.

Other branches of `assignNote`:

- `update.ppq`/`update.endppq` → `resizeNote` (covered next).
- `update.pitch` → only writes pitch on attached PAs and the note
  itself; no pb interaction.
- Other fields (vel, muted, …) → `assignLowlevel('note', …)`, no pb.

### `resizeNote` — tm:325–382 (the most intricate case)

The col1 path is the one to scrutinise; the `not col1` branch just
writes ppq/endppq via `assignLowlevel` with no pb interaction.

```lua
local oldppq = n.ppq
local D   = n.detune
local L   = logicalAt(n.chan, P1)
local C1  = detuneBefore(n.chan, oldppq)
local NP1 = nextNotePPQ(n.chan, oldppq)
local oldPb = pbAt(n.chan, oldppq)

assignLowlevel('note', n, { ppq = P1, endppq = P2 })

if oldPb and oldPb.fake then
  deleteLowlevel('pb', oldPb)
end
retuneLowlevel(n.chan, oldppq, NP1, C1 - D)
reconcileBoundary(n.chan, NP1)

local C2 = detuneBefore(n.chan, P1)
if L ~= logicalBefore(n.chan, P1) then
  forcePb(n.chan, P1)
elseif D ~= C2 and forcePb(n.chan, P1) then
  markFake(n.chan, P1)
end
local NP2 = nextNotePPQ(n.chan, P1)
retuneLowlevel(n.chan, P1, NP2, D - C2)
reconcileBoundary(n.chan, NP2)
```

- `oldPb` deletion gated on `fake`. Real pb at oldppq survives. ✓
- First retune `[oldppq, NP1)` with δ = C1 − D: carry in this range
  was D (note here), becomes C1 (note moved away). Match in this
  range. Real pbs in the range get raw shifted by C1 − D, logical
  preserved.
- Second retune `[P1, NP2)` with δ = D − C2: post-move carry in
  `[P1, NP2)` is D (note now seats here). Pre-move carry was C2 in
  the same range *only if no other note bridges between* — which is
  the standing assumption (see "no-intervening" condition below).
- `forcePb(P1)` in the L-mismatch branch *seats a real pb*: this is
  the one place a note op deliberately creates a real pb. It does so
  only when `L = logicalAt(n.chan, P1)` (captured pre-mutation)
  differs from `logicalBefore(P1)` (read post-mutation), i.e., when
  the user authored a logical-pb seat at P1 that needs to survive
  the move. This **does not modify any pre-existing real pb** —
  forcePb gates on absence. It creates a new real pb where the user
  intended one to be.
- The elseif arm seats a fake absorber — also gated on absence.
- Both `reconcileBoundary` calls real-safe.

#### The carry-shift / raw-shift correspondence — when does it hold?

For real pbs in the *intersection* `[oldppq, NP1) ∩ [P1, NP2)`, both
retunes apply. Net raw shift = `(C1 − D) + (D − C2) = C1 − C2`. The
carry change in that intersection depends on direction:

- **Forward delay (P1 > oldppq)**: intersection is `[P1, NP1)`. Carry
  pre-move = D (was inside [oldppq, NP1)), post-move = D (now inside
  [P1, NP1) under the moved note). Carry shift = 0.
  - Logical preserved iff net raw shift = 0 iff `C1 = C2`.
- **Backward delay (P1 < oldppq)**: similar, intersection is
  `[oldppq, NP2)`. Carry pre-move = C1 (note was at oldppq, this
  range is after it), wait no — this gets messy. Symmetric reasoning
  applies.

`C1 = detuneBefore(oldppq)` and `C2 = detuneBefore(P1)`. They are
equal iff no lane-1 note onset sits in the open interval between
oldppq and P1.

vm-side bounds enforce no such intervening:

- For delay-only edits (the resizeNote-via-realiseNoteUpdate path):
  `delayRange` (vm:192) bounds at the prev/next lane-1 sibling's
  realised onset (same-col arm) and same-pitch endppq (channel-wide
  arm). Either way, the moved note can't reach across a sibling. ✓
- For ppq edits (`adjustPosition` etc.): `overlapBounds` (vm:167)
  bounds against prev/next col-mates and same-pitch siblings. Since
  the moved note is in lane 1 in this analysis, col-mates are other
  lane-1 notes — the bound rules out crossing. ✓
- For paste/duplicate writes via `tm:addEvent`, the addNote path
  applies (single-onset insert, no resizeNote called).
- For reswing via `tm:assignEvent` with trustGeometry: each event
  reswings to a new ppq via `swing.fromLogical`. Could two adjacent
  lane-1 notes' ppqs *swap* under reswing? No — reswing is monotone
  per channel, so per-channel ordering is preserved. Could they
  *collide* (round to same ppq)? Yes — same fragility as L2's
  rounding case. If two lane-1 notes collide at the same intent
  ppq, the second one's resizeNote could see C1 ≠ C2 if the first
  one already arrived. Acknowledged below.

So the carry-shift/raw-shift match holds for every editing path
reachable from vm, and L3 holds in the strong byte-identical sense
for real pbs.

### Acknowledged edge — reswing collision

If two lane-1 notes round to identical ppq under reswing (the L2
fragility), the second-iterated note's resizeNote sees the first
already at that ppq, which can make `C1 ≠ C2` and break the
carry-shift/raw-shift match. Real pb logical drifts by C1 − C2.

This is the same root cause as L2's rounding fragility — the same
fix (unconditional persisted-lane honouring at allocateNoteColumn,
or a pre-clamp that rejects co-located ppqs from reswing's plan)
closes both. Worth keeping in mind when L2's open design question is
resolved.

### `clearSameKeyRange` — tm:421–437

CSK calls `deleteNote(n)` for prior siblings (line 434) and
`assignNote(n, { endppq = P })` for truncations (line 435). Both
covered above:

- `deleteNote` is L3-safe.
- `assignNote(n, { endppq = P })` → `resizeNote(n, n.ppq, P)` →
  shift = 0 → first/second retunes cancel net to zero on every real
  pb (range and δ are symmetric). ✓

### `realiseNoteUpdate` — tm:460–468

Only writes `update.ppq`. Doesn't touch any pb. The downstream effect
is via resizeNote, covered above.

### Rebuild

- **Step 1** — seeds detune/delay defaults via `mm:assignNote(loc, …)`
  (metadata-only, lockless). Doesn't touch pbs at mm or tm level. ✓
- **Step 1's truncation pass** — `mm:assignNote(loc, { endppq = … })`.
  Direct mm call, no um cascade. Doesn't touch pbs. The detune carry
  (which is keyed on note *onsets*, not endppqs) is unchanged, so
  tm-level logical pb val recomputation at step 3 yields the same
  logical for every real pb. ✓
- **Step 3** — pb assembly reads mm and computes
  `val = round(rawToCents(cc.val) − detune)`. Pure read at the mm
  side; tm-side it builds a fresh per-rebuild representation. Real
  pbs' raw is unchanged from before rebuild, detune carry unchanged,
  so logical val unchanged. ✓

### Summary

| Note op                                  | Holds L3? |
|------------------------------------------|-----------|
| `addNote` lane ≥2                        | ✓ vacuous (I3) |
| `addNote` lane 1                         | ✓ retune δ matches carry shift |
| `deleteNote` lane ≥2                     | ✓ vacuous (I3) |
| `deleteNote` lane 1                      | ✓ pb-at-onset gated on fake; retune matches |
| `assignNote` detune lane ≥2              | ✓ vacuous (I3) |
| `assignNote` detune lane 1               | ✓ forcePb gated on absence; retune matches |
| `assignNote` ppq/endppq → `resizeNote` not col1 | ✓ no pb interaction |
| `assignNote` ppq/endppq → `resizeNote` col1     | ✓ when `C1 = C2` (vm bounds enforce) |
| `assignNote` pitch                       | ✓ no pb interaction |
| `assignNote` other (vel, muted, …)       | ✓ no pb interaction |
| `clearSameKeyRange` (delete + truncate)  | ✓ inherits deleteNote and shift-0 resize |
| `realiseNoteUpdate`                      | ✓ delegates to resizeNote |
| Rebuild step 1 (detune/delay seed + truncate) | ✓ mm metadata-only |
| Rebuild step 3 (pb assembly)             | ✓ pure read |
| Reswing co-location (L2 fragility)       | ⚠️ inherits L2 — see acknowledged edge |
