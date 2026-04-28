# viewManager

Projects tm's channel/column tree onto a 2D display grid, owns cursor /
selection / clipboard, and exposes the editing command surface. Produces
`vm.grid` for rm to read each frame; does no ImGui work itself.

## viewContext

A pure, throwaway snapshot built once per `vm:rebuild`. Binds the
swing snapshot, `rowPPQs` (prefix array of PPQ per row boundary),
`length`, `numRows`, `rowPerBeat`, `ppqPerRow` (the straight-grid row
width — fractional in odd `(rpb, denom)` combinations), `timeSigs`,
`tuning`. Every method is a function of the bound state plus its args —
no callbacks, no mutation. Throw it away and rebuild a new one; there
is no migration.

Two responsibilities:

- **Row ↔ PPQ projection.** `ppqToRow(ppq, chan)` binary-searches
  `rowPPQs`, unapplying channel-relevant swing first; `rowToPPQ` is the
  inverse (floor + swing-apply). Per-chan, because column swings
  differ. `ppqPerRow()` exposes the bound straight-grid row width so
  callers (e.g. clipboard paste) can compute straightPPQ at the
  destination row.
- **Tuning lens.** `noteProjection(evt)` resolves `(pitch, detune)`
  into `(label, gap, halfGap)` under the bound microtuning, or nil if
  none active.

**Row placement and off-grid follow the spec** (`design/archive/swing.md`):

```
displayRow(e) = round(ppqToRow_c(e.ppq))                  -- under current swing
offGrid(e)    = rowToPPQ_c(displayRow(e)) ≠ e.ppq
```

`rowPPQs` is stored as **floats** (`r · ppqPerRow`, no rounding) so
`rowToPPQ` / `ppqToRow` are mutually exact — a single round happens
only at realisation. The off-grid test then collapses to a clean
integer compare, with no ε to tune. A swing slot change correctly
surfaces previously-on-grid events as off-grid: their realised ppq
sits at the old grid's swung position, which under the new swing no
longer matches `rowToPPQ_c(N)`.

`evt.straightPPQ` and `evt.frame` are not consulted by rebuild's row
placement — they exist for `reswing` (preserve authored row across
swing changes) and for editing operations that need the unswung row
position.

## Ghost sampling

For each consecutive scalar pair whose first event has a non-step
shape, `vm:rebuild` samples the curve at every row strictly between
A and B (skipping occupied rows) and writes `{ val, fromEvt, toEvt }`
into `gridCol.ghosts[y]` for rm to render. The sample point for row
`y` is `ctx:rowToPPQ(y, chan)` — so under swing the ghost reflects
the value at the row's realised time, not at "fraction of rows
traversed". Curve evaluation is delegated to `tm:interpolate` (which
forwards to `mm:interpolate`); the shape / tension / bezier-handle
table are owned by midiManager.

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

A selection extends the caret into a rectangle. Internally:

```
sel = { row1, row2, col1, col2, selgrp1, selgrp2 }   -- or nil
```

At the public boundary `ec:region()` returns
`row1, row2, col1, col2, kind1, kind2` (with cursor-degenerate fallback
to a 1×1 rect — `ec:hasSelection()` is the bit when that distinction
matters), and `ec:setSelection{ row1, row2, col1, col2, kind1, kind2 }`
takes a kind-typed record. selgrps stay internal.

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
`{ grid, cm, rowPerBar, moveHook }`, passing `followViewport`
as the move hook. ec reads pure config (`advanceBy`, `rowPerBeat`)
straight from cm; vm only passes the derived `rowPerBar` closure.
Both vm and rm consume ec directly — rm reaches it via `vm:ec()`.
ec owns: position (`row/col/pos/setPos/clampPos`),
motion (`advance` for advance-by; `moveStop/Col/Channel` and
`cycleHBlock/VBlock/swapEnds` are command-internal), selection
(`selClear/isSticky/unstick/extendTo/setSelection/shiftSelection/selectChannel/Column/eachSelectedCol`),
kind (`cursorKind/region/regionStart/selectionStopSpan`),
grid-column kind decoration (`decorateCol`), lifecycle
(`reset/rescaleRow`), and command registration (`registerCommands`).
Cursor-axis clamping lives in `ec:clampPos`; viewport follow stays
vm-side because it touches scrollRow/scrollCol and runs through the
move hook.

## Frames and straight ppq

Two halves of one mechanism: authoring frames stamped on notes at
write time, and a view-layer override that pushes a frame onto cm's
`transient` tier when active.

**Per-event stamp.** vm (and clipboard, in `editCursor.lua`) set
`evt.frame = currentFrame(chan)` at every authoring call site before
handing the event to `tm:addEvent`. tm doesn't know what a frame is —
it just persists whatever is supplied as sidecar metadata. `currentFrame`
reads merged cm, so a transient override is naturally inherited:
events authored under the override stamp the override's frame, not
the underlying cfg's. PAs are bound to a host note, so the call site
sets `evt.frame = host.frame` instead.

CC / PB / AT / PC frames travel as sidecar metadata at the mm layer
(the same channel the per-note `uuid → metadata` map uses). On rebuild,
tm copies `cc.frame` onto the column-level event tables.

