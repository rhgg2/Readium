---
status: ✅ HOLDS — pinned for global swing change; per-column case not directly pinned
---

# G3 — Swing change surfaces off-grid honestly  ✅ HOLDS

**Invariant**: Under a new global swing or per-column swing, events
whose intent ppq sat at the old swung grid surface as off-grid in the
new frame.

**Falsifying scenario**: under c58, seed events authored under
identity (frame.swing = nil); switch take swing to c58; assert events
at non-fixed-points show `gridCol.offGrid[y] = true`. (Already pinned
by `vm_grid_spec` "swing change: notes authored under swing-off…".)

---

## Verdict

G3 holds by construction. The on-grid bit is computed in
`vm:rebuild` (vm:2028) against the *current* frame's row map, and
the rebuild fires whenever `swing`/`colSwing` change in cm. Events
keep their old intent `evt.ppq`; the row map changes underneath
them; the comparison `ctx:rowToPPQ(y, chan) ~= evt.ppq` flips on
for events whose old intent doesn't agree with the new
`swing.fromLogical`.

Period-boundary fixed points (logical-ppq at integer multiples of
the swing period) survive the change on-grid because
`swing.fromLogical` is the identity at those points by construction
— pinned by `vm_grid_spec`'s c58 test (rows 0, 4 stay on-grid; rows
1, 2 surface off-grid).

### Rule to extract into docs

> **G3 holds because (a) the on-grid bit is recomputed against
> current frame on every rebuild, and (b) cm `swing`/`colSwing`
> writes trigger a rebuild via `configChanged → tm:rebuild →
> vm:rebuild`.** Events store intent `evt.ppq` (delay-stripped by
> tm); the row map is per-frame state in vm's `ctx`. Changing the
> frame doesn't touch any event field — it changes the function
> against which `evt.ppq` is compared, and previously-on-grid events
> at non-fixed-points flip to off-grid. Period-boundary events
> (logical-ppq at integer multiples of `swing.period`) stay on-grid
> because the swing function fixes those points.
>
> **Two distinct user actions, two distinct outcomes.** Picking a
> different swing *slot* (`vm:setSwingSlot` / `setColSwingSlot`)
> changes which slot is active without migrating events; the events
> surface off-grid (G3). Editing a slot's *contents*
> (`vm:setSwingComposite`) is followed by `vm:reswingPreset` in the
> editor, which migrates events to the new shape (G4). Neither path
> falls through to the other — they implement different intents.

---

## Detailed walk

### Mechanism — vm:2010–2030

```lua
-- Per docs/timing.md: displayRow(e) = round(ppqToRow_c(e.ppq))
-- under *current* swing. tm has stripped delay, so e.ppq is
-- intent. On-grid iff rowToPPQ_c reproduces e.ppq exactly — with
-- float rowPPQs the round-trip is bit-exact, so a swing change
-- correctly surfaces previously-on-grid events as off-grid.
for _, gridCol in ipairs(grid.cols) do
  ...
  for _, evt in ipairs(gridCol.events) do
    local startRow = ctx:ppqToRow(evt.ppq or 0, chan)
    local y        = util.round(startRow)
    if y >= 0 and y < numRows then
      ...
      if ctx:rowToPPQ(y, chan) ~= evt.ppq then gridCol.offGrid[y] = true end
    end
    ...
  end
end
```

`ctx` was built earlier in this same `vm:rebuild` call (vm:1996–2008)
with `swing = tm:swingSnapshot()`, i.e. *current* swing under both
global and per-column resolution. So the `rowToPPQ` here is the
new-frame map; `evt.ppq` is whatever tm-side `tidyCol` produced (the
old intent ppq, untouched by a swing-config change). The comparison
is exact-equal under floats because rowPPQs are stored as
`r * logPerRow` (no rounding seeded into the table); the
`swing.fromLogical` at `r * logPerRow` rounds to integer ppq, and
that's the value compared against `evt.ppq`. Match iff intent
agrees.

### Trigger paths

