# renderManager

ImGui rendering and input for one viewManager. Owns no tracker state; pulls
everything from `vm` each frame and routes all writes back through `vm` or
`cmgr.commands`.

## Pull-only discipline

rm caches almost nothing of what vm/tm know. Every frame it re-reads
`vm.grid`, `vm:ec()`, `vm:rowPerBar()` etc. fresh, and reads pure
config (`rowPerBeat`, `currentOctave`, `advanceBy`) directly from cm.
The only persistent local state is ephemeral UI:

- grid cell metrics (`gridX`, `gridY`) — derived once from
  `CalcTextSize('W')` and held.
- drag pin (`dragging`, `dragWinX/Y`) — see *Mouse* below.
- `modalState`, `swingEditor` — overlay lifecycle.
- `colourCache` — flushed on any cm config change.

Nothing in rm mirrors data that lives in a lower layer.

## Coordinate system

rm works in two spaces:

- **Pixel space** — what ImGui speaks.
- **Grid-cell space** — integer `(x, y)` measured in monospace character
  cells. All grid drawing goes through the `printer` helper, which folds
  the pixel conversion into one place.

`gridX`/`gridY` are the per-cell pixel size; `gridOriginX`/`gridOriginY`
is the per-frame pixel anchor of cell `(0, 0)`. The grid *data* starts
at `(0, 0)`; header rows sit at negative y (`-HEADER = -3`), the
row-number gutter at negative x (`-GUTTER = -4`). Every `draw:*`
method takes cell coordinates.

Visible columns are laid out afresh each frame, starting from
`scrollCol` and assigning `col.x` left-to-right until the next column
would overflow `gridWidth`. Everywhere downstream, `col.x == nil`
is the visibility predicate.

`computeLayout()` runs once per frame between `drawToolbar` and the
draw routines. It establishes char metrics, viewport dimensions, and
calls `layoutColumns`, leaving `chanX/chanW/chanOrder/totalWidth` as
factory locals shared by `drawLaneStrip` and `drawTracker`. `gridHeight`
already accounts for the lane strip's `laneStrip.rows`, so the tracker
sees the row count it actually gets to fill.

## Paint order

`drawTracker` draws back-to-front:

1. Channel-label row, column labels, column sub-labels.
2. Header separator, inter-channel vertical dividers.
3. Row backgrounds (bar / beat tint) and row numbers.
4. Sustain tails — per-note continuous bars from intent `ppq` to `endppq`.
5. Cells, char by char.
6. Off-grid projection bars — only under an active temperament, only for
   notes with a non-zero `(intent − displayed)` gap.
7. Selection highlight.
8. Cursor (single-cell box + re-painted cursor char).

Tails sit above the row backgrounds but below cells, so cell characters
paint over the tail pixels at the note head and foot.

## Cell painting

`renderFns[col.type]` dispatches per type. Each renderer returns
`text, colour?, overrides?`:

- `text` — the string to paint;
- `colour` — a single-colour hint for the whole cell (e.g. `negative`
  for negative pb or delay);
- `overrides` — `{ [charIdx] = colour }` for per-character colouring
  (note renderer uses it to paint negative-delay digits without tinting
  the note name; under `trackerMode`, also dims the sample digits with
  `shadowed` when `evt.sampleShadowed` is set).

Colour resolution per cell, outermost-wins:

- **`col.type` has no renderer** → cell is skipped.
- **Ghost** (no evt but `col.ghosts[row]`) → `ghost` / `ghostNegative`.
- **Overflow** (more than one event on this row) → `overflow`, ignoring
  any evt-supplied colour.
- **Off-grid** promotes the `text` default to `offGrid`; an evt-supplied
  override (`negative`) outranks it.
- **Channel effectively muted** forces `inactive` over everything else.
- **Dots `·`** are always painted `inactive`, regardless of the run's
  colour — so a single renderer output splits into multiple coloured
  runs on dot boundaries.

`pa` events inside note columns render as `··· vv`: velocity shows, the
note name is dotted out.

## Lane strip

