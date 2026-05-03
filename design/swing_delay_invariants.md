# Swing × delay × editing — invariants

A working list to audit `trackerManager` and `viewManager` against. The
question we want to answer for each: **does the code uphold this in
every editing path, or only in some?** Sources of truth are
`docs/timing.md` (frames, swing, delay) and `docs/tuning.md` (pb/detune
realisation).

Legend for "where to look":
- vm = `viewManager.lua`
- tm = `trackerManager.lua`
- ec = `editCursor.lua`
- ctx = `viewContext` (in vm)

Each invariant ends with a *falsifying scenario* — a one-line description
of the kind of test that would refute it. The audit holds iff no such
test can be constructed.

---

## How to audit (read this first across sessions)

**The pattern is per-invariant, exhaustive, code-referenced. No
"looks fine".** Past audits glossed sites and missed real bugs; the
process below is what worked.

For each invariant:

1. **Identify every site that could write the relevant fields.** For
   F1/F2/F3 that means `grep` for `ppqL\s*=`, `endppqL\s*=`, `delay`,
   `frame\s*=` across `viewManager.lua` and `editCursor.lua`. For L*/G*
   also include `assignEvent('note', ...)` callers. Cross-check against
   the invariant's own "where to look" list — don't trust it as
   complete; the code's the source of truth.
2. **Walk each site in turn.** Quote the actual block (with `file:line`
   refs), then state for that block: what it writes, what it leaves
   alone, and whether the invariant holds.
3. **Distinguish strict violations from common-case-clean / edge-case
   issues.** A site that breaks F1 only when `frame.rpb ≠ current.rpb`
   is a different class of bug from one that breaks unconditionally.
   Mark each finding clearly: ✓ holds, ⚠️ cross-rpb only / acknowledged,
   ❌ unconditional bug.
4. **Don't fix in the audit pass.** Collect the findings; a separate
   pass cleans them up. Avoids interleaving exploration with edits.
5. **Write each audit to `design/audit/<INVARIANT>_<name>.md`** (e.g.
   `F1_ppqL_pinning.md`). Each file: short verdict summary at the top
   (real bugs / cross-rpb / acknowledged), then the detailed walk. The
   summary is what gets read during the fix pass.
6. **One invariant at a time, report back to the user before
   continuing.** Don't batch — the user wants to see each in detail and
   may redirect mid-audit.

What "the falsifying scenario" buys you: it's a sanity check on the
invariant's *meaning*, not the audit's coverage. Once you've enumerated
the writers, derive whether the test could trip and on which path.

Anti-patterns from past sessions:

- "I checked X and it's fine" without quoting the code. ← This is the
  failure mode that triggered the careful re-audit.
- Conflating "F1 part 2 is vacuously true" with "the code is correct".
  Vacuity means F1 says nothing — separately check whether the code's
  doing the right thing for the surrounding invariants (G1 in
  particular).
- Stopping at viewManager. Paste sites in `editCursor.lua` write events
  with `ppqL`/`frame`/`endppq` and have caught real bugs.

---

## Frame integrity

### F1 — ppqL pinning
Every authored event with a `frame` stamps
`evt.ppqL = row · logPerRow_frame`. For an event whose `ppqL` is an
integer multiple of `logPerRow_frame`, `ctx:rowToPPQ(row, chan) == evt.ppq`
exactly (i.e. on-grid).

- Sole stamping helper: `vm.stamping(chan)` (vm).
- Other call sites that must obey the same shape: `placeNewNote`,
  `moveLaneEvent`, `insertRowCore`/`deleteRowCore`'s `shiftEvent`,
  clipboard paste sites in ec.
- *Falsifies:* author a note at row r, then read back `ppqL`; expect
  `r · logPerRow_currentFrame`.

### F2 — Delay independence
A delay-only edit changes `ppq` (realised) and nothing else: `ppqL`,
`endppqL`, `endppq`, `frame` all untouched. The map `delay → ppq` is
the integer bijection given by `timing.delayToPPQ`.

- vm: `editEvent` stop 5–7, `nudgeDelay`.
- tm: `realiseNoteUpdate` writes only `update.ppq`; `assignNote`
  routes through `resizeNote` (which shifts the absorber but not
  `endppq`).
- *Falsifies:* nudge a note's delay; expect `endppq`, `ppqL`, `endppqL`,
  `frame` byte-identical.

### F3 — endppq is intent at every layer
`endppq` is intent at mm, tm, vm storage. Only `ppq` carries the
realisation/intent split. tm's `tidyCol` strips delay only from `ppq`.

- *Latent write-side gap (now pinned by the fix in this branch):*
  `um:addEvent` historically added `delayToPPQ(delay)` to *both*
  `evt.ppq` and `evt.endppq`. Today no caller passes `delay ≠ 0` to
  `addEvent`, so this is unreachable — but the test set should pin
  it so a future caller can't trip it.
- *Falsifies:* `tm:addEvent('note', { …, delay = 500 })` directly;
  after rebuild, expect `endppq` unchanged from the caller's value.

