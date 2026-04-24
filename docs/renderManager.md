# renderManager

ImGui rendering and input for one viewManager. Owns no tracker state; pulls
everything from `vm` each frame and routes all writes back through `vm` or
`cmgr.commands`.

## Pull-only discipline

rm caches almost nothing of what vm/tm know. Every frame it re-reads
`vm.grid`, `vm:cursor()`, `vm:selection()`, `vm:displayParams()` etc.
fresh. The only persistent local state is ephemeral UI:

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

## Paint order

`drawTracker` draws back-to-front:

1. Channel-label row, column labels, column sub-labels.
2. Header separator, inter-channel vertical dividers.
3. Row backgrounds (bar / beat tint) and row numbers.
4. Sustain tails — per-note continuous bars from intent `ppq` to `endppq`.
5. Cells, char by char.
6. Off-grid projection bars — only under an active tuning, only for
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
  the note name).

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

## Input

Three independent dispatches, gated by focus:

### Mouse (`handleMouse`)

`nearestStop(mouseX, mouseY)` converts a pixel to `(col, stop, fracX)`.
`fracX` is kept separately from `col` so callers can tell "past the end
of any column" from "inside col N". Behaviours:

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
   GetKeyMods() == mods` fires the command. Return-code protocol is
   the one documented in `docs/commandManager.md` — `'quit'` exits the
   loop, `'modal'` / `'swingEditor'` open the respective overlays,
   `'fallthrough'` keeps scanning the keymap, anything else stops the
   pass.
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

Centred on the viewport, driven by whatever state the triggering
command returned via the `'modal'` return code:

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
  lastCount   = <n factors last seen>,   -- auto-resize trigger
  lastW       = <remembered width>,
  dragOld     = <composite or nil>,      -- captured on slider press
}
```

**Create mode** (no slot set): user types a name, we call
`setSwingComposite(name, {})` + `setSwingSlot(name)` and fall through
to edit mode in the same frame.

**Edit mode**: composite preview + Reset (disabled when clean) + one
row per factor (atom combo, amount slider, period combo, reorder,
delete, PWL thumb) + add-factor button.

**Amount-slider drag.** The slider fires every frame while held. A
naive reswing-on-change would reswing every event under the preset on
every tick. Instead:

- on `IsItemActivated`, snapshot the pre-drag composite into `dragOld`;
- during the drag, `swingPreview` writes the composite without the
  reswing, so the preview thumbs redraw cheaply;
- on `IsItemDeactivatedAfterEdit`, fire `reswingPreset(name, dragOld,
  now)` exactly once.

All other edits (atom, period, reorder, add, delete, Reset) go through
`swingWrite`, which does the full `setSwingComposite` + `reswingPreset`
pair — cheap because they're discrete, low-frequency.

**Periods.** Composites store periods in QN. The UI speaks
bar-fractions via `PERIOD_PRESETS` (`1/16` … `2`), converting through
`barFracToPeriod` (using the take's first time signature) and
`periodLabel`. Non-preset periods show as `N qn` or `N.NNN qn`.

**Auto-resize.** On a change in factor count, `idealSwingHeight`
estimates a height that fits the whole stack; width is preserved from
`lastW`. Clamped to the viewport so auto-grow stays on-screen.

## Colour

Every colour is read lazily from `cm:get('colour.<name>')` and cached
as a packed U32. A cm callback nukes the cache on any `config` change,
so a palette edit takes effect next frame. `pushStyles` applies
ImGui-level window-chrome colours around the main window; all grid
drawing uses the cached palette directly.

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