`drawLaneStrip` renders a single horizontal envelope above the tracker
grid, mirroring its horizontal extent. Time goes left→right (decoupled
from the tracker's vertical time axis below); the y-axis is value.

The strip displays the column the cursor is currently on if its type is
`cc`, `pb`, or `at`; otherwise the strip is just a tinted background.
Anchors are circles at each event's `(ppq, val)`; segments between
consecutive events follow the shape on the *first* event of the pair —
`step` paints horizontal-then-vertical, `linear` is a straight line, and
the curved shapes (`slow`, `fast-start`, `fast-end`, `bezier`) sample
the curve via `vm:sampleCurve` (which forwards to `tm:interpolate`).
A held-flat segment extends to each viewport edge so the eye never
sees an envelope drop to zero outside the data.

Value range:

- `cc` / `at` — `[0, 127]`, bottom-up.
- `pb` — `[-pbRange*100, +pbRange*100]` cents, axis line at zero.

Bar and beat row-cells are shaded (`rowBarStart`, `rowBeat`) and a 1px
divider sits at every row boundary (`laneRowDivider`), aligned with the
tracker rows below. Anchor dots may overlap the strip's top and bottom
edges — the clip rect is padded vertically so values at the extremes
aren't half-clipped.

Strip height is `laneStrip.rows * gridY`. Visibility is controlled by
`laneStrip.visible` (toolbar checkbox "Graph"); when false, the strip
draws nothing and `computeLayout` reclaims its rows for the tracker.
A pair of `+`/`-` `SmallButton`s in the strip's gutter nudge
`laneStrip.rows` between 3 and 32 (the half-row pad on each side eats
one row, so `rows = 3` is the floor that still shows 2 rows of
envelope). Both keys live at the `global`
level. The strip inherits the window's ambient background. Colour
keys: `colour.laneAxis`, `colour.laneRowDivider`, `colour.laneEnvelope`,
`colour.laneAnchor`, `colour.laneAnchorActive`.

### Lane-strip mouse interaction

`drawLaneStrip` publishes a per-frame `laneLayout` (or `nil` when the
strip isn't showing an envelope) carrying the rect, value scale, row
window, and the active column. `handleMouse` reads it for hit-testing
and dispatch.

State:

- **`laneHover`** — index into `col.events` of the anchor under the
  cursor (within ~6 px), or `nil`. Recomputed each frame inside
  `drawLaneStrip`; suppressed while `laneDrag` is active so the
  highlight stays pinned to the dragged anchor.
- **`laneDrag`** — `{ colIdx, idx }` while a drag is in flight, else
  `nil`. The pinned `colIdx` survives a rebuild that swaps the col
  table; if the column is no longer cc/pb/at the drag aborts.

Active anchor (drag wins over hover) draws at radius 4.5 in
`colour.laneAnchorActive`; inactive anchors stay at 2.5 in
`colour.laneAnchor`.

Click on a hovered anchor starts a drag. Per held frame, rm computes:

- `mouseRow = scrollRow + (mx − x0) / w · rowSpan`
- `toVal = clamp(round(valMin + (yBot − my) / valSpan · (valMax − valMin)))`

and a `toRow` that depends on the modifier:

- **Unmodified.** Direction-aware integer snap. Let
  `currRow = vm:ppqToRow(evt.ppq, chan)`, `target = round(mouseRow)`,
  and `startRow = laneDrag.startMouseRow` (mouse row captured at
  click). The direction predicate compares `mouseRow` to `startRow` —
  *not* to `currRow`. That makes the click frame a no-op by
  construction: any click landing inside the 6 px hit-circle on
  either side of an off-grid event's exact row would otherwise snap
  the event on frame 1. The inner check `target > currRow` /
  `target < currRow` still uses `currRow` because it's a geometric
  question (which side of the event's row does the snap target land
  on?), not a direction one. Neighbour clamps: `≥ floor(prev)+1`
  going down, `≤ ceil(next)−1` going up. If the clamp pushes `target`
  back across `currRow`, `toRow = currRow` (no move) — this is what
  leaves an off-grid event sandwiched between off-grid neighbours
  stationary in time when no integer row fits.

  After any horizontal move, `startMouseRow` is re-anchored to the
  current `mouseRow`. Without this, once the event has snapped past
  `startRow`, `mouseRow > startRow` (or `<`) would stay one-sided and
  the opposite-direction branch could never fire — back-tracking
  would silently break.
- **Shift.** `toRow = mouseRow` (fractional). The result lands ppq
  off-grid; `vm:moveLaneEvent`'s `±1 ppq` clamp is the only floor.

`vm:moveLaneEvent(col, i, toRow, toVal)` is the only write surface;
identity-by-index survives the per-frame flush via the ppq clamp (see
`docs/viewManager.md`). Drag ends when the button releases.

## Input

Three independent dispatches, gated by focus:

### Mouse (`handleMouse`)

Lane-strip first: `handleLaneStrip` claims the gesture if `laneDrag`
is active or a click lands on a hovered anchor (see
*Lane-strip mouse interaction* above). When the strip claims,
`handleMouse` returns immediately and the tracker-grid path below
doesn't run.

For the tracker grid: `nearestStop(mouseX, mouseY)` converts a pixel
to `(col, stop, fracX)`. `fracX` is kept separately from `col` so
callers can tell "past the end of any column" from "inside col N".
Behaviours:

- right-click on channel-label row → toggle that channel's mute.
- click on channel-label row → `selectChannel`.
- click on column-label row → `selectColumn`.
- shift-click in grid body → extend selection (start one if absent).
- plain click in grid body → clear selection, move cursor, begin drag.
  The window position is pinned at `dragWinX/Y` for the duration of the
  drag; without the pin, a drag that clips offscreen makes ImGui
  "helpfully" reposition the window.
- held-and-moving → walk cursor/selection with the mouse. Horizontal
  excursions past a column's edge step the cursor through neighbouring
  `(col, stop)` pairs one at a time, clamped at the ends. The
  selection is lazily started on the first frame the cursor actually
  moves.

Wheel (vertical / horizontal) drives `cursorUp/Down` / `cursorLeft/Right`
one invocation per notch, via direct `cmgr.commands.*` calls —
wheel ignores command return codes.

### Keys (`handleKeys`)

Strictly ordered, one pass per frame:

1. **Command dispatch.** Iterate `cmgr.keymap`; `IsKeyPressed(key) &&
   GetKeyMods() == mods` fires the command. The command returns `false`
   to decline (keep scanning, let the char queue see the press) or
   anything else (incl. `nil`) to consume the keypress. UI effects
   (modal, swing editor, quit) are produced as side effects by commands
   rm itself registers — see `docs/commandManager.md`.
2. **Edit char queue** (unmodified, no command key held). One
   character dequeued via `GetInputQueueCharacter` per frame and
   routed to `vm:editEvent`. The `commandHeld` flag is tracked across
   the dispatch pass because `IsKeyPressed` and the character queue
   don't share auto-repeat timing; without the gate, a held command
   key leaks a character into the edit path.
3. **Shift-digit half-step.** `Shift + 0..9` writes the digit to the
   MSB of the current stop with the half-value filling the LSB. It's
   a dedicated edit path rather than a character-queue entry because
   it needs the modifier state.

Modal is a hard gate: `handleKeys` returns immediately if `modalState`
is set, so the popup owns the keyboard until dismissed.

## Modal

Centred on the viewport. Triggered by rm-internal commands calling
`openPrompt(title, prompt, callback)` or `openConfirm(title, callback)`,
which set `modalState` and call `ImGui.OpenPopup`. The dispatch table:

- **confirm** — Y / Enter → `callback(true)`; N / Escape →
  `callback(false)`; no text buffer.
- **text** (default) — `InputText` with enter-returns-true; Escape
  cancels without invoking the callback; focus is seized on
  appearance.

The callback runs under `pcall` — a misbehaving handler shouldn't take
the render loop down with it.

## Swing editor

Floating, non-modal overlay. Edits a named composite in `cfg.swings`
via `cmgr.commands.setSwingComposite`; the tracker grid behind it
reflows live.

State shape:

```
swingEditor = {
  name        = <slot name>,            -- nil ⇒ create mode
  snapshot    = <composite or nil>,      -- on-open state; Reset restores
  createBuf   = <string>,                -- pending name in create mode
  createError = <string or nil>,
  rpb         = <subdivisions per beat>, -- preview grid resolution; default 4
  lastCount   = <n factors last seen>,   -- auto-resize trigger
  lastW       = <remembered width>,
}
```

**Create mode** (no slot set): user types a name, we call
`setSwingComposite(name, {})` + `setSwingSlot(name)` and fall through
to edit mode in the same frame.

**Edit mode**: header (Editing/Reset/Rows-per-beat) + composite preview
+ one row per factor (atom combo, amount slider, period combo, reorder,
delete) with that factor's preview directly below + add-factor button.

**Preview (`drawSwingGrid`).** A horizontal strip — the tracker on its
side. Cells are the unswung subdivisions (`rpb` per beat); each cell
starts at an unswung tick line. Grid lines are 1px in `text` with alpha
dialled to ~0.7 (full alpha is too loud against the cream bg). A
semi-transparent black filled dot is drawn at the *swung* image of
each unswung tick (`timing.applyFactors` applied at `i/N · periodQN`).
Dots size by meter tier: bar starts and the mid-bar beat (when
`qpb/2` lands on a beat — true in 4/4 and 6/8, false in 3/4 and 2/2)
get the largest radius, other beats slightly smaller, offbeats
smallest. The atom preview (no `shadeMeter`) uses the middle size
throughout.

The composite preview passes `shadeMeter = true` and a period rounded
up to a whole number of bars (`ceil(lcmQN / qpb) · qpb`), so the
beat/bar shading actually corresponds to a meter the user can read:
cells on a beat get `rowBeat`, cells on a bar start get `rowBarStart`.
Both `qpb` and the beat unit come from `meterQN()`, which reads the
take's first time signature — so 6/8 shades on the eighth and 2/2 on
the half, not on every quarter. Per-factor previews use the factor's
own `period` and skip the shading — that period rarely aligns to bars
and the colour bands would mislead.

At a glance: the X tells you *where in time* the note actually lands;
its drift from its cell wall is the swing displacement.

**Amount-slider drag.** The slider fires every frame while held; each
frame routes through `swingWrite`, which reads the currently stored
composite as the "old" side of the delta and reswings just that
per-frame slice. Chained across the drag, those slices compose to the
same total transformation as a single press→release reswing, but the
notes physically move under the cursor as the slider drags.

All edits (slider, atom, period, reorder, add, delete, Reset) share
`swingWrite`'s `setSwingComposite` + `reswingPreset` pair.

**Periods.** Composites store periods in QN. The UI speaks
bar-fractions via `PERIOD_PRESETS` (`1/16` … `2`), converting through
`barFracToPeriod` (using the take's first time signature) and
`periodLabel`. Non-preset periods show as `N qn` or `N.NNN qn`.

**Auto-resize.** On a change in factor count, `idealSwingHeight(n)`
estimates a height that fits the whole stack (chrome + composite
preview + n × per-factor block). Width is preserved from `lastW`,
height clamped to the viewport so auto-grow stays on-screen.

## Colour

The colour table in cm is a flat keyspace with three coexisting
namespaces:

- `palette.*` — atoms for the parchment grid palette (`palette.bg`,
  `palette.shade`, `palette.mid`, `palette.highlight`, `palette.inactive`,
  `palette.danger`, `palette.caution`, `palette.positive`, `palette.amber`,
  `palette.steel`, `palette.pale`, `palette.night`, `palette.nightText`).
- `chrome.*` — atoms for the neutral toolbar/popups/modals palette
  (`chrome.bg`, `chrome.shade`, `chrome.mid`).
- `colour.*` — roles that name the *function* a colour plays
  (`colour.bg`, `colour.text`, `colour.rowBeat`, `colour.toolbar.bg`,
  etc.). Roles alias atoms, or other roles, by their full cm key.

Each entry takes one of three forms:

- `{r,g,b,a}` — atom (terminal RGBA).
- `'fullKey'` — pure alias; alpha inherited from the eventual atom.
- `{'fullKey', a}` — alias with alpha override; outermost override wins
  along a chain. (Lua treats 0 as truthy, so `override or v[i]` correctly
  lets an alpha-0 override come through.)

One-off colours that earn no good function name (the yellow editCursor,
faded steel, faded red) live inline at the role rather than as palette
atoms.

`renderManager.resolveColour(key)` chases the chain to an atom, raising
on cycles or unknown keys. The `colour(name)` wrapper takes a bare role
name, prepends the `colour.` namespace, resolves, and caches the U32 by
role name. The cache invalidates on `'configChanged'`, so a palette edit
takes effect next frame. `pushStyles` applies ImGui-level window-chrome
colours around the main window; all grid drawing uses the cached palette
directly.

## Font

`Source Code Pro` at 15 px, attached at `rm:init` and pushed once per
`rm:loop`. Grid character metrics assume this font — `gridX`/`gridY`
are derived on the first frame and held.

## Conventions

- **rm never touches tm.** Writes go through vm or `cmgr.commands`.
- **Cell coordinates are 0-indexed**, both axes. The column axis is
  0-indexed *within the current visible window* — `col.x = 0` is the
  leftmost *visible* column, not `grid.cols[1]`.
- **`col.x == nil` means off-screen.** Every loop over `grid.cols`
  that paints must gate on it.
- **Drag pins the window position** via `SetNextWindowPos(dragWinX,
  dragWinY)` so ImGui doesn't reposition mid-drag.
- **Dots are `inactive` at the character level**, no matter what
  colour the renderer asked for on the rest of the cell.

---

## API reference

### Construction & lifecycle

```
newRenderManager(vm, cm, cmgr)
rm:init()    -- create ImGui context + font; call once
rm:loop()   -> false when the user closes the window; true otherwise
```

`rm:loop` pushes styles, draws toolbar / tracker / status bar / modal
/ swing editor, calls `vm:tick`, and returns `open && !quit`. There is
no public surface beyond these two methods — everything else is
internal to the closure.
