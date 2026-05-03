# editCursor refactor — overall plan

Resolved open calls: **kind** (not band), for continuity with `noteKind`/`applyNudge`; split to own file at Stage 5; expose `ec` to renderManager.

**Status as of 2026-04-24:** Stages 1, 2, 3, 4 landed in order; Stage 3.5 landed after 4 as a retrofit (placed between 3 and 4 below for logical reading order, not calendar order). Suite green at 123. Next: Stage 5 (file split). Authoritative status is in `project_viewmanager_refactor.md`.

## Goal

Untangle viewManager by extracting a `newEditCursor` factory that owns cursor, selection, and their encoding — exposing a semantic interface (`ec:kind()`, `ec:region()`, `ec:eventsByCol()`) in place of raw `cursorRow/cursorCol/sel/selGrp` primitives scattered across 190+ call sites. Length reduction is secondary; the primary win is collapsing the `if sel then … else cursor …` duality and killing grid-encoding magic numbers.

## What ec owns

**State** (private): `cursorRow`, `cursorCol`, `cursorStop`, `sel`, `selAnchor`, `hBlockScope`, `vBlockScope`.

**Constants** (private): `STOPS`, `SELGROUPS` — these encode *ec's* kind layout, not grid structure.

**Not owned**: `scrollRow/scrollCol` (viewport), `gridHeight/gridWidth/lastVisibleFrom` (rendering), event enumeration and mutation (caller runs these on `eventsByCol` output), config like `rowPerBeat`/`advanceBy` (vm).

## API

```lua
-- POSITION
ec:row(), ec:col(), ec:stop()
ec:setPos(row, col, stop)
ec:moveRow(n, selecting)              -- was scrollRowBy
ec:moveStop(n, selecting)             -- was scrollStopBy
ec:moveCol(n)                         -- was scrollColBy
ec:moveChannel(n)                     -- was scrollChannelBy
ec:clamp()                            -- cursor bounds only
ec:afterMove(fn)                      -- vm installs viewport-follow here

-- REGION (always defined; degenerates to 1×1 at cursor)
ec:hasSelection(), ec:isSticky()
ec:region()                           -- { r1, r2, c1, c2 }
ec:cols(), ec:chans()
ec:ppqSpan(col)                       -- was selBoundsFor
ec:eventsByCol()                      -- was selectedEvents; {col, locs, kind}[]

-- KIND (semantic — replaces raw selGrp ints)
-- 'pitch' | 'vel' | 'delay' (single note col) | 'val' (single scalar col) | 'mixed'
ec:kind()
ec:cursorKind()
ec:firstStopForKind(col, kind)        -- was firstStopForSelGrp

-- GROWTH
ec:start(), ec:update(), ec:clear()
ec:cycleHBlock(), ec:cycleVBlock(), ec:swapEnds()
ec:selectChannel(chan), ec:selectColumn(col)
ec:unstick()

-- LIFECYCLE
ec:reset()                            -- called on take change
ec:rescaleRow(oldRpb, newRpb)         -- setRowPerBeat / matchGridToCursor
ec:shiftSelection(rowDelta)           -- adjustPositionMulti

-- RENDERING HELPERS
ec:selectionKindSpan(col)             -- (stopStart, stopEnd) for sel rect in col
```

`ec:kind()` unifies with `applyNudge`'s existing `kind` parameter (`'pitch'/'vel'/'delay'/'val'`). The `noteKind = {[2]='vel', [3]='delay', vel='vel', ...}` mixed-int-string table goes away — callers read `ec:kind()` directly.

## Asymmetric-defaults carveout

These commands don't unify via `ec:region()` because the no-sel case has a genuinely different default scope:

- `forEachRowOp`: no-sel → **all cols**; sel → sel cols.
- `adjustDuration`/`adjustPosition`: no-sel → `cursorNoteBefore` (at-or-before cursor row); sel → multi-note logic.
- `nudge`: no-sel → `cursorRowEvent(col)`; sel → iterate groups.

These stay branched on `ec:hasSelection()`. Pinning this as an invariant in Stage 1 is important.

## Staged plan

### Stage 1 — pin invariants

Add regression specs before moving any code:

1. `selBounds` degenerate case returns `(row, row, col, col, kind, kind)`.
2. `delete` on delay-stop cursor ≡ `deleteSel` on 1-row delay selection (delay zeroed).
3. `delete` on vel-stop cursor ≡ `deleteSel` on 1-row vel selection (vel reset to carry-forward).
4. `copy` current behaviour with no selection — **verify first**, then pin whatever it does.
5. `forEachRowOp` asymmetry: cursor-only `insertRow` → row added to every col; single-cell sel → row only in sel col.
6. `duplicate` lands cursor on correct stop across kind widths (uses `firstStopForKind`).
7. `adjustPosition`/`nudge`/`noteOff` solo-cursor paths (currently uncovered) — minimal specs.

Run green. Stage 1 output: a tested floor.

### Stage 2 — introduce ec in viewManager.lua (same file)

Move into a new `newEditCursor` factory section at the top of vm's body:

- All state + `STOPS`/`SELGROUPS`.
- `selStart/Update/Clear`, `cycleBlock/VBlock`, `swapBlockEnds`, `selectSpan`.
- `selGrpAt`/`cursorSelGrp`/`firstStopForSelGrp` → renamed to kind API.
- `scrollRowBy/StopBy/ColBy/ChannelBy` → `moveRow/Stop/Col/Channel`.
- Split `clampCursor`: ec owns cursor-bounds clamp; vm keeps `followViewport` for scrollRow/Col and installs it via `ec:afterMove(followViewport)`.