**Straight ppq** rides alongside `frame`. Every event with a frame
carries `straightPPQ` (and `straightEndPPQ` for notes), the canonical
authoring-grid position pre-swing, pre-delay. The invariant is

```
evt.ppq         = round(apply(frame.swing, evt.straightPPQ))
evt.straightPPQ = r · timing.straightPPQPerRow(frame.rpb, denom, res)   -- r integer ⇔ on-grid
```

Mutation rules (one rule per kind of edit, exhaustively):

| operation                                | straightPPQ                                                   | frame             |
| ---------------------------------------- | ------------------------------------------------------------- | ----------------- |
| snap-to-cursor (off-grid → cursor row)   | `cursorRow · sppr_currentFrame`; end preserves straight delta | restamp `currentFrame` |
| shift-by-rows (`adjustPosition`, multi)  | `+= rowDelta · sppr_currentFrame`                             | restamp `currentFrame` |
| quantize (snap to nearest row)           | `newRow · sppr_currentFrame`                                  | restamp `currentFrame` |
| insert-row / delete-row                  | `± numRows · sppr_currentFrame`                               | restamp `currentFrame` |
| delay nudge                              | unchanged                                                     | unchanged              |
| reswing (frame swap)                     | unchanged; realised re-applied                                | restamp `currentFrame` |
| reswing-preset (composite for `name` changes) | unchanged; realised re-applied                          | unchanged (name kept)  |

Events without a `frame` (e.g. older data) are skipped by
`reswingCore`: there is no after-the-fact frame inference. They also
carry no `straightPPQ`; rebuild displays them via `ppqToRow` on the
realised ppq directly (which, in the absence of swing, is the same as
straight).

**View-layer override.** `matchGridToCursor` (Ctrl-G) reads the
authoring frame off the note under the cursor and writes it to cm's
`transient` tier as a unit (`swing`, `colSwing`, `rowPerBeat`).
Because `transient` is most-specific in the merge, every reader of
those keys — including `tm:swingSnapshot()` and the rebuild itself —
sees the override values without any vm-side lensing. Toggling the
command again drops the three keys via `cm:assign('transient', ...)`
with `util.REMOVE` sentinels.

`FRAME_KEYS = { swing, colSwing, rowPerBeat }` is the unit of override.
`frameTransientActive()` checks whether any of them currently sit at
the transient tier. `releaseTransientFrame()` peels them and rescales
ec if rpb changes underneath.

The configCallback releases the override automatically when a real
edit lands: any non-`transient` write to a frame key (e.g. the toolbar
calling `cm:set('track', 'rowPerBeat', n)`) triggers
`releaseTransientFrame()` so the user's input is visible. The check
hinges on `changed.level ~= 'transient'`, so vm's own transient-tier
writes don't recursively self-release.

## Rebuild & callbacks

Triggers:

- `tm` `'rebuild'` signal — always rebuilds. The take-swap flag travels
  via tm's separate `'takeSwapped'` signal, captured here into a transient
  flag and consumed by the next rebuild (tm guarantees the firing order);
- `cm` `'configChanged'` signal **except** `mutedChannels` /
  `soloedChannels` (which only push mute). Non-`transient` writes to
  any `FRAME_KEYS` member while a transient override is active are
  short-circuited into `releaseTransientFrame`, whose recursive
  `cm:assign` fires the rebuild.

Reentrancy-guarded by `rebuilding`. `vm:rebuild(takeChanged)` takes a
bool: `true` resets cursor / selection and re-reads `resolution`, `length`,
`timeSigs` from tm; the remaining work (grid cols, `rowPPQs`, the
viewContext, cell/overflow/offGrid maps, ghost maps) runs unconditionally
on every rebuild. Mute is pushed to tm unconditionally at the end.

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
survives, tm re-realises on assign. The straightPPQ is repinned to
the cursor row (`row · sppr_currentFrame`) and the frame is restamped
to current; for notes, straightEndPPQ shifts by the same delta so
straight duration is preserved exactly.

After any edit, `commit` calls `tm:flush`, advances by `advanceBy`,
and optionally auditions the new pitch.

## Clipboard

The clipboard lives in a `newClipboard` factory in `editCursor.lua`
(co-located with ec, since clipboard reads ec's region/eachSelectedCol/
cursorKind to drive collect and paste). vm constructs it once over
`{ ec, grid, tm, cm, currentFrame, getCtx, getLength }` and exposes it
via `vm:clipboard()`. Public surface: `collect`, `copy`, `paste`,
`pasteClip(clip)` (paste a given clip without touching ExtState — used
by `duplicate`), `trimTop(clip, n)`.

The persistent store is REAPER ExtState under `rdm.clipboard`,
serialised via `util.serialise` with `loc` / `sourceIdx` stripped.

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

vm exposes paired domain verbs `vm:<base>Selection()` /
`vm:<base>All()` for each batch op (reswing, quantize,
quantizeKeepRealised). The selection-vs-all-with-confirm UX choice
lives in rm, which dispatches to one or the other.

