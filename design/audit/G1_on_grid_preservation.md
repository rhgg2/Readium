---
status: ⚠️ HOLDS for ppq, modulo three acknowledged sub-row exceptions
---

# G1 — On-grid preservation across edits  ⚠️ HOLDS UP TO ACKNOWLEDGED EXCEPTIONS

**Invariant**: For any edit, every event whose intent ppq the edit
didn't deliberately move keeps its on-grid status; and every event the
edit did deliberately move lands on-grid in the post-edit frame.

**Falsifying scenario**: under c58 swing, seed several on-grid events,
insert a row above the lowest, assert all post-edit events remain
on-grid in the current frame. (Same for delete.)

---

## Verdict

G1 holds for the **edited-event-lands-on-grid** half wherever the
target row is constructible as an integer; it holds for the
**untouched-events-byte-identical** half wherever "byte-identical" is
read as the only thing the on-grid bit actually depends on:
**`evt.ppq`**.

Three acknowledged exceptions to "lands on-grid":

| Path                                            | What                                                       |
|-------------------------------------------------|------------------------------------------------------------|
| `vm:moveLaneEvent` collision +1 ppq nudge       | Sub-row off-grid by deliberate +1 ppq anti-collision shift |
| `vm:moveLaneEvent` fractional toRow drag        | Off-grid by design (drag preview before snap)              |
| `conformOverlaps` same-onset / tail-overlap fix | Sub-row off-grid by ±1 ppq or ±excess ppq                  |

And one acknowledged exception to "untouched events byte-identical":

| Behaviour            | Notes                                              |
|----------------------|----------------------------------------------------|
| CSK-truncated tails  | Same-pitch siblings can have endppq trimmed. ppq unchanged → on-grid bit unaffected. |
| Survivor extension   | `queueDeleteNotes` and paste's truncate-last write `endppq` on a survivor. ppq unchanged. |

The strict reading of "byte-identical" never held in this codebase —
many editing paths legitimately rewrite `endppq` / `vel` / `frame` on
sibling events to maintain V1 / F1. **The bit G1 actually pins is
on-grid status, which depends only on `evt.ppq` and the current
frame's row map.** Frame fields, ppqL fields, and endppq are all
free to change without affecting it (vm:2028).

The third bullet (`conformOverlaps`) is the same fragility class
already documented in L2's verdict: rounded swing/grid arithmetic can
collapse two events onto adjacent or identical ppqs, and the helper
restores ordering with a sub-row shift. The shift takes the planned
event off-grid by ≤ 1 ppq in the rare collision case. Acceptable
trade — the alternative is a same-onset rejection at the allocator.

There is also one **inconsistency, not a violation**:

