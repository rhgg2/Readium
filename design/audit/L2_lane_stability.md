# L2 — Notes never change lane  ⚠️ HOLDS UP TO ROUNDING (one fragility class across multiple paths, one orphan bug)

**Invariant**: For every note in the take, its `lane` after any edit +
flush + rebuild equals its `lane` before. **No exceptions.**

**Falsifying test**: for each editing op, take a fixture with multiple
lanes, run the op, assert every note's lane is unchanged post-rebuild.

---

## Verdict

L2 holds modulo a single fragility class — **rounding-induced
overlap drift** — that affects every path recomputing ppq from
rounded swing/grid math. Same-pitch instances are caught by CSK on
all paths except reswing (which opts out via `trustGeometry`).
Different-pitch instances are caught nowhere; CSK doesn't cover
them. See "Acknowledged fragility" below for the full path×case
matrix.

The mechanism is two-layered:

1. **Direct**: `assignNote` (tm:386) rejects `update.lane` outright,
   so no editing path can flip a note's persisted `lane` field by
   accident. The only legitimate writes of `note.lane` happen in
   rebuild step 2 itself (tm:707, when allocateNoteColumn returns a
   different lane than the persisted one) or via `mm:assignNote(loc,
   { lane = ... })` directly (used by tm:rebuild's reconciliation
   write).
2. **Indirect**: rebuild's `allocateNoteColumn` honours `note.lane`
   first; it falls through to first-fit only when
   `noteColumnAccepts(notes[note.lane], note)` returns false. So L2
   reduces to: every editing path must leave each note in a state its
   persisted lane still accepts. Per-path: **yes**, by the bounds
   below.

### Acknowledged fragility — rounding past the acceptance threshold

Any path that rewrites a note's `ppq` or `endppq` from a rounded
swing-or-grid expression (`util.round(swing.fromLogical(chan, ppqL))`
or `ctx:rowToPPQ(row, chan)`) can perturb the field by up to ±0.5
ppq independently of any other field. Two col-mates each rounding
independently means the overlap amount between them can shift by up
to ±1 ppq per recomputation.

`noteColumnAccepts` rejects when `overlapAmount > threshold`, where
threshold is `0` for same-pitch col-mates and `lenient = overlapOffset
* resolution` for different-pitch. This bites in two ways:

- **Same-pitch (threshold 0)**: two distinct ppqLs round to identical
  ppq → the `noteppqI == evtppqI ⇒ false` arm fires. Caught by CSK
  *if* the path runs CSK (i.e. `trustGeometry` is not set); otherwise
  exposed.
- **Different-pitch (threshold `lenient`)**: two col-mates sitting at
  *exactly* `lenient` overlap round to overlap > `lenient`. The
  editor actively produces such pairs — `overlapBounds`/`adjust*` use
  this same `lenient` as the positive bound on permitted overlap, so
  authored notes can sit right on the boundary. **CSK does not cover
  this case** (CSK is same-pitch only). So *every* path that recomputes
  ppq from rounded math is exposed, even with the per-write clamp on.

Path exposure:

| Path                                    | Same-pitch fragility | Different-pitch fragility |
|-----------------------------------------|----------------------|----------------------------|
| `reswing*` (trustGeometry on)           | ⚠️ exposed           | ⚠️ exposed                 |
| `quantize*`                             | ✓ CSK catches        | ⚠️ exposed                 |
| `quantizeKeepRealised*`                 | ✓ CSK catches        | ⚠️ exposed                 |
| `insertRow` / `deleteRow` (non-identity swing) | ✓ CSK catches | ⚠️ exposed                 |
| `editEvent` snap (sub-row only)         | ✓ CSK catches        | bounded sub-row, ✓ in practice |

The different-pitch case is the more practically reachable one: any
pair of col-mates the user adjusted up to the bound is one rounding
event away from a lane flip. The window is one ppq wide, but the
*number* of such pairs scales with how aggressively the user packs the
column.

Pinning fixtures should construct: (a) two same-pitch siblings across
distinct cols at sub-PPQ source ppqLs that reswing rounds together;
(b) two different-pitch col-mates sitting at exactly `overlapOffset`
intent overlap, then reswung / quantized / row-shifted into a
slightly-different intent gap.

**Open design question (carried from the source doc)**: make
`allocateNoteColumn` honour persisted `lane` unconditionally — only
fall through when the lane doesn't *exist*, not when it doesn't
*accept*. Closes both fragility classes above for *every* path. The
cost is that two col-mates can end up over the acceptance threshold
in the same column, which the renderer would have to handle
gracefully — it already handles same-row collisions via
`gridCol.overflow[y] = true` (vm:1875), so the affordance is partly
in place. Worth weighing against the per-path patchwork.