### F4 — Round-trip exactness
Two corners hold:
1. **Integer row → intent ppq → integer row**, via the recovery operator:
   `ctx:snapRow(ctx:rowToPPQ(r, c), c) == r` for integer `r ∈ [0, numRows)`.
   Raw `ctx:ppqToRow ∘ rowToPPQ` is *not* the identity under non-divisor
   `rpb` — it drifts by `< 0.5` rows because `rowToPPQ` rounds at
   realisation but `ppqToRow` returns a fractional row. Callers needing
   an integer row back must go through `snapRow` (or `util.round`).
2. **On-grid ppq → row → ppq:** for `p = ctx:rowToPPQ(integer_r, c)`,
   `ctx:rowToPPQ(ctx:ppqToRow(p, c), c) == p` exactly.

- Held by float `rowPPQs[r] = r · logPerRow` (no rounding seeded into
  the row table) plus realisation rounding in `rowToPPQ`. The
  asymmetry is deliberate: `ppqToRow`'s fractional return is needed for
  lane drag and off-grid display.
- *Falsifies:* under any non-divisor `rpb` (e.g. 7), iterate
  `r = 0..numRows−1` and check `snapRow(rowToPPQ(r,c),c) == r`, plus
  for each such `r`, `rowToPPQ(ppqToRow(rowToPPQ(r,c),c),c) == rowToPPQ(r,c)`.

---

## Lane stability

### L1 — Delay can't change lane allocation
`noteColumnAccepts` judges in intent space (subtracts
`delayToPPQ(delay)` on both sides). Changing only `delay` on a note
cannot push it into another column or spring a new one.

- tm: `noteColumnAccepts` (around the `evt.ppq − delayToPPQ(...)`
  comparison). Comment in tm: "Delay does not affect column
  allocation."
- *Falsifies:* two same-pitch notes in lanes 1 and 2; delay-nudge
  the lane-1 note across the lane-2 onset in realised time; assert
  the lane-1 note's lane is still 1 after rebuild.

### L2 — Notes never change lane
For every note in the take, its `lane` after any edit + flush +
rebuild equals its `lane` before. **No exceptions.**

- Direct write paths: `tm:assignEvent('note', …)` rejects `lane` /
  `chan` keys outright.
- Indirect risk: `tm:rebuild`'s `allocateNoteColumn` prefers
  `note.lane` but **falls through to first-fit if
  `noteColumnAccepts(col, note)` is false**. So L2 holds *iff*
  every editing path leaves the lane in a state its persisted lane
  still accepts.
- Audit must check: `editEvent`, `placeNewNote`, `adjustPosition`,
  `adjustDuration`, `insertRowCore`, `deleteRowCore`, paste,
  duplicate, reswing, quantize, `quantizeKeepRealised`, lane-drag.
- Reswing is the most fragile case: monotone reparam preserves
  ordering, but rounding can in pathological cases collide two
  events at one ppq, triggering first-fit.
- **Open design question:** make `allocateNoteColumn` honour
  persisted `lane` unconditionally (only fall through when the
  lane doesn't *exist*, not when it doesn't *accept*). Turns L2
  into a hard contract instead of a downstream property.
- *Falsifies:* for each editing op, take a fixture with multiple
  lanes, run the op, assert every note's lane is unchanged
  post-rebuild.

### L3 — Real pbs are inviolate under note edits
Any note operation (add / assign / delete on any lane, any field)
leaves every real pb (no `fake` flag) byte-identical in
`(chan, ppq, val, shape, tension, ppqL, frame)`. Only fake pbs
may be created, moved, or removed by note edits.

- tm: lane-1 gates on `addNote`, `assignNote` (detune branch),
  `resizeNote`, `deleteNote`. `forcePb` only seats new pbs;
  `deletePb` only re-marks fake. Real pbs are never demoted by
  reconciliation.
- *Falsifies:* seed a real pb among notes; perform every kind of
  note edit including lane-≥2 edits; expect that pb byte-identical
  in `mm:dump()` after each.

---

## Grid stability

### G1 — On-grid preservation across edits
For any edit: every event whose intent ppq the edit didn't
deliberately move keeps its on-grid status; and every event the
edit did move lands on-grid in the post-edit frame.

- **Non-row-moving edits** (delay nudge, vel/pitch nudge w/o
  repitch-snap, detune change, value/shape on cc/pb/at):
  edited event's off-grid bit unchanged; every other event
  byte-identical.
- **Row-moving edits** (`editEvent` snap path,
  `adjustPosition[Multi]`, `placeNewNote`, paste, duplicate,
  reswing, quantize, `quantizeKeepRealised`,
  `insertRow`/`deleteRow`): edited event lands on-grid with no
  off-grid flag in the post-edit frame; untouched events
  byte-identical.
- Until this branch, `insertRow`/`deleteRow` violated G1 under any
  non-identity swing by adding a constant `dppq` to events at
  heterogeneous source rows. The fix re-realises each event's
  `ppq` from `swing.fromLogical(chan, newppqL)`.
- *Falsifies:* under c58 swing, seed several on-grid events,
  insert a row above the lowest, and assert all post-edit events
  remain on-grid in current frame; do the same for delete.

