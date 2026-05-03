---
status: ⚠️ HOLDS for stamped events; one carry-over sub-row exception; no direct off-grid-flag test
---

# G4 — Reswing recovers on-grid  ⚠️ HOLDS modulo conformOverlaps carry-over

**Invariant**: `reswingScope` re-realises events with stamped `ppqL +
frame` so they display on-grid in the new frame, with no off-grid
flag and no spurious row jump. Events outside scope (other channels
in `reswingSelection`, untouched events in `reswingPresetChange`)
byte-identical.

**Falsifying scenario**: author notes under nil-frame, switch swing,
run `reswingAll`; expect zero off-grid flags and `ppqL` unchanged.

---

## Verdict

G4 holds for the three core claims:

1. **Lands on-grid** — for events with `ppqL = sourceRow ×
   oldLogPerRow` (F1 stamping), `newppq = round(tgt.fromLogical(chan,
   ppqL))` equals `ctx:rowToPPQ(sourceRow, chan)` under the new
   frame, by the same arithmetic that defines the rowToPPQ check
   (vm:64–70 ≡ vm:1178). On-grid by F4. ✓
2. **No spurious row jump** — `displayRow_post = round(ppqToRow_new(newppq, chan)) ≈ ppqL / newLogPerRow`. Under same-rpb (the common case), `newLogPerRow = oldLogPerRow`, so displayRow = sourceRow. Monotone reparameterisation preserves order; sub-row rounding ≤ 0.5 ppq from `util.round` won't cross a row boundary unless the source row was right at the half. ✓
3. **Untouched events byte-identical** — `reswingScope` calls `reswingCore(eventsByCol(), …)`; only events in selected groups enter `plans`. `reswingAll` calls with `allGroups()`, but the `if e.frame and …` guard skips frameless events (left alone). `reswingPresetChange` filters via `opts.include = e.frame.swing == name or e.frame.colSwing == name`. Off-scope events stay out of plans, never get an `assignEvent` call. ✓

The one carry-over **exception** is the same `conformOverlaps`
sub-row drift documented in L2 and G1: when two events' independent
`fromLogical` rounds collapse onto the same ppq (or onto adjacent
ppqs past the lenient threshold), `conformOverlaps` shifts a planned
event's `newppq` by ±1 ppq. The shifted event lands sub-row off-grid
in the new frame. Acceptable trade for L2 — pinned indirectly by
`vm_reswing_lane_stability_spec`. Under G4 strict reading, that's a
violation; in practice it's the same conformance class with two
acceptable losses (1 ppq drift, lane preserved).

There's also a **cross-rpb restamp** concern that overlaps F1, not
G4 directly: under `reswingScope`'s restamp with rpb change, `ppqL`
is rescaled by `ratio = newLogPerRow / oldLogPerRow` (vm:1191), but
`newppq` is computed from the *old* `e.ppqL`. The post-write event
lands on-grid in the new frame (G4 ✓), but `ppqL/newLogPerRow ≠
displayRow_post`. F1 was audited ✅ separately; flagging here for
cross-reference because it can confuse future readers walking
through the cross-rpb math.

### Rule to extract into docs