### Orphan bug — `vm:hideExtraCol` lane-shift is silently dropped

`vm:hideExtraCol` (vm:1660–1664) tries to shift higher-lane notes
down by writing `tm:assignEvent('note', evt, { lane = lane - 1 })`.
That update is rejected by `assignNote` at tm:386 (with a `print`).
Net effect: notes keep their old `note.lane`; on the next rebuild,
`allocateNoteColumn` regrows the closed column to honour the
persisted lane (tm:630), and rebuild step 4's `if n > want.notes
then want.notes = n` bumps `extraColumns` back up. The hidden column
reappears.

This isn't an L2 violation — L2 says lanes don't drift, and they
don't drift here either; the user's *intent* to hide is what's
dropped. Filing it as a separate finding.

### Rule to extract into docs

> **Lane is a rebuild-only field on notes.** No editing op may write
> `note.lane`; the only legitimate writes are by `tm:rebuild` itself
> (recording the allocator's decision back to mm) and direct
> `mm:assignNote` calls from inside rebuild. The `assignNote` gate at
> tm:386 enforces this; any caller wanting to *move* a note between
> lanes has to express that as a delete + add, not as a `lane`
> assignment, because the persisted lane is what `allocateNoteColumn`
> reads.
>
> **L2 is held downstream of CSK and the overlap bounds.** Any path
> that moves intent ppq/endppq/pitch must leave the note inside its
> column's `noteColumnAccepts` window. The realised mechanisms are:
> `overlapBounds` for adjust-style ops (clamp at lenient threshold);
> `clearSameKeyRange` for ops that change pitch / shrink intervals
> (deletes/truncates same-pitch collisions); paste's region-clear +
> end-cap (no neighbour overlap by construction); reswing's monotone
> guarantee (orderwise, modulo rounding). Any new editing op must
> route through one of these or supply its own equivalent.

---

## Detailed walk

### Allocation surface — tm:603–639

Recap: the only consumer of `note.lane` is `allocateNoteColumn`, the
only caller of `noteColumnAccepts`, the only caller of `pushNoteCol`
in steady state. The decision flow:

```
if note.lane and notes[note.lane] then
  if noteColumnAccepts(notes[note.lane], note) then return note.lane
  else fall through (first-fit, then spill)
elseif note.lane then
  grow notes to note.lane and return it
else
  first-fit, then spill
end
```

So L2 holds iff, for every editing path, after flush+rebuild:

- `note.lane` is the same value it had before (assignNote gate
  enforces this for all `tm:assignEvent` writes).
- `noteColumnAccepts(notes[note.lane], note)` returns true at the
  moment allocation runs.

`noteColumnAccepts` is intent-vs-intent (see L1 audit) and depends on
`(intent ppq, intent endppq, pitch)` of the candidate plus the
already-allocated col-mates.

### Direct writes of `note.lane`

| Site                           | Writes lane?                       |
|--------------------------------|------------------------------------|
| `assignNote` (tm:384)          | rejects via tm:386 print + return  |
| `addNote` (via `um:addEvent`)  | takes `evt.lane` as the seed for the new note (tm:504) |
| `mm:assignNote` direct         | only called from rebuild step 2 (tm:707) and step 1 (tm:682, 697) — neither writes `lane` |
| `vm:hideExtraCol`              | tries `tm:assignEvent('note', …, { lane = … })` → blocked at the gate; orphan bug above |

So the only way `note.lane` can change between rebuilds is via
rebuild's own write at tm:707 (when allocator picked something other
than `note.lane`). Therefore L2 reduces to "allocator picks
`note.lane` for every existing note on every rebuild".

### Per-path walk

For each editing path: what changes, and why noteColumnAccepts still
holds.

#### `editEvent` — vm:553

| stop          | writes                          | gate                      | L2 mechanism                                                                 |
|---------------|---------------------------------|---------------------------|------------------------------------------------------------------------------|
| 1 (pitch)     | `{ pitch, detune, [snap...] }`  | CSK runs (pitch in update) | CSK truncates/deletes any same-`(chan, new_pitch)` overlap before the write succeeds; col-mate same-pitch checks then pass. snap is sub-row (cursor sits on the off-grid event's display row), so diff-pitch overlap stays within `lenient`. |
| 2 (octave)    | `{ pitch }`                     | CSK runs                  | as above; no ppq move.                                                       |
| 5/6/7 (delay) | `{ delay }`                     | none (delay-only)         | covered by L1 — intent unchanged on both sides.                              |
| vel           | `{ vel }`                       | none                      | nothing noteColumnAccepts reads.                                             |
| pa-create     | `tm:addEvent('pa', …)`          | n/a                       | PAs aren't notes; no lane allocation.                                        |
| cc/at/pc/pb val | non-note                      | n/a                       | not L2-relevant.                                                             |

Off-grid snap (vm:572) deserves a note: it fires only when
`evt.ppq ~= cursorppq`, but `evt = col.cells[cursorRow]` already
constrains `evt`'s display row to equal `cursorRow`. So the ppq shift
is sub-row (within one row's worth of ppq). Different-pitch col-mates
sit at other display rows — at least one row away — so a sub-row
shift can't push the edited note into one's window past the `lenient`
threshold. Same-pitch handling is via CSK as above.

#### `placeNewNote` — vm:528 ✓

```lua
local last = util.seek(col.events, 'before', update.ppq, util.isNote)
local next = util.seek(col.events, 'after',  update.ppq, util.isNote)
if last and last.endppq >= update.ppq then
  assignTail(last, col.midiChan, update.ppq, update.ppqL)
