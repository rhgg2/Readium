# viewManager

Projects tm's channel/column tree onto a 2D display grid, owns cursor /
selection / clipboard, and exposes the editing command surface. Produces
`vm.grid` for rm to read each frame; does no ImGui work itself.

## viewContext

A pure, throwaway snapshot built once per `vm:rebuild`. Binds the
swing snapshot, `rowPPQs` (prefix array of PPQ per row boundary),
`length`, `numRows`, `rowPerBeat`, `timeSigs`, `tuning`. Every method is
a function of the bound state plus its args — no callbacks, no
mutation. Throw it away and rebuild a new one; there is no migration.

Three responsibilities:

- **Row ↔ PPQ projection.** `ppqToRow(ppq, chan)` binary-searches
  `rowPPQs`, unapplying channel-relevant swing first; `rowToPPQ` is the
  inverse (floor + swing-apply). Per-chan, because column swings
  differ.
- **Tuning lens.** `noteProjection(evt)` resolves `(pitch, detune)`
  into `(label, gap, halfGap)` under the bound microtuning, or nil if
  none active.
- **Ghost sampling.** `sampleGhosts(events, chan, occupied)` walks
  consecutive scalar pairs whose first event has a non-step shape and
  produces interpolated cell values for the rows between them.
  REAPER's shape codes (`linear`, `slow`, `fast-start`, `fast-end`,
  `bezier`) evaluate via a recovered bezier handle table for the
  tension slider.

`pa` events are not ghosted — they live inside note columns.

## Grid shape (vm's output to rm)

```
grid.cols         = { <col>, <col>, ... }     -- flat, 1-indexed
grid.chanFirstCol = { [chan] = i }            -- dense 1..16
grid.chanLastCol  = { [chan] = i }
grid.lane1Col     = { [chan] = <col> }        -- first note col per chan
grid.numRows      = <integer>
```

Each column:

```
{
  type, midiChan,
  lane      = <int>  (note only)    key = lane
  cc        = <int>  (cc only)      key = cc number
  label, events, width,
  stopPos, selGroups,               -- see below
  showDelay = bool,                 -- note only
  cells     = { [y] = evt },        -- y is 0-indexed row
  overflow  = { [y] = true },       -- >1 event landed on row
  offGrid   = { [y] = true },       -- cell's intent ppq is not row-centred
  ghosts    = { [y] = { val, fromEvt, toEvt } },  -- scalar types only
}
```

`events` is the column's event array from tm, sorted by intent ppq.
`cells` keeps only the first event that lands on each row; the rest
are flagged via `overflow`. `offGrid` marks cells whose snapped row
disagrees with their intent ppq (swing, delay, or both).

Column widths: note = 6 (10 with delay), pb = 4, everything else = 2.

## Cursor & selection

The cursor is `(row, col, stop)`. **Stop** indexes into `col.stopPos`,
the list of character offsets inside the column where the caret can
sit (e.g. `{0,2,4,5}` for `C-4 30`). **Selgroup** is the semantic axis
at that stop, read from `col.selGroups[stop]`:

| type             | stops                  | selgroups           |
|------------------|------------------------|---------------------|
| note             | `{0,2,4,5}`            | `{1,1,2,2}`         |
| note with delay  | `{0,2,4,5,7,8,9}`      | `{1,1,2,2,3,3,3}`   |
| pb               | `{0,1,2,3}`            | `{1,1,1,1}`         |
| cc / at / pa / pc| `{0,1}`                | `{1,1}`             |

Note selgroups: 1 = pitch, 2 = velocity, 3 = delay. `(col, selgrp)`
picks which typed edit a keypress performs (pitch vs velocity vs
delay) and which clipboard / nudge semantics apply.

A selection extends the caret into a rectangle:

```
sel = { row1, row2, col1, col2, selgrp1, selgrp2 }   -- or nil
```

`selAnchor` is the fixed end; the cursor is the moving end. Sticky
block scopes cycle orthogonally:

- **hBlockScope** `0 → col → channel → all-cols → col → …`
- **vBlockScope** `0 → beat → bar → all-rows → beat → …`

Each cycle press widens one axis; the two compose freely. `selClear`
exits block mode (drops both scopes and the anchor); `unstick` drops
the sticky flags but keeps `sel` visible for one frame of feedback
after a destructive op — the next cursor move then clears it.

`swapBlockEnds` exchanges anchor and cursor on whichever axes are not
scope-locked, letting the user drive the opposite edge.

The cursor and selection live in a `newEditCursor` factory in
`editCursor.lua`. vm constructs one ec at startup over
`{ grid, rowPerBeat, rowPerBar }` and installs `followViewport` via
`ec:setMoveHook`. Both vm and rm consume ec directly — rm reaches it
via `vm:ec()`. ec owns: position (`row/col/stop/setPos/clampPos`),
motion (`moveRow/Stop/Col/Channel`), selection
(`selStart/Update/Clear/isSticky/unstick/swapEnds/cycleHBlock/VBlock/setSelection/shiftSelection/selectChannel/Column/eachSelectedCol`),
kind (`cursorKind/kindAt/region/regionFrom/selectionStopSpan`),
grid-column kind decoration (`decorateCol`), and lifecycle
(`reset/rescaleRow`). Cursor-axis clamping lives in `ec:clampPos`;
viewport follow stays vm-side because it touches scrollRow/scrollCol
and runs through the move hook.

## Frames

Two halves of one mechanism: authoring frames stamped on notes at
write time, and a view-layer override that replaces cfg when active.

**Per-note stamp.** Every new note gets `evt.frame = currentFrame(chan)`
on write — snapshotting the authoring swing + rpb so later reswings
can undo it. For events that don't carry a frame of their own (CC /
PB / AT / PC / PA), `frameOwner(col, e)` inherits one:

- **notes** own themselves;
- **PA** inherits from the lane-1 note whose pitch and interval
  contain it;
- **CC / PB / AT / PC** inherit from the most recent lane-1 note
  at-or-before their ppq on the same channel.

Orphans (no lane-1 note / no PA host) return nil and are skipped by
reswing. Legacy notes without a frame pass identity — `auth=nil` in
`reswingCore` means no authoring unapply.

**View-layer override.** `matchGridToCursor` (Ctrl-G) reads the
authoring frame off the note under the cursor and installs it:

```
frameOverride = { swing, col, chan, rpb }   -- col applies only to chan
```

`effectiveSwing` / `effectiveColSwing(chan)` / `effectiveRPB` read
from the override when present, else from cfg. `swingOverrideArg`
packages the override for `tm:swingSnapshot`, substituting only the
override's channel so other channels fall through to cfg. Any cfg
change to `swing` / `colSwing` / `rowPerBeat` invalidates the override
(see `frameKeys` in the cm callback).