- `adjustPosition` (single) calls `snapRow(note.ppq) + rowDelta`,
  normalising off-grid sources to grid before shifting.
  `adjustPositionMulti` calls `ppqToRow(n.ppq) + rowDelta`,
  preserving the source's logical offset across the move. Either
  policy is defensible (one normalises, the other "carries the
  selection together"). The divergence is undocumented.

### Rule to extract into docs

> **The on-grid bit is a function of `evt.ppq` and the current
> frame's row map only.** ppqL, endppq, frame, and other fields don't
> enter `gridCol.offGrid[y] = true` (vm:2028). So:
>
> - To **preserve** an event's on-grid status across an edit, leave
>   `evt.ppq` alone. Any other field can change.
> - To **land** an event on-grid in the post-edit frame, write
>   `evt.ppq = ctx:rowToPPQ(integerRow, chan)`. Equivalent constructions:
>   `round(swing.fromLogical(chan, integerRow * logPerRow))`. The row
>   must be integer — F4 part 1 guarantees the round-trip
>   `snapRow(rowToPPQ(r, c), c) == r` only for integer `r`.
>
> **Off-grid sources preserve their offset under swing-respecting
> moves** (insertRow / deleteRow / reswing). The shift is in logical
> space (`newppqL = e.ppqL + dLogical` or scaled by ratio under
> restamp), and the source's off-grid offset rides along. This is
> consistent with G4's "from stamped ppqL+frame" carve-out: reswing
> recovers on-grid only for events whose ppqL was a clean integer
> multiple of `logPerRow_authoredFrame`.
>
> **`conformOverlaps` may push planned events sub-row off-grid
> (≤ 1 ppq)** to break a same-onset collision. Rare — fires only when
> two col-mates' independent `swing.fromLogical` rounds collapse onto
> the same ppq, or two ppqs end up exactly `lenient` apart. Pinning
> tests should assert L2 holds (lane preserved); G1 sub-row drift is
> the cost of that.

---

## Detailed walk

### What "on-grid" actually checks

```lua
-- vm:2015–2028 (rebuild)
for _, gridCol in ipairs(grid.cols) do
  ...
  for _, evt in ipairs(gridCol.events) do
    local startRow = ctx:ppqToRow(evt.ppq or 0, chan)
    local y        = util.round(startRow)
    if y >= 0 and y < numRows then
      if gridCol.cells[y] then
        gridCol.overflow[y] = true
      else
        gridCol.cells[y] = evt
        if ctx:rowToPPQ(y, chan) ~= evt.ppq then gridCol.offGrid[y] = true end
      end
    end
    ...
  end
end
```

Two reads on `evt`: `evt.ppq` and (implicitly via `endppq`) `evt.endppq`
for tails. Only `evt.ppq` enters the off-grid flag. So:

- `displayRow(e) = round(ppqToRow(evt.ppq, chan))`
- `onGrid(e) ⇔ rowToPPQ(displayRow(e), chan) == evt.ppq`

By F4 part 1 (audited ✅), for any integer `r ∈ [0, numRows)`:
`snapRow(rowToPPQ(r, c), c) == r` exactly. So if a writer sets
`evt.ppq = rowToPPQ(integerRow, chan)`, then displayRow rounds back to
`integerRow` and the rowToPPQ check is exact-equal → on-grid. This is
the canonical landing pattern.

### Non-row-moving edits — `evt.ppq` untouched on the edited event

| Site                                                 | Writes                                       | ppq on edited evt?    |
|------------------------------------------------------|----------------------------------------------|------------------------|
| `editEvent` stop 5–7 (delay) — vm:778–797            | `{ delay }`                                  | unchanged (tm strips delay → vm-side `evt.ppq` is intent, untouched) ✓ |
| `editEvent` stop 0/3/4 vel hex on note — vm:811–814  | `{ vel }`                                    | unchanged ✓                                                              |
| `editEvent` stop 0–4 val/shape on cc/at/pc/pb (existing, on-grid source) — vm:852–853 | `snap({ val })` no-op when `evt.ppq == cursorppq` | unchanged ✓        |
| `editEvent` stop 1/2 pitch/octave on note (on-grid source) — vm:740, 774 | `{ pitch, detune }` (no snap fires) | unchanged ✓                       |
| `nudgeDelay` — vm:1525–1530                          | `{ delay }`                                  | unchanged ✓                                                              |
| `nudgeVel` — vm:1520–1523                            | `{ vel }`                                    | unchanged ✓                                                              |
| `nudgeValue` — vm:1532–1536                          | `{ val }`                                    | unchanged ✓                                                              |
| `nudgePitch` — vm:1506–1518                          | `{ pitch, detune }`                          | unchanged ✓                                                              |
| `queueResetDelays` — vm:1636–1642                    | `{ delay = 0 }`                              | (covered by F2 / L1: tm-side stripping leaves vm-side ppq invariant) ✓   |
| `queueResetVelocities` — vm:1646–1659                | `{ vel = ... }`                              | unchanged ✓                                                              |
| `interpolate` (cycleShape) — vm:916–919              | `{ shape }`                                  | unchanged ✓                                                              |

In every case the edited event's `evt.ppq` is left alone, so
on-grid status is preserved.

#### Side effects on untouched events

Two routes can rewrite *other* events' fields:

- **CSK** (tm:421–437) on a pitch-changing edit: deletes or
  truncates `endppq` of same-pitch siblings. Never writes `ppq`. ✓
- **`assignTail` predecessor truncation** in `placeNewNote` (vm:676)
  and pastes (ec:676, ec:819): writes `endppq`/`endppqL`/`frame` on
  the predecessor. Never writes `ppq`. ✓

Both leave on-grid bits on those siblings intact.

#### Off-grid source on a value-write or pitch edit

When `editEvent` is called and `evt.ppq ~= cursorppq`, `snap` fires
and rewrites `evt.ppq = cursorppq` (vm:716–726). `cursorppq =
ctx:rowToPPQ(ec:row(), chan)` with `ec:row()` integer → on-grid in
current frame by F4. So an off-grid source becomes on-grid post-edit.
**This is row-moving** (the off-grid → on-grid snap), and it satisfies
the row-moving half of G1.

### Row-moving edits — `evt.ppq` rewritten via `rowToPPQ(integerRow, …)`

| Site                                  | New `ppq`                                                         | Row integer? | Lands on-grid?                                                      |
|---------------------------------------|-------------------------------------------------------------------|--------------|---------------------------------------------------------------------|
| `editEvent` snap (off-grid source) — vm:716 | `cursorppq = ctx:rowToPPQ(ec:row(), chan)`                  | ✓            | ✓                                                                   |
| `placeNewNote` — vm:761/672           | passed in `cursorppq`                                             | ✓            | ✓ (head); `last.endppq` truncated, ppq unchanged (✓)                |
| `moveLaneEvent` integer toRow — vm:881 | `ctx:rowToPPQ(integerToRow, chan)`                                | ✓            | ✓                                                                   |
| `moveLaneEvent` fractional toRow — vm:881 | `ctx:rowToPPQ(fractionalToRow, chan)`                          | ✗            | ⚠️ deliberately off-grid (drag preview)                              |
| `moveLaneEvent` collision lift — vm:884/888 | `prev.ppq + 1` or `next.ppq - 1`                              | ✗            | ⚠️ sub-row off-grid (anti-collision)                                 |
| `adjustPosition` (single) — vm:1141   | `assignStamp(rowS = snapRow(note.ppq) + rowDelta, …)`             | ✓            | ✓ (snapRow normalises off-grid sources to grid first)                |
| `adjustPositionMulti` — vm:1100       | `assignStamp(rowS = ppqToRow(n.ppq) + rowDelta, …)`               | ✓ for on-grid sources; ✗ for off-grid | ✓ for on-grid sources; ⚠️ off-grid sources preserve offset |
| `adjustDuration` — vm:1036–1048       | only `endppq` rewritten                                           | n/a          | ✓ (head's `evt.ppq` unchanged)                                      |
| `noteOff` — vm:995–1030               | only `endppq`                                                     | n/a          | ✓                                                                   |
| `insertRowCore` / `deleteRowCore` — vm:1406, 1434 | `round(swing.fromLogical(chan, e.ppqL + dLogical))`   | ✓ for on-grid sources (ppqL is integer × logPerRow + integer × logPerRow) | ✓ for on-grid sources; ⚠️ off-grid sources preserve offset |
| `quantizeScope` — vm:1294             | `ctx:rowToPPQ(util.round(ppqToRow(e.ppq)), chan)`                 | ✓            | ✓                                                                   |
| `quantizeKeepRealisedScope` — vm:1330 | `ctx:rowToPPQ(snapRow(e.ppq), chan)`                              | ✓            | ✓ (head); `endppq` stays as intent (✓)                               |
| `reswingScope` / `reswingPresetChange` — vm:1169–1259 | `round(tgt.fromLogical(chan, e.ppqL))`                  | implied integer for on-grid sources | ✓ for on-grid sources; ⚠️ off-grid sources preserve offset |
| `pasteSingle` — ec:627–727            | `ctx:rowToPPQ(r + ce.row, chan)` (r, ce.row integer)              | ✓            | ✓                                                                   |
| `pasteMulti` — ec:729–868             | `ctx:rowToPPQ(cRow + ce.row, chan)`                               | ✓            | ✓                                                                   |
| `duplicate` — vm:1711                 | (re-uses `pasteClip`)                                             | ✓            | ✓                                                                   |
| `deleteEvent` / `deleteSelection`     | no ppq writes; survivor extension only writes `endppq`            | n/a          | ✓                                                                   |
| `conformOverlaps` — vm:241–302        | sub-row corrections to planned `newppq` / `newEndppq`             | usually ✗    | ⚠️ ≤ 1 ppq off-grid in the collision case                            |

#### Per-path notes worth surfacing

##### `insertRowCore` / `deleteRowCore` — vm:1406, 1434 ✓ (the G1 motivating fix)

`shiftPlan` (vm:1392–1404):

```lua
local newppqL = logicalOf(e) + dLogical
local entry   = { col = col, e = e, newFrame = f,
  newppq = util.round(swing.fromLogical(chan, newppqL)),
  newPpqL = newppqL,
}
```

`dLogical = numRows * logPerRow`, with `logPerRow` from
`frameAndLogPerRow(chan)` (current frame) — so `dLogical` is an
integer multiple of `logPerRow`. For an on-grid source,
`logicalOf(e) = e.ppqL` is also an integer multiple of `logPerRow`
(F1), so `newppqL = (i + numRows) * logPerRow`.

Then `newppq = round(swing.fromLogical(chan, (i + numRows) * logPerRow))`.
This is exactly what `ctx:rowToPPQ(i + numRows, chan)` returns
(vm:64–70). So `newppq == ctx:rowToPPQ(displayRow, chan)` where
displayRow = i + numRows → on-grid. ✓

This is the "G1 fix" the source doc names: under the previous
flat-`+dppq` formulation, on-grid sources at heterogeneous source
rows landed off-grid in the new frame because `swing.fromLogical` is
non-linear in row. The current per-event re-realisation via
`swing.fromLogical(chan, newppqL)` fixes this. Pinned by `vm_grid_spec`'s
"swing change" tests for the on-grid invariant under c58.

##### `reswingScope` / `reswingPresetChange` — vm:1169–1259 ✓ (with cross-rpb subtlety)

Same pattern: `newppq = round(tgt.fromLogical(chan, e.ppqL))`. For
on-grid sources (ppqL = sourceRow × oldLogPerRow), this rounds to
`ctx:rowToPPQ(sourceRow, chan)` under (newSwing, oldRpb). Under the
common case (rpb unchanged), the new frame *is* (newSwing, oldRpb)
and on-grid holds in current frame.

Under restamp **with rpb change** (vm:1185–1194), ppqL is rescaled
by `ratio = newLogPerRow / oldLogPerRow`. The post-write event has:

- `evt.ppq = round(tgt.fromLogical(chan, oldPpqL))`
- `evt.ppqL = oldPpqL * ratio`

These represent different logical positions — `evt.ppq` is the
realised image of the *old* ppqL value, while `evt.ppqL` is rescaled
to the *new* logPerRow's units. Looking like a (ppqL, frame)
inconsistency, but **the on-grid check still holds**: it asks whether
`ctx:rowToPPQ(displayRow, chan) == evt.ppq` in current frame, and
- `displayRow = round(ppqToRow(evt.ppq, chan)) ≈ swing.toLogical(chan, evt.ppq) / newLogPerRow ≈ oldPpqL / newLogPerRow`
- `ctx:rowToPPQ(displayRow, chan) = round(swing.fromLogical(chan, displayRow * newLogPerRow)) ≈ round(swing.fromLogical(chan, oldPpqL))` = `evt.ppq`. ✓

So G1 holds even though F1 (which this audit doesn't second-guess —
F1 was already audited ✅) is satisfied via a different mechanism
(ppqL rescale, not row-anchoring). The on-grid bit, depending only
on `evt.ppq` + current row map, doesn't see the inconsistency.

##### `quantizeScope` — vm:1294 ✓

```lua
local sRow   = ctx:ppqToRow(e.ppq, chan)
local newRow = util.round(sRow)
local newppq = ctx:rowToPPQ(newRow, chan)
```

`newRow` integer; `newppq = ctx:rowToPPQ(newRow, chan)` → on-grid by
F4. ✓

##### `quantizeKeepRealisedScope` — vm:1330 ✓

```lua
local newRow = ctx:snapRow(e.ppq, chan)
local newppq = ctx:rowToPPQ(newRow, chan)
```

`newRow` integer (snapRow rounds); `newppq` on-grid. The endppq
stays (intent), and the head moves to the grid; delay absorbs the
realised offset. The head is on-grid; the tail is endppq, which
doesn't enter the on-grid bit. ✓

##### `adjustPositionMulti` divergence from `adjustPosition` ⚠️

- `adjustPosition` (vm:1127–1128):
  `newStart = ctx:snapRow(note.ppq, chan) + rowDelta` →
  rounds an off-grid source to its display row before shifting.
  Post-edit row is integer regardless of source.
- `adjustPositionMulti` (vm:1098–1099):
  `rowS = ctx:ppqToRow(n.ppq, chan) + rowDelta` →
  uses the fractional row of an off-grid source, preserving the
  logical offset across the move. Post-edit row is integer iff
  source was on-grid.

For on-grid sources both paths land on-grid. For off-grid sources,
single normalises and multi preserves. Behavioural divergence.
**Not a strict G1 violation** — both behaviours are defensible, and
the multi semantics matches the intuition of "translate the
selection together". Worth a doc line so future ports don't unify
the helpers without thought.

##### `moveLaneEvent` (cc/pb/at) ⚠️

```lua
local newppq = ctx:rowToPPQ(toRow, chan)
local newRow = toRow
if prev and newppq <= prev.ppq then
  newppq = prev.ppq + 1
  newRow = ctx:ppqToRow(newppq, chan)
end
if next and newppq >= next.ppq then
  newppq = next.ppq - 1
  newRow = ctx:ppqToRow(newppq, chan)
end
```

Three cases for the resulting `newppq`:

1. `toRow` integer, no neighbour collision → on-grid by F4. ✓
2. `toRow` fractional (drag preview) → off-grid by design. ⚠️
3. Neighbour collision → `prev.ppq + 1` or `next.ppq - 1` → sub-row
   off-grid by 1 ppq. ⚠️

(2) is documented by the comment at vm:868–870 ("either an integer
or a fractional row"). (3) is rare and serves L2 (avoiding
same-onset collision in the dst column). Both are sub-row drift, so
the displayed row is unaffected — only the off-grid flag flips on.

##### `conformOverlaps` — vm:241–302 ⚠️ (the cross-cutting case)

Two arms touch `newppq`:

1. **Same-onset shift** (vm:268–282): when two timeline entries land
   at identical ppq, `curr.plan.newppq = curr.ppq + 1` (or
   `prev.plan.newppq = prev.ppq - 1`). The ±1 ppq shift takes the
   planned event sub-row off-grid.

2. **Tail-overlap clip** (vm:283–299): when the predecessor isn't
   planned, the successor's onset is lifted by `excess`:
   `lifted = math.min(curr.endppq - 1, curr.ppq + excess)`.
   `excess` is the overlap amount past threshold — generally
   non-row-aligned. Sub-row off-grid.

So whenever conformOverlaps fires, planned events can land sub-row
off-grid. This is the L2 fragility class viewed through the G1 lens:
the helper trades on-grid status (small drift) for lane stability
(no allocator failure). The four callers (`reswingCore`,
`quantizeScope`, `quantizeKeepRealisedScope`, `insertRowCore` /
`deleteRowCore`) each pass plans where the post-write events would
otherwise have landed on-grid; conformOverlaps' drift only fires in
the rare collision case.

Because the drift is sub-row, displayRow is unaffected, so the
event still appears at its expected row — only the off-grid flag
turns on for the affected pair. Acknowledged.

### Cross-cutting: take swap, mute, transient frame

- `tm:rebuild` after take swap: re-iterates `mm:notes()` with new
  events. on-grid bit recomputed from the new `evt.ppq` against
  current frame's row map. Foreign MIDI doesn't preserve `ppqL`/`frame`
  metadata; events appear on-grid iff their ppq sits at integer
  `rowToPPQ`. This is correct for foreign MIDI (it has no authoring
  metadata to honour).
- `tm:setMutedChannels`: routes through cm channel-mask state;
  doesn't touch any event field. ✓
- Transient frame override (Ctrl-G `matchGridToCursor`, vm:485): rebuilds
  with a different rpb in the row map but no event writes. on-grid
  bit recomputed against the override frame's row map; events
  authored in the source frame may surface off-grid in the
  transient — *as they should* (G3 honesty under frame change). ✓

### Summary

G1 holds for `evt.ppq` preservation everywhere it strictly applies.
The three sub-row exceptions (`moveLaneEvent` collision lift +
fractional drag, `conformOverlaps` collision shift) are deliberate
trade-offs against worse failure modes (same-onset collision, drag
flicker). The off-grid-source preservation under
`adjustPositionMulti` / `insertRowCore` / `deleteRowCore` /
`reswingCore` is consistent with G4's "from stamped ppqL+frame"
carve-out — events without clean authoring metadata don't recover
on-grid through these moves, by design.

The cross-cutting `conformOverlaps` finding is the same fragility
class L2 documents: rounded `swing.fromLogical` + adjacent col-mates
forces the helper to nudge a planned event ±1 ppq off-grid. Pinned
indirectly by L2's lane-stability tests; a dedicated G1 spec
would assert "post-quantize planned event at integer source row
lands at `rowToPPQ(round(sourceRow), chan)`" — useful but not
load-bearing.