Mechanical call-site rewrites in vm:
- `cursorRow/Col/Stop` → `ec:row()/:col()/:stop()`.
- Direct cursor writes → `ec:setPos`, `ec:rescaleRow`, `ec:shiftSelection`.
- `sel` reads → `ec:region()` or `ec:hasSelection()`.
- `selBounds/For/selectedEvents/selectedCols/selectedChans` → ec equivalents.
- `inBlock/unstick` → `ec:isSticky/unstick`.

Vm's public passthroughs (`vm:cursor`, `vm:selection`, `vm:selStart/Update/Clear`, `vm:setCursor`, `vm:selectChannel/Column`, `vm:markMode/clearMark`) still exist — they forward to ec. rm untouched in this stage.

Green all tests, including Stage 1 additions.

### Stage 3 — kill magic numbers, unify on `kind`

- `deleteEvent` 993–1000: `selGrp == 2/3` → `ec:cursorKind() == 'vel'/'delay'`.
- `pasteSingle` 1903/1920/1963: `selGrp == 1/2` → `ec:cursorKind() == 'pitch'/'vel'`.
- `ec:eventsByCol()` returns entries keyed by `kind` field (not `noteMode` string); `nudge` and `deleteSelection` read `g.kind`.
- Retire `noteKind` mixed-key table.
- `'val'` unifies into `ec:kind()` for scalar-col region; `applyNudge` reads it unchanged.

**Check**: `grep 'selGrp\|selgrp\|g1 ==\|g2 ==' viewManager.lua` returns zero hits outside ec.

### Stage 3.5 — ec owns STOPS/SELGROUPS via a decorator

Move `STOPS` and `SELGROUPS` out of vm and into the ec factory, alongside `NOTE_KIND_BY_SELGRP`/`SELGRP_BY_NOTE_KIND`. Expose a decorator:

```lua
function ec:decorateCol(col)
  local key = (col.type == 'note' and col.showDelay) and 'noteWithDelay' or col.type
  col.stopPos   = STOPS[key]     or {0}
  col.selGroups = SELGROUPS[key] or {0}
end
```

`addGridCol` drops its local `stopKey` line and the inline `stopPos`/`selGroups` assignments, replacing them with one `ec:decorateCol(gridCol)` after the half-built table. Field names become ec-private — vm never mentions `STOPS`/`SELGROUPS`/`stopKey`/`stopPos`/`selGroups` anywhere.

**Check**: `grep 'STOPS\|SELGROUPS\|stopKey' viewManager.lua` returns hits only inside the ec factory.

**Structural invariant (landed alongside):** `trackerManager.lua` default for an unseeded channel changed from `{ notes = 0 }` to `{ notes = 1 }`. This makes `#grid.cols >= 16` a real invariant rather than a situational property, letting vm motion functions (`moveStop`, `moveUnit`, `moveCol`, `moveChannel`, `selUpdate`) assume a non-empty grid. Six tests that pinned the old zero-lane behaviour were migrated.

### Stage 4 — renderManager consumes ec directly

Expose `vm:ec()` accessor. Rewrite rm:

- `vm:cursor()` / `vm:selection()` call sites → `ec:row/col/stop`, `ec:region/hasSelection`.
- rm:427–434 raw `selGroups[s] <= sel.selgrp2` loops → `ec:selectionKindSpan(col)`.
- rm:531/532/539/540/543/544/577/578 mutation calls → ec methods directly.

Retire vm's now-redundant passthroughs (`vm:cursor`, `vm:selection`, `vm:selStart/Update/Clear`, `vm:setCursor`, `vm:selectChannel/Column`, `vm:markMode/clearMark`).

### Stage 5 — extract to `editCursor.lua`

Lift the factory into its own module. `continuum.lua` loads it; vm constructs with `ec = newEditCursor(grid, ctx, cm)` and installs `ec:afterMove(followViewport)`.

Expected vm.lua shrinkage: ~200–250 lines.

### Stage 6 — clipboard extraction

With `ec:region/cols/ppqSpan/eventsByCol/cursorKind` available, clipboard lifts cleanly. Update `project_viewmanager_refactor` memory to reflect the new staging.

## Risks already surfaced

1. `copy` behaviour with no sel is unverified — Stage 1 verifies and pins.
2. `rebuild()` must call `ec:reset()` before the trackerManager cascade; take-scoped state goes through the reset path.
3. `duplicate`'s save/restore + sel-rebuild gymnastics (viewManager.lua:2158–2173) — leave alone in Stage 2; consider `ec:withPosition(...)` tidy in a later stage if still ugly.
4. Existing uncovered paths (`duplicate`, `adjustPosition`, `noteOff` solo, nudge solo) need minimal specs in Stage 1 before they're touched.

## Exit criteria per stage

| Stage | Done when |
|-------|-----------|
| 1 | New specs green; existing suite green. |
| 2 | All vm-internal cursor/sel access goes through ec; rm unchanged; full suite green. |
| 3 | No `selGrp\|selgrp\|g1 ==` hits outside ec; `noteKind` table gone; full suite green. |
| 3.5 | No `STOPS\|SELGROUPS\|stopKey` hits outside ec; `#grid.cols >= 16` invariant holds via tm default; full suite green. |
| 4 | rm calls `vm:ec():…` directly; passthroughs removed; full suite green. |
| 5 | `editCursor.lua` exists; vm constructs via factory; full suite green. |
| 6 | Clipboard lifted; memory updated. |

## First concrete step on resume

Check `copy` behaviour with no selection (read `collectSelection` → `copySelection` path; trace what happens when `sel == nil`), then draft the Stage 1 spec list.