`currentFrame(chan)` is the glue: it reads the effective values (so
new notes authored under an override inherit the override's frame)
and produces the snapshot that gets stamped.

## Rebuild & callbacks

Triggers:

- `tm` callback when `changed.data` or `changed.take` fires;
- `cm` callback on any config change **except** `mutedChannels` /
  `soloedChannels` (which only push mute), plus the side-effect that
  `swing` / `colSwing` / `rowPerBeat` changes nuke `frameOverride`
  before the rebuild.

Reentrancy-guarded by `rebuilding`. `changed.take` resets cursor /
selection and re-reads `resolution`, `length`, `timeSigs` from tm;
`changed.data` rebuilds the grid cols, `rowPPQs`, the viewContext,
cell/overflow/offGrid maps, and ghost maps. Mute is pushed to tm
unconditionally at the end.

## Mute / solo

vm owns the **effective mute** = persistent-mute ∪ solo-implied mute.
When any channel is soloed, non-soloed channels are forced muted and
soloed channels are forced audible (DAW convention — solo wins over
persistent mute).

Both sets persist in cm so that on reload tm's `lastMuteSet` matches
the muted flag already on the wire; otherwise a take where solo had
silenced channels would come back unmuted. `effectiveMuted` is cached
for cheap per-cell render queries; `pushMute` recomputes it and
forwards to `tm:setMutedChannels`.

## Editing contract

All writes funnel through tm:

```
tm:addEvent / tm:assignEvent / tm:deleteEvent / tm:flush
```

vm never touches mm. `editEvent(col, evt, stop, char, half)` is the
single typed-input entry point; it dispatches on `(col.type, stop,
evt-kind)`:

- **note**, stop 1: note name → pitch + detune (microtuning snap if
  active); repitch existing, wipe PA tail if replacing a PA, else
  `placeNewNote` which shortens the prior note and inherits its vel.
- **note**, stop 2: octave (on real notes only).
- **note**, stops 3–4: velocity nibble (hex); falls through to PA
  creation on a sustain row when `polyAftertouch` is on.
- **note**, stops 5–7: decimal signed delay, clamped to the realised
  overlap bound `delayRange`.
- **cc / at / pc**: hex nibble on `val`.
- **pb**: decimal signed nibble on `val`, with `-` toggling sign.

An off-grid edit snaps intent time to the cursor row (`snap`); delay
survives, tm re-realises on assign. Endppq shifts by the same delta
so straight duration is preserved.

After any edit, `commit` calls `tm:flush`, advances by `advanceBy`,
and optionally auditions the new pitch.

## Clipboard

The clipboard lives in a `newClipboard` factory in `editCursor.lua`
(co-located with ec, since clipboard reads ec's region/eachSelectedCol/
cursorKind to drive collect and paste). vm constructs it once over
`{ ec, grid, tm, cm, addNoteEvent, getCtx, getLength }` and exposes it
via `vm:clipboard()`. Public surface: `collect`, `copy`, `paste`,
`pasteClip(clip)` (paste a given clip without touching ExtState — used
by `duplicate`), `trimTop(clip, n)`.

The persistent store is REAPER ExtState under `rdm.clipboard`,
serialised via `util:serialise` with `loc` / `sourceIdx` stripped.

Clip events encode rows in the **source column's** own swing frame;
paste decodes them into the **destination column's** frame via
`rowToPPQ`. The round-trip is consistent even when source and
destination have different effective swings, because both sides go
through `(row, chan)`.

Two clip modes:

- **single** — one column selected. `type` ∈ `{ note, 7bit, pb }`;
  the selgrp at copy time picks `note` vs `7bit` for note columns.
- **multi** — multiple columns. Each entry carries `chanDelta`
  (relative to leftmost source channel) and a `key`: lane index for
  notes, cc number for ccs, nil for singletons.

Paste heuristics:

| clip.type | dstCol.type   | selgrp | behaviour                                      |
|-----------|---------------|--------|------------------------------------------------|
| note      | note          | 1      | wipe region, write notes with carried velocities |
| pb        | pb            | *      | wipe region, write pb stream                   |
| 7bit      | cc / at / pc  | *      | wipe region, write val stream                  |
| 7bit      | note          | 2      | `pasteVelocities` — carry-forward onto note-ons, optionally synth PAs on sustain rows |

Multi paste resolves each clip col via `chanDelta` from the cursor's
channel; destinations missing (out-of-range channel, no matching
cc/singleton column) are skipped. Notes anchor to the cursor's lane,
other clip cols shift relative.

`duplicate(dir)` copies the selection to the adjacent block without
touching the user clipboard: it calls `clipboard:collect()` and
`clipboard:pasteClip(clip)` directly. Going up past row 0
`clipboard:trimTop`s the clip in place — the start of the block is cut
off, not the end — so selection follows and repeated invocations stack
cleanly.

## Reswing / quantize

All batch operations go through the same scope protocol: if there's a
selection, operate on it; otherwise confirm via modal and operate on
the whole take (`scopeOrConfirm`, `allGroups`).

- **`reswingScope`** — for each event, unapply its owner's authoring
  frame, apply the current target frame, and restamp notes with the
  current frame. Two passes (plan, then mutate) so in-flight writes
  don't disturb later events' reads of their owners' `.frame`.
- **`reswingPresetChange(name, oldComp, newComp)`** — for every event
  whose authoring frame references `name`, rebase from `oldComp` to
  `newComp` using `libOverride` to inline both composites. Independent
  of the library's current state, so the caller may invoke before or
  after writing the new composite. No restamp — the name didn't
  change, only the composite behind it.
- **`quantizeScope`** — snap every event to the nearest row under the
  current frame; notes preserve straight length in rows.
- **`quantizeKeepRealisedScope`** — move the intent onto the grid
  **without changing realised time**: intent shifts, delay absorbs
  the inverse. If the required delay exceeds the overlap-bounded
  `delayRange`, clamp — realised still preserved, intent remains
  partially off-grid. Popup reports the clamp count.

## Extra columns & delay sub-column

Columns beyond the data-driven ones are materialised by tm from
`cfg.extraColumns[chan]`. vm owns the user-facing add/remove:

- `addExtraCol(type, cc)` — bumps the `notes` count, sets `ccs[cc]`,
  or sets the singleton flag. Applies to every unique channel in the
  active selection, or the cursor col's channel when no selection.
- `hideExtraCol` — current cursor col only; refuses populated cols
  and the sole note column of a channel. For notes, compacts
  higher-lane indices down by 1 (both in the events via `assignEvent`
  and in `noteDelay` keys).
- `showDelay()` — turns on the delay sub-column (via
  `cfg.noteDelay[chan][lane] = true`) on every note col in the active
  selection, or on the cursor col when no selection. Idempotent.

The delay sub-column is a display variant of the note column
(`noteWithDelay` in `STOPS`/`SELGROUPS`), not a separate grid column.

## Audition

One pending note-off at a time, keyed by `(midiChan, pitch)`, sent
via `reaper.StuffMIDIMessage`. `vm:tick` (called each frame by rm)
kills stale auditions after `AUDITION_TIMEOUT` (0.8s). MIDI chan is
0-indexed at the REAPER boundary only; everywhere else vm speaks
1-indexed.

## Commands & wrappers

vm registers its full command set in a single `cmgr:registerAll` at
construction, keyed by flat string names. Categories:

- **navigation** — `cursorDown/Up`, `pageDown/Up`, `goTop/Bottom/Left/Right`,
  `cursorLeft/Right`, `colLeft/Right`, `channelLeft/Right`
- **selection** — `select*` variants, `cycleBlock`, `cycleVBlock`,
  `swapBlockEnds`, `selectClear`
- **edit** — `delete`, `deleteSel`, `copy`, `cut`, `paste`,
  `duplicateUp/Down`, `interpolate`, `insertRow`, `deleteRow`
- **note shaping** — `growNote`, `shrinkNote`, `noteOff`,
  `nudgeForward/Back`, `nudgeCoarse/FineUp/Down`
- **transport** — `play`, `stop`, `playPause`, `playFromTop/Cursor`
- **column management** — `addNoteCol`, `addTypedCol`, `hideExtraCol`
- **display** — `doubleRPB`, `halveRPB`, `setRPB`,
  `matchGridToCursor`, `cycleTuning`, `inputOctaveUp/Down`, `advBy0..9`
- **timing** — `reswing[All]`, `quantize[All]`,
  `quantizeKeepRealised[All]`, `cycleSwing`, `setSwingComposite`,
  `reswingPreset`, `setSwingSlot`, `openSwingEditor`

See `docs/commandManager.md` for the dispatch protocol and return-code
convention.

vm then applies three families of `cmgr:wrap`:

- **mark-paste cancel** — in mark mode, the first `paste` press
  clears the selection instead of pasting, so the explicit second
  press pastes at the cursor.
- **auto-unstick** — all nudge / grow / duplicate / interpolate /
  row-insert / reswing / quantize commands drop sticky flags after
  running.
- **auto-selClear** — `delete` / `deleteSel` / `cut` clear the
  selection after running, since the affected events are gone.

## Conventions

- **Rows 0-indexed, cols 1-indexed, channels 1..16, stops 1-indexed.**
- **`vm.grid` is a live handle** — rm reads it each frame; it is
  mutated in place on rebuild, never reassigned, so rm need not
  re-fetch.
- **rm is pull-only.** vm fires no render callbacks; rm queries
  `vm.grid`, `vm:cursor()`, `vm:selection()`, `vm:displayParams()`
  etc. each frame.
- **Frame stamping is unconditional on note add** via
  `addNoteEvent` — the single choke point. Never call
  `tm:addEvent('note', ...)` from vm directly.
- **Row encoding in the clipboard uses the source column's swing**;
  paste decodes into the destination column's. Round-trip is
  symmetric, not absolute-ppq.
- **Off-grid writes snap intent** to the cursor row; delay survives.

---

## API reference

### Construction & lifecycle

```
newViewManager(tm, cm, cmgr)   -- tm/cm may be nil; attach later
vm:attach(tm, cm)              -- detach any prior, rebuild immediately
vm:detach()                    -- remove callbacks from attached tm/cm
vm:rebuild(changed)            -- manual rebuild; defaults to { take=false, data=true }
vm:tick()                      -- called each frame by rm; kills stale audition
```

### Grid readout (for rm)

```
vm.grid                         -- see "Grid shape"; live handle
vm:cursor()                    -> cursorRow, cursorCol, cursorStop, scrollRow, scrollCol
vm:selection()                 -> sel or nil
vm:displayParams()             -> rowPerBeat, rowPerBar, resolution, currentOctave, advanceBy
vm:timeSig()                   -> num, denom  (first ts of the take)
vm:markMode()                  -> bool  (inside a sticky block)
vm:lastVisibleFrom(startCol)   -> last grid col that fits in gridWidth from startCol
```

### Projection / tuning

```
vm:ppqToRow(ppq, chan)         -- fractional row
vm:activeTuning()              -- bound microtuning object or nil
vm:noteProjection(evt)         -> label, gap, halfGap  (or nil if no tuning)
vm:rowBeatInfo(row)            -> isBarStart, isBeatStart
vm:barBeatSub(row)             -> bar, beat, sub, ts
```

### Cursor / selection / scroll

```
vm:setGridSize(w, h)           -- visible viewport in chars / rows
vm:setCursor(row, col, stop)
vm:setRowPerBeat(n)            -- clamped 1..32; cursor row rescales
vm:selStart() / vm:selUpdate() / vm:selClear()
vm:selectChannel(chan)         -- sticky all-rows channel-wide selection
vm:selectColumn(col)           -- sticky all-rows single-column selection
vm:clearMark()                 -- alias for selClear
```

### Channel mute / solo

```
vm:isChannelMuted(chan)            -> bool
vm:isChannelSoloed(chan)           -> bool
vm:isChannelEffectivelyMuted(chan) -> bool
vm:toggleChannelMute(chan)
vm:toggleChannelSolo(chan)
```

### Extra columns

```
vm:addExtraCol(type, key)          -- type ∈ {note, cc, pb, at, pc}
                                   -- key = cc number (cc only); ignored otherwise
                                   -- applies to selection, else cursor col's channel
vm:hideExtraCol()                  -- current cursor col; refuses populated / sole note col
vm:showDelay()                     -- applies to selection, else cursor col; non-note skipped
```

### Editing

```
vm:editEvent(col, evt, stop, char, half)
```

`col` is a grid column table, `evt` the currently-resident event or
nil, `stop` the 1-indexed caret stop, `char` the typed character
code, `half` the sub-nibble index for multi-digit fields. Routes
through tm; commits and advances on success.

### Commands exposed to cmgr

Full set registered via `cmgr:registerAll`; see the *Commands &
wrappers* section for the category breakdown, and `docs/commandManager.md`
for dispatch and the return-code protocol.