### G2 — Off-grid edits snap to cursor row
`editEvent` on an off-grid event repins `(ppq, ppqL, frame)` to the
cursor row in current frame; for notes, logical duration
(`endppqL − ppqL`) is preserved exactly.

- vm: `snap` inside `editEvent`.
- *Falsifies:* seed an off-grid note (e.g. via swing change after
  authoring); type a new pitch over it from a different row;
  expect the note's `ppq` and `ppqL` repinned to cursor row, and
  `endppqL − ppqL` preserved.

### G3 — Swing change surfaces off-grid honestly
Under a new global swing or per-column swing, events whose realised
ppq sat at the old swung grid surface as off-grid (already pinned
by `vm_grid_spec` "swing change: notes authored under swing-off…").

### G4 — Reswing recovers on-grid
`reswingScope` re-realises events with stamped `ppqL + frame` so
they display on-grid in the new frame, with no off-grid flag and
no spurious row jump. Events outside scope (other channels in
`reswingSelection`, untouched events in `reswingPresetChange`)
byte-identical.

- vm: `reswingCore`'s monotone plan + post-reswing delay clamp.
- *Falsifies:* author notes under nil-frame, switch swing, run
  `reswingAll`; expect zero off-grid flags and `ppqL` unchanged.

---

## Single voice

### V1 — One voice per (chan, pitch)
After any edit + flush + rebuild, no two notes share `(chan, pitch)`
with intersecting `[ppq, endppq)` and none share `(chan, pitch, ppq)`.

- tm: `clearSameKeyRange` runs on every add and on every assign
  that touches `ppq`/`endppq`/`pitch` (unless `trustGeometry`).
  Rebuild's group-by-pitch truncation is the backstop.
- vm: `delayRange` enforces a same-pitch channel-wide bound on
  delay so realised onsets stay ordered with intent ends.
- *Falsifies:* iterate all pairs of same-`(chan, pitch)` notes
  after each kind of edit; expect disjoint intervals.

### V2 — Reswing's `trustGeometry` is sound
The `trustGeometry` opt-out in reswing must not introduce a same-pitch
overlap absent in the source. Held by: pitch unchanged + monotone
fromLogical + post-reswing delay clamp.

- *Falsifies:* same-pitch siblings butted end-to-end (legato join);
  reswing into c58 and back to identity; expect both intact and
  joined.

---

## Tuning interaction

### T1 — Orthogonality under delay
Delay-only edit on a lane-1 note: pb count unchanged, logical pb
stream unchanged, fake absorber (if any) follows the host's
realised onset.

- tm: `realiseNoteUpdate` sets `update.ppq` ⇒ `assignNote` routes
  through `resizeNote`, which deletes the fake at the old realised
  seat and reseats at the new realised seat. Lane-1-only.
- *Falsifies:* lane-1 note with detune ≠ 0 (so an absorber seats);
  delay-nudge the note; expect identical pb count, fake pb's
  `ppq` shifted by `delayToPPQ(dNew − dOld)`, logical pb stream
  (raw − detune) unchanged at every sample.

### T2 — Orthogonality under reswing
Reswing preserves pb count and the `(fake?, val, shape, tension)`
profile of every pb; each pb's new `ppq` is
`round(target.fromLogical(chan, pb.ppqL))`.

- vm: pbs go through `reswingCore` plans alongside notes; their
  `ppqL` drives `newppq`. detune ledger isn't consulted in reswing.
- *Falsifies:* mixed notes + pbs under c58; reswing into identity;
  expect every pb's new `ppq == round(id.fromLogical(chan, ppqL))`
  and `fake` flag unchanged.

---

## Audit checklist

For each editing path below, walk through every invariant and ask
"can this op falsify it?" Path × invariant matrix; cells either
"holds — by mechanism X" or "fails — scenario Y".

Editing paths:

- `vm:editEvent` — pitch (note), octave (note), velocity (note/PA),
  delay (note), val (cc/at/pc/pb), with and without an off-grid
  source event
- `placeNewNote` (fall-through from `editEvent` pitch with no resident)
- `vm:moveLaneEvent` — integer toRow, fractional toRow
- `nudge` — pitch, velocity, delay, value
- `adjustPosition`, `adjustPositionMulti`
- `adjustDuration` (grow/shrink)
- `noteOff`
- `insertRow`, `deleteRow`
- `duplicate` (up/down)
- `clipboard.paste` (single, multi; note→note, pb→pb, 7bit→cc, 7bit→note)
- `reswingSelection`, `reswingAll`, `reswingPreset`
- `quantizeSelection`, `quantizeAll`
- `quantizeKeepRealisedSelection`, `quantizeKeepRealisedAll`
- `interpolate` (cycles shape; doesn't move ppq)
- `deleteEvent`, `deleteSelection`

Cross-cutting paths to also verify:

- `tm:rebuild` after a take swap (lane preservation under foreign
  MIDI)
- `tm:setMutedChannels` (must not move events)
- Transient frame override (Ctrl-G `matchGridToCursor` and release)