- **`reswingScope`** — for each event, apply the current target swing
  to the event's stored straightPPQ and restamp the frame to current.
  Two passes (plan, then mutate) so in-flight writes don't disturb
  later events. Writes are clamped to take length: when length doesn't
  sit on a swing-period boundary, apply at the last event can land
  past it, and any write past length makes REAPER auto-extend the
  source on MIDI_Sort — which leaks an extra row into the next
  rebuild.
- **`reswingPresetChange(name)`** — for every event whose authoring
  frame references `name`, re-realise from straightPPQ under the new
  composite. The caller must update the project lib first; the
  snapshot reads it back via cm. No restamp — the name didn't change,
  only the composite behind it.
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

Command registration is split by ownership: ec self-registers
navigation and selection-shape commands via `ec:registerCommands(cmgr)`,
clipboard self-registers `copy/paste` via
`clipboard:registerCommands(cmgr)`, and vm registers everything else
in a single `cmgr:registerAll` at construction. Categories:

- **navigation** (ec) — `cursorDown/Up`, `pageDown/Up`,
  `goTop/Bottom/Left/Right`, `cursorLeft/Right`, `colLeft/Right`,
  `channelLeft/Right`
- **selection** (ec) — `select*` variants, `cycleBlock`, `cycleVBlock`,
  `swapBlockEnds`, `selectClear`
- **clipboard** (clipboard) — `copy`, `paste`. `cut` stays in vm
  because it composes `clipboard:copy()` with `deleteSelection`.
- **edit** (vm) — `delete`, `deleteSel`, `cut`, `duplicateUp/Down`,
  `interpolate`, `insertRow`, `deleteRow`
- **note shaping** — `growNote`, `shrinkNote`, `noteOff`,
  `nudgeForward/Back`, `nudgeCoarse/FineUp/Down`
- **transport** — `play`, `stop`, `playPause`, `playFromTop/Cursor`
- **column management** — `addNoteCol`, `hideExtraCol`
- **display** — `doubleRPB`, `halveRPB`,
  `matchGridToCursor`, `cycleTuning`, `inputOctaveUp/Down`, `advBy0..9`
- **timing** — `cycleSwing`, `setSwingComposite`,
  `reswingPreset`, `setSwingSlot`

`addTypedCol`, `setRPB`, `reswing`, `quantize`, `quantizeKeepRealised`,
`openSwingEditor`, `quit` are owned by rm (they wrap UI orchestration
around vm's domain verbs).

See `docs/commandManager.md` for the dispatch protocol and return-code
convention.

vm then applies three families of `cmgr:wrap`:

- **mark-paste cancel** — in mark mode, the first `paste` press
  clears the selection instead of pasting, so the explicit second
  press pastes at the cursor.
- **auto-unstick** — all nudge / grow / duplicate / interpolate /
  row-insert / `noteOff` commands drop sticky flags after running.
  (rm applies the same wrapper to its `reswing` / `quantize` /
  `quantizeKeepRealised` registrations.)
- **auto-selClear** — `delete` / `deleteSel` / `cut` clear the
  selection after running, since the affected events are gone.

## Conventions

- **Rows 0-indexed, cols 1-indexed, channels 1..16, stops 1-indexed.**
- **`vm.grid` is a live handle** — rm reads it each frame; it is
  mutated in place on rebuild, never reassigned, so rm need not
  re-fetch.
- **rm is pull-only.** vm fires no render callbacks; rm queries
  `vm.grid`, `vm:ec()`, `vm:rowPerBar()` etc. each frame, and reads
  pure config (`rowPerBeat`, `currentOctave`, `advanceBy`) directly
  from cm rather than through vm.
- **Frame + straightPPQ stamping is the view layer's responsibility** —
  every authoring call site in vm and clipboard sets `evt.frame =
  currentFrame(chan)` (or `host.frame` for PA) and
  `evt.straightPPQ = row · sppr_currentFrame` before `tm:addEvent`. tm
  is frame-agnostic.
- **Row encoding in the clipboard uses the source column's swing**;
  paste decodes into the destination column's. Round-trip is
  symmetric, not absolute-ppq.
- **Off-grid writes snap intent + straightPPQ** to the cursor row;
  delay survives, frame restamps to current.

---

## API reference

### Construction & lifecycle

```
newViewManager(tm, cm, cmgr)   -- wires callbacks on tm/cm and rebuilds
vm:rebuild(changed)            -- manual rebuild; defaults to { take=false, data=true }
vm:tick()                      -- called each frame by rm; kills stale audition
```

### Grid readout (for rm)

```
vm.grid                         -- see "Grid shape"; live handle
vm:ec()                        -> editCursor (rm uses ec:pos, ec:hasSelection, ec:region, ec:selectionStopSpan)
vm:rowPerBar()                 -> rows per bar (rowPerBeat × first ts num)
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

vm itself owns viewport sizing and rpb; the cursor and selection live
on ec (reach via `vm:ec()`).

```
vm:setGridSize(w, h)           -- visible viewport in chars / rows
vm:setRowPerBeat(n)            -- clamped 1..32; cursor row rescales
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