end
update.endppq = next and next.ppq or length
update.lane   = col.lane
```

Truncates `last.endppq` to `update.ppq` (no overlap with new note).
New note's endppq = `next.ppq` (no overlap with successor). New note
seeded with `lane = col.lane`. ✓

#### `moveLaneEvent` — vm:729 ✓ vacuous

Excludes notes outright (`if not util.oneOf('cc pb at', col.type)
then return end`). ✓

#### `nudgePitch` / `nudgeVel` / `nudgeDelay` / `nudgeValue` — vm:1348/1354/1361/1367

Same shape as their `editEvent` cousins: pitch goes through CSK,
vel/value don't touch noteColumnAccepts inputs, delay covered by L1.

#### `adjustPosition` / `adjustPositionMulti` — vm:975 / vm:922 ✓

Bounded by `overlapBounds(col, note.ppq, note, false)` (vm:984) for
single, or per-direction extrema for multi (vm:933, 937). The
`allowOverlap = false` arg sets `lenient = 0` — bounds are tighter
than `noteColumnAccepts`'s lenient threshold, so the post-move
position remains in-window. Same-pitch arm is channel-wide
(`prevS, nextS` in `overlapBounds`), so same-pitch always disjoint. ✓

#### `adjustDuration` — vm:892, 906 ✓

Bounded by `overlapBounds(col, note.ppq, note, true)` (vm:899). The
`allowOverlap = true` arg gives `lenient = overlapOffset *
resolution` — exactly the threshold `noteColumnAccepts` uses. So an
extension up to the bound stays within the accept window. ✓

#### `noteOff` — vm:851 ✓

Only shrinks/extends the last note's tail in the cursor's row range.
Bounded by `overlapBounds(col, last.ppq, last, true)` (vm:845). Same
threshold-equivalence as `adjustDuration`. ✓

#### `insertRowCore` / `deleteRowCore` — vm:1243 / vm:1269 ✓

Per-event shift via `shiftEvent` (vm:1227): `newppqL =
logicalOf(e) + dLogical`, `newppq = round(swing.fromLogical(chan,
newppqL))`. Within a single column, every event takes the same
dLogical, and the swing map is monotone, so post-shift relative order
is preserved and overlap windows shift uniformly. Spanning notes get
their tail clipped via `assignTail` (only shrinks endppq → strictly
easier to fit). ✓

The G1 fix that re-realises ppq via `swing.fromLogical(chan,
newppqL)` is what makes this hold under non-identity swing — a flat
`+dppq` would have left events landing at non-grid positions, but the
per-column relative ordering still holds even under the broken
version (uniform shift preserves relative deltas). So this path was
sound for L2 even before the G1 fix.

#### `paste` (single, multi) — editCursor.lua:670 / 815 ✓

Both paths:

1. Truncate `lastNote.endppq` to `events[1].ppq` if it spans into the
   region (single: 675, multi: 818).
2. Delete in-region survivors (single: 678, multi: 821).
3. Cap pasted note's `endppq` to `nextNotePPQ` (single: 692, multi:
   837).
4. Add new notes with `lane = dstCol.lane` / `lane = r.lane`.

Post-paste in the dst column: lastNote (truncated) ⟂ pasted notes (no
overlap) ⟂ nextNote. ✓ for all parties involved.

For other lanes: untouched. Their persisted `note.lane` and
col-mates' intents unchanged. ✓

#### `duplicate` — vm:1543 ✓

Implemented as `clipboard:pasteClip(clip)` with a target row offset.
Inherits paste's L2 properties. ✓

#### `reswingScope` / `reswingPresetChange` — vm:1111 / vm:1122 — ⚠️

Walked above under "Acknowledged fragility". Both same-pitch
sub-PPQ-collision and different-pitch threshold-brushing are reachable
because `trustGeometry = true` skips the per-write CSK clamp and
because each ppq is rounded independently after `swing.fromLogical`.

The `pass 1.5 delay clamp` (vm:1064–1084) only touches `delay`, not
`ppq`/`endppq`. It enforces realised-order = intent-order; doesn't
help with intent collisions or threshold-brushing.

#### `quantizeScope` — vm:1139 ✓

Snaps `ppq`/`endppq` to grid. Each write goes through
`tm:assignEvent` *without* `trustGeometry`, so CSK runs. If
post-quantize geometry would collide two same-pitch siblings, CSK
truncates/deletes one before the next assignEvent sees it.
noteColumnAccepts holds for the post-CSK state. ✓

The same rounding-collision concern as reswing applies in principle
(distinct source ppqLs quantising to same row), but here the per-write
CSK gate catches it instead of trustGeometry letting it through.

#### `quantizeKeepRealisedScope` — vm:1165 ✓

Bounded by `delayRange` (vm:1175). Only writes `(ppq, ppqL, delay,
endppqL, frame)` — endppq stays put. delay clamping ensures realised
order = intent order; intent ppq lands on grid; CSK runs. ✓

#### `interpolate` — vm:777 ✓ vacuous

Only writes `shape`. Doesn't touch ppq/endppq/pitch. ✓

#### `deleteEvent` / `deleteSelection` — vm:1504 / 1523 ✓

`queueDeleteNotes` (vm:1435): for each deleted run, extends the
predecessor's `endppq` to the next survivor's `ppq` (or `length`).
Since the extension lands exactly at the next survivor's onset, the
extended interval and the next survivor are butt-joined: overlap = 0.
✓ noteColumnAccepts unchanged for the survivor; the extended
predecessor's window grew but it's checked against the same col-mates
(unchanged) so its persisted lane still accepts.

`queueResetVelocities`, `queueResetDelays`, `queueDeleteCCs` either
write non-allocating fields or delete events — no L2 impact.

#### `setMutedChannels` — tm:913 ✓

Writes only `muted`. CSK gate skipped (no pitch/ppq/endppq in
update). ✓

#### Take swap rebuild — ✓ vacuous

Foreign MIDI may not carry `note.lane` metadata. `allocateNoteColumn`
sees `note.lane == nil` and goes straight to first-fit. There's no
"prior lane" to preserve. ✓

#### Transient frame override (`matchGridToCursor`) — vm:341 ✓

Writes only config (swing/colSwing/rpb). No note data touched. tm
sees the same intent ppqs (swing acts at the vm boundary, not tm), so
noteColumnAccepts answers are unchanged. ✓

### Iteration order

`mm:notes()` iterates by location key, which is stable across edits
(REAPER doesn't reuse note locations within a take's lifetime). So
across two consecutive rebuilds:

- The set of notes processed is the same (modulo
  add/delete/reorderings the edit deliberately performed).
- For each note, the col.events seen at allocation time is the same
  prefix of allocated col-mates as before — assuming each prior note
  in iteration order made the same allocation decision, which holds
  by induction once we know each note individually keeps its lane.

So per-note inductive lane preservation lifts to set-wide preservation.

### Summary

| Path                                    | Holds L2? |
|-----------------------------------------|-----------|
| `editEvent` pitch / octave              | ✓ (CSK)   |
| `editEvent` vel / val / delay           | ✓         |
| `placeNewNote`                          | ✓         |
| `moveLaneEvent`                         | ✓ vacuous (notes excluded) |
| `nudge*`                                | ✓         |
| `adjustPosition[Multi]`                 | ✓ (overlapBounds, lenient=0) |
| `adjustDuration`                        | ✓ (overlapBounds, lenient matches threshold) |
| `noteOff`                               | ✓         |
| `insertRow` / `deleteRow`               | ✓ identity-swing; ⚠️ diff-pitch threshold-brushing under non-identity swing |
| `paste` (single, multi)                 | ✓ (region-clear + caps) |
| `duplicate`                             | ✓ (paste)  |
| `reswing*`                              | ⚠️ rounding past acceptance threshold (acknowledged fragility) |
| `quantize*`                             | ✓ same-pitch (CSK); ⚠️ diff-pitch threshold-brushing |
| `quantizeKeepRealised*`                 | ✓ same-pitch (CSK); ⚠️ diff-pitch threshold-brushing |
| `interpolate`                           | ✓ vacuous |
| `deleteEvent` / `deleteSelection`       | ✓ (butt-join extension) |
| `setMutedChannels`                      | ✓         |
| Take swap rebuild                       | ✓ vacuous (lane=nil) |
| Transient frame override                | ✓ (config-only) |
| `vm:hideExtraCol` (orphan bug)          | n/a — bug is "lane-shift silently dropped", not "lane drifts" |