> **Reswing recovers on-grid for stamped events only.** The
> recovery operator is `newppq = round(tgt.fromLogical(chan,
> e.ppqL))`. For events with `e.ppqL = sourceRow × oldLogPerRow`
> (the F1 stamping shape) and same-rpb target, this equals
> `ctx:rowToPPQ(sourceRow, chan)` in the target frame — on-grid.
>
> Events without `e.frame` are skipped (no authoring frame to
> invert). They retain whatever evt.ppq they had, surfacing on-grid
> or off-grid as G3 dictates. **Foreign MIDI never recovers via
> reswing — by design.**
>
> **`conformOverlaps` may push a planned event sub-row off-grid by
> ±1 ppq** in the rare collision case. Carry-over from the L2
> fragility class. Acceptable: the alternative is a same-onset
> rejection at the allocator.
>
> **Restamp with rpb change** (`reswingScope`'s default `restamp =
> currentFrame(chan)` when current rpb differs from the source's
> rpb): G4 still holds (event lands on-grid in current frame), but
> ppqL is rescaled to keep "same authoring row, new logPerRow"
> bookkeeping coherent for F1. The two pieces of arithmetic
> (`newppq` from old ppqL; `newPpqL` rescaled) lock the post-write
> state to the *event's intent time at restamp*, while the F1
> reading of ppqL keys to the *display row in new rpb*. They agree
> visually but diverge if you read ppqL as "row × logPerRow" with
> the new logPerRow.

---

## Detailed walk

### `reswingCore` — vm:1169–1259

```lua
local function reswingCore(groups, opts)
  local plans = {}
  local notePlansByChan = {}
  for _, g in ipairs(groups) do
    local col, chan = g.col, g.col.midiChan
    for _, e in pairs(g.locs) do
      if e.frame and (not opts.include or opts.include(e, chan)) then
        local tgt   = opts.target(e.frame, chan)
        local entry = { col = col, e = e,
          newppq = math.min(length, util.round(tgt.fromLogical(chan, e.ppqL))) }
        if util.isNote(e) then
          entry.newEndppq = math.min(length, util.round(tgt.fromLogical(chan, e.endppqL)))
          ...
        end
        if opts.restamp then
          entry.newFrame = opts.restamp(chan)
          local ratio = logPerRowFor(entry.newFrame.rpb) / logPerRowFor(e.frame.rpb)
          if ratio ~= 1 then
            entry.newPpqL    = e.ppqL    * ratio
            if util.isNote(e) then entry.newEndppqL = e.endppqL * ratio end
          end
        end
        util.add(plans, entry)
      end
    end
  end
  ...
```

#### Frame guard — `if e.frame and …`

The guard's two arms:

- `e.frame` — events without authoring frame are silently skipped.
  Foreign MIDI (no ppqL/frame) and any pre-stamping legacy data
  qualify. Their evt.ppq is left untouched; G4's "ppqL unchanged"
  holds vacuously (ppqL is nil), and on-grid status is whatever G3
  produced.
- `opts.include` — for `reswingPresetChange`, restricts to events
  matching the changed slot name. Selective migration.

Test pin: `vm_reswing_cc_spec` "CC without a frame is skipped by
reswing" pins the foreign-event branch.

#### Lands on-grid — `newppq = round(tgt.fromLogical(chan, e.ppqL))`

For an event with `e.ppqL = sourceRow × oldLogPerRow`:

- **Same-rpb target**: target's logPerRow = oldLogPerRow.
  `tgt.fromLogical(chan, sourceRow × oldLogPerRow)` is exactly the
  expression `ctx:rowToPPQ(sourceRow, chan)` evaluates internally
  (vm:64–70). So `newppq == ctx:rowToPPQ_target(sourceRow, chan)` → on-grid in target frame. ✓
- **Cross-rpb target**: target's logPerRow = newLogPerRow ≠
  oldLogPerRow. `newppq = round(tgt.fromLogical(chan, sourceRow ×
  oldLogPerRow))`. In the target frame, the displayRow of newppq is
  `round(ppqToRow_target(newppq, chan)) = round(swing.toLogical(chan, newppq) / newLogPerRow) ≈ round(sourceRow × oldLogPerRow / newLogPerRow) = round(sourceRow × ratio_inv)`. Then `ctx:rowToPPQ_target(displayRow, chan) = round(swing.fromLogical(chan, displayRow × newLogPerRow)) ≈ round(swing.fromLogical(chan, sourceRow × oldLogPerRow)) = newppq`. ✓ on-grid.

Pin: `vm_reswing_cc_spec` "CC authored under c58 reswings to
identity using its ppqL" — seed with `ppqL = 120`, c58 frame, take
swing nil; expect post-reswing realised `ppq == 120` (identity
target). ✓

#### No spurious row jump

Same algebra as on-grid: `displayRow_post ≈ ppqL / newLogPerRow`.
Under same-rpb, that's `sourceRow` exactly. Under cross-rpb, that's
`sourceRow × ratio_inv` (rounded) — the row index changes because
the row width changes, but it's the *same time*. Not "spurious" — a
denser grid means a higher row index for the same event.

#### Untouched events byte-identical

- `reswingSelection` → `reswingScope(eventsByCol())` — eventsByCol()
  returns only selected events. Other channels' events not in
  groups → not in plans → no assignEvent fires. ✓
- `reswingAll` → `reswingScope(allGroups())` — all events in
  groups, but `if e.frame` filter excludes frameless. Frameless
  events stay byte-identical. ✓
- `reswingPresetChange` → filter via `opts.include`. Only events
  with `frame.swing == name` or `frame.colSwing == name` enter
  plans. Other-slot events stay byte-identical. ✓

#### ppqL claim ("ppqL unchanged")

The G4 falsifying scenario asserts `ppqL unchanged` post-reswing. The
code:

- **Same-rpb**: `entry.newPpqL` is not set (line 1190 `if ratio ~= 1
  then …`). The plan's `assignEvent` doesn't pass `ppqL` →
  unchanged. ✓
- **Cross-rpb**: `entry.newPpqL = e.ppqL * ratio`. ppqL **is
  rescaled**. Strictly violates "ppqL unchanged". The intent is F1
  coherence ("same authoring row, new logPerRow"). Acknowledged
  cross-reference to F1, not a G4 finding per se.

### conformOverlaps interaction — vm:1230–1234, 241–302 ⚠️

```lua
-- Pass 2: conform overlaps that monotone-but-rounded
-- swing.fromLogical may have nudged past noteColumnAccepts'
-- threshold (or onto the same ppq).
conformOverlaps(plans)
```

When two col-mate notes' independent `fromLogical` rounds land at
identical ppq or within `lenient` of each other, `conformOverlaps`
shifts one of them by ±1 ppq (same-onset case) or by `excess` ppq
(tail-overlap lift). The shifted event's new `newppq` is no longer
`round(tgt.fromLogical(chan, ppqL))` — it's that value ± a small
correction. So:

- displayRow stays at sourceRow (sub-row drift won't cross half-row).
- `ctx:rowToPPQ(displayRow, chan) ≠ newppq` (the +1 ppq shift
  breaks the equality). Off-grid flag fires.

This is the same finding logged in G1's "Cross-cutting" row and
L2's "rounding-induced overlap drift" verdict. The sub-row drift is
the cost of preserving lane allocation; G4 strict reading is
violated in this corner; no fix planned.

### Delay clamp — vm:1208–1228

The "Pass 1.5" delay clamp writes `entry.newDelay` to enforce
realised-order under post-reswing geometry. `newDelay` only affects
mm via `realiseNoteUpdate` (tm:460–468) — vm-side `evt.ppq` (intent)
is what the on-grid bit reads. So the clamp doesn't touch on-grid.
✓

### Cross-rpb restamp internal consistency (cross-reference, not a G4 finding)

Under restamp with rpb change, the post-write event has:
- `evt.ppq = round(tgt.fromLogical(chan, oldPpqL))` — realised
  intent of *old* ppqL value
- `evt.ppqL = oldPpqL × ratio = sourceRow × newLogPerRow` — rescaled
  to current rpb's units

Reading the ppqL as "row × logPerRow" with the new logPerRow says
"this event is at row sourceRow", but the displayRow under the new
frame is `sourceRow × ratio_inv` (= sourceRow × (oldLogPerRow /
newLogPerRow)). These agree only when `ratio = 1`.

This is by design — F1 audit ✅ pinned this as the canonical
restamp behaviour. Documenting here so future cross-rpb walkers
don't re-discover the asymmetry. G4's on-grid claim is unaffected
because the on-grid bit doesn't read ppqL.

### Test coverage

| Assertion                                       | Pinned by                                                                         |
|-------------------------------------------------|-----------------------------------------------------------------------------------|
| Reswung event lands at correct `evt.ppq`        | `vm_reswing_cc_spec` "CC authored under c58 reswings to identity using its ppqL"; `vm_logical_ppq_spec` reswing-restamp tests |
| Frameless events skipped                        | `vm_reswing_cc_spec` "CC without a frame is skipped by reswing"                   |
| Frame restamps to current                       | `vm_reswing_cc_spec` "reswing restamps cc.frame to the current frame"             |
| Lane preserved (L2)                             | `vm_reswing_lane_stability_spec`                                                  |
| **Off-grid flag absent post-reswing**           | ✗ — not directly asserted. Implied by ppq equality + on-grid math, but a regression guard would pin "after `reswingAll`, no col has any `offGrid[y] = true` for migrated events". |
| **`ppqL` unchanged under same-rpb reswing**     | ✗ — implied by absence of `newPpqL` in the plan, but no test asserts             |

Two test gaps worth filling cheaply:

1. **`gridCol.offGrid` empty after `reswingAll`**: seed off-grid
   events (e.g. nil-frame under c58 setup), reswingAll, assert all
   `gridCol.offGrid[y] == nil` for each migrated event's display
   row.
2. **Same-rpb reswing leaves `ppqL` byte-identical**: seed a c58
   event, reswingAll into c67, assert `evt.ppqL` unchanged but
   `evt.ppq` updated to the new realised position.

### Summary

| Aspect                                                              | Verdict |
|---------------------------------------------------------------------|---------|
| Stamped event's `newppq` lands on-grid in target frame              | ✓       |
| No spurious row jump (same-rpb)                                     | ✓       |
| No spurious row jump (cross-rpb — row index scales with rpb, by design) | ✓       |
| Untouched events byte-identical (selection / preset / frameless)    | ✓       |
| `ppqL` unchanged under same-rpb                                     | ✓       |
| `ppqL` rescaled under cross-rpb restamp                             | ⚠️ deliberate F1-coherence rescale; flagged as cross-reference |
| `conformOverlaps` ±1 ppq sub-row shift under collision              | ⚠️ acknowledged carry-over from L2 / G1 |
| Direct off-grid-flag-empty test post-reswing                        | ✗ test gap |