| User action                                   | Code path                                         | Triggers rebuild? | Migrates events? |
|-----------------------------------------------|---------------------------------------------------|-------------------|------------------|
| Pick global swing slot                        | `vm:setSwingSlot` → `cm:set('project','swing',…)` and `cm:set('track','swing',…)` (vm:520–530) | ✓ via `configChanged` (tm:945–947) | ✗ |
| Pick per-column swing slot                    | `vm:setColSwingSlot` → `cm:set('track','colSwing',map)` (vm:536–540) | ✓ via `configChanged` | ✗ |
| Edit slot composite                           | `vm:setSwingComposite` → `cm:set('project','swings',lib)` (vm:542–547) | ✓ via `configChanged` | not by this call alone — but renderManager.lua:1513–1514 calls `vm:reswingPreset(name)` immediately after, which migrates events for that slot |
| Edit a swing's atom params (live drag in editor) | renderManager.lua:1510–1514 — `setSwingComposite` then `reswingPreset` | ✓ + reswing | ✓ (G4 path) |

The split is deliberate: slot **selection** (G3) doesn't migrate;
slot **edit** (G4) does. A user who wants to migrate a slot
selection's events without changing the slot would call
`vm:reswingAll` explicitly.

### `tm:swingSnapshot` resolves slot names freshly each rebuild — tm:860–890

```lua
function tm:swingSnapshot(override)
  local global, column = nil, {}
  if mm then
    local gSrc, cSrc
    if override then gSrc, cSrc = override.swing, override.colSwing
    else             gSrc, cSrc = cm:get('swing'), cm:get('colSwing')
    end
    global = resolveSlot(gSrc)
    if cSrc then
      for chan, name in pairs(cSrc) do column[chan] = resolveSlot(name) end
    end
  end
  return { global = global, column = column,
    fromLogical = function(chan, ppqL) ... end,
    toLogical   = function(chan, ppqI) ... end,
  }
end
```

Snapshot is rebuilt on every `vm:rebuild` (via `tm:swingSnapshot()`
at vm:2000), so the row map always reflects current cm state. No
caching that could go stale across a swing config change. ✓

### `vmOnlyKeys` carve-out — tm:931, 945–947

```lua
local vmOnlyKeys = { mutedChannels = true, soloedChannels = true }
...
cm:subscribe('configChanged', function(change)
  if not vmOnlyKeys[change.key] then tm:rebuild(false) end
end)
```

`swing`, `colSwing`, `swings` (the slot library) are all not in
`vmOnlyKeys`, so they all trigger `tm:rebuild`. tm forwards
`'rebuild'` to vm (via tm's hook setup elsewhere), and vm rebuilds.
`tm:rebuild(false)` is the "non-take-swap" rebuild: events are
re-iterated from mm but no foreign MIDI is being absorbed. The
delay-strip in `tidyCol` runs again, idempotent — vm sees the same
intent ppqs.

### Test coverage

- `tests/specs/vm_grid_spec.lua` "swing change: notes authored under
  swing-off are off-grid under a non-trivial swing" — pins the
  global swing change case under c58. Covers period-boundary fixed
  points (rows 0, 4 stay on-grid) and non-fixed-points (rows 1, 2
  flip to off-grid). ✓
- **Not directly pinned**: per-column swing change. The mechanism
  is identical (cm write → configChanged → rebuild), but a regression
  test would pin the wiring explicitly. Suggested fixture: two
  channels, both seeded under identity; set `colSwing[1] = 'c58'`;
  assert chan-1 off-grid surfaces while chan-2 stays on-grid.
- **Not directly pinned**: swing slot library mutation
  (`cm:set('project', 'swings', …)`) without changing the active
  slot name. Edge case: slot `'c58'` is selected; user edits c58's
  composite via setSwingComposite; renderManager calls reswingPreset
  immediately, so events migrate. But if a future caller wrote to
  `swings` *without* the reswingPreset chaser, events would surface
  off-grid against the new c58 shape — desired G3 behaviour.

### Findings

1. **Per-column swing change has no dedicated test**, only the
   global case. The wiring is the same, but a regression guard
   would be cheap to add.
2. **No findings on the mechanism itself.** G3 is a passive
   property of "rebuild the grid against current cm state", and the
   trigger wiring is direct.

### Summary

| Aspect                                                         | Verdict |
|----------------------------------------------------------------|---------|
| On-grid bit recomputed against current frame on every rebuild  | ✓       |
| cm `swing` writes trigger rebuild                              | ✓       |
| cm `colSwing` writes trigger rebuild                           | ✓       |
| Period-boundary fixed points stay on-grid across swing change  | ✓ (pinned) |
| Non-fixed points surface off-grid                              | ✓ (pinned) |
| Per-column swing change pinned in tests                        | ✗ (suggest adding) |
| Slot-selection vs slot-edit policy split                       | ✓ (G3 vs G4 carve-out is deliberate) |
