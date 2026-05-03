# Swing

## Basic setup

A **swing** is an orientation-preserving homeomorphism of the unit
interval fixing endpoints:

    S : [0, 1] → [0, 1],   S(0) = 0,   S(1) = 1,   S strictly increasing.

We represent S as a piecewise-linear function through a sorted list of
control points `{(0, 0), (x₁, y₁), ..., (xₙ, yₙ), (1, 1)}`. Evaluation
`S(x)` and inversion `S⁻¹(y)` are each O(log n). Identity swing
`id = {(0,0), (1,1)}`.

Swings are closed under composition: `(S ∘ T)(x) = S(T(x))` is again
piecewise linear, with breakpoints at the union of `{xᵢ}` for T and
`{T⁻¹(yⱼ)}` for S. Swings form a group under composition; `id` is the
unit, `(S ∘ T)⁻¹ = T⁻¹ ∘ S⁻¹`.

A swing's shape lives on `[0, 1]`. To act on the PPQ axis of the take,
we attach a **period** `T` (in PPQ) at the *slot* where the swing is
installed, not intrinsic to the swing. The **tiled extension** of
`(S, T)` to the PPQ axis is

    ŝ(p) = T · (⌊p/T⌋ + S((p/T) mod 1))

i.e. reparameterise within each window of length T. ŝ is an
orientation-preserving bijection of the PPQ axis fixing every multiple
of T. Periods are picked in musical units (a beat, an eighth, a bar)
and converted to PPQ against the local tempo map.

## Slots

Two slots exist:

- **global**: one swing `(S_g, T_g)`, applies to every column.
- **column**: per channel `c`, optionally `(S_c, T_c)`; absent ⇒ `id`.

The **effective view swing** on column `c` is

    E_c = ŝ_g ∘ ŝ_c

(column inner, global outer — column reshapes inside its own period
first, global then reshapes at its own scale).

## Storage

For each event `e`:

- `e.ppq` (and `e.endppq` for notes): REAPER-native, authoritative for
  where the event sounds. No swing is baked into these.
- `delay(e)`: metadata, signed, in **millibeats**. Tempo-stable;
  unbounded sign; no grid quantum. Default `0`.

Everything else is derived. In particular, the **intent PPQ** of an
event is

    intent(e) = e.ppq − mb(delay(e))

where `mb(d)` converts a millibeat delay to PPQ against the local tempo
map. For notes, `endIntent(N) = N.endppq − mb(delay(N))`.

`intent(e)` is where the event would sit if the performance delay were
zero. It is not stored; it is the single degree of freedom the view
layer operates on.

Delay is a notes-only concept. CC, pb, and sysex events have no delay
metadata: their realised `e.ppq` is their intent.

## Delay bounds

Delay is bounded by neighbours. Within each column, for note N with
intent-order predecessor P and intent-order successor Q on the
same column:

    realised(N.start) ≥ realised(P.end)   − overlapOffset
    realised(N.end)   ≤ realised(Q.start) + overlapOffset

This is exactly the existing column overlap rule, applied in the
realised frame after delay is added. `viewManager` is the gatekeeper:
delay entry clamps to `delayRange(col, n)`, the row-shift ops
(`nudgeBack`, `nudgeForward`) pre-check each run and no-op if any
shifted note would collide, and `reGrid` rounds each event
independently (its output can't be worse than the input was).
`trackerManager` trusts the intent it's handed and does not
re-validate — callers outside vm are expected to respect the bound.

Consequence: realised and intent orderings on each column agree up
to the `overlapOffset` wiggle that the pb machinery already tolerates.
There is no bifurcation between frames; the pitchbend invariants from
`pitchbend.md` apply in the realised frame unchanged, and row-order
iteration in the view layer sees the same sequence midiManager does.

## Row ↔ PPQ

Row numbering is a view concern and is per-column. For column `c` with
current subdivision `rowPerBeat = k`:

    rowToPPQ_c(r)  =  E_c( rowToPpqL(r) )
    ppqToRow_c(p)  =  ppqLToRow( E_c⁻¹(p) )

where `rowToPpqL` / `ppqLToRow` are the existing
time-sig-aware linear maps with `ppqPerRow = ppqPerBeat / k`. Swing
enters only through `E_c`; subdivision and time signatures enter only
through the logical map. The two are orthogonal.

Under column `c` the event is displayed with:

    displayRow(e)  =  round( ppqToRow_c(intent(e)) )
    offGrid(e)     =  | ppqToRow_c(intent(e)) − displayRow(e) | > ε

Invariant: `e.ppq = intent(e) + mb(delay(e))`. That is the only
invariant. Swing slots can change freely; events do not move.

## Editing

All editing lives in the intent frame, then re-realises. Queued edits
run sequentially against a simulated state; within each op, all queried
values (`intent`, `delay`, `E_c`, ...) are taken from the state
going in. On flush the raw edits are passed to midiManager.

`trackerManager` rejects channel or lane changes on a note (delete
and recreate instead). Positional validity — non-negative intent
length, delay within overlap bounds — is enforced above, at the vm
edit sites; tm trusts the intent it receives.

### Helper: realise

    realise(e):
      e.ppq    := intent(e) + mb(delay(e))
      e.endppq := endIntent(e) + mb(delay(e))   -- notes only

Pure function of intent. Writing through an assignment that changes
`intent`, `endIntent`, or `delay` always ends with `realise`.

### Add event at row R in column c

- `intent := rowToPPQ_c(R)`
- `delay := 0` (or user-specified)
- `realise`, insert.

For notes: `endIntent := rowToPPQ_c(R + defaultLengthRows)`.

### Move event by Δ rows (in its own column c)

- `intent := rowToPPQ_c( ppqToRow_c(intent(e)) + Δ )`
- if note: `endIntent` shifts by the same row delta.
- `realise`.

Shifting does not force a re-snap: a note at row 4.3 moved by +1
rides through to row 5.3. Selection moves preserve the fractional
offset exactly; the single-note nudge additionally rounds
`ppqToRow_c + Δ` in the direction of travel, which has the effect of
pulling an off-grid note onto the grid on its first move and then
stepping integer rows thereafter. Both reduce to a clean integer row
when the source was on-grid. Explicit re-snapping is `reGrid`.

### Set delay of event e to d (millibeats)

- `delay(e) := d`
- `realise`.

Orthogonal to swing.

### Amend note endpoints

- Write the new intent (subject to `endIntent ≥ intent`).
- `realise`.

### Delete event

- Remove. Nothing else to do — no realisation is tied to deleted events.

### Install or change a swing slot

- Update `(S_g, T_g)` or `(S_c, T_c)`.
- **No events are touched.** Only `E_c` changes, so `rowToPPQ_c` /
  `ppqToRow_c` reshape; the view redraws.

This is the heart of the "swing as pure view" stance: there is no rebuild
after a slot change. Events keep their PPQs; some of them will now
display off-grid (their `intent` no longer lands on an integer row
under the new `E_c`). That is the intended feedback.

### reGrid (explicit, destructive)

An opt-in operation that snaps events to the current grid on their own
columns:

    reGrid(scope):
      for e in scope:
        R := round( ppqToRow_c(e)(intent(e)) )
        intent := rowToPPQ_c(e)(R)
        -- notes: preserve intent length in rows, then re-round end
        realise(e)

Scope is typically "current selection" or "the whole take". This is
the only operation that moves events in response to a swing change,
and it only runs when the user asks for it.

## View-layer affordances

### Off-grid indicator

Events with `offGrid = true` render with a distinguishing glyph (an
italic note character, or a dim marker in the row-number gutter). The
user sees at a glance which notes' intents don't align with the current
subdivision + swing.

Off-grid-ness and non-zero delay are independent: an event can have
either, both, or neither. Delay displays in its own signed sub-column;
off-grid is a flag on the (intent, grid) relationship.

### Match-grid-to-cursor

Command (candidate binding `Ctrl-G`) that sets `rowPerBeat` to the
smallest subdivision putting the note-under-cursor on grid:

    procedure matchGridToCursor:
      N := note under cursor
      x := fractional-beat position of intent(N)  -- already in E_c's frame
      for k = 1, 2, ..., 32:                            -- the range rowPerBeat
        if |k·x − round(k·x)| < ε:                       -- accepts in the toolbar
          setcfg('rowPerBeat', k); return

The status line can additionally show the note-under-cursor's natural
subdivision when off-grid: `♪ off-grid (7)` — a hint before invocation.

### Delay sub-column

`delay(e)` is surfaced in an optional signed sub-column, toggled per
lane as `noteDelay` is today. Units displayed as millibeats (and/or ms
— ms is derived against the local tempo but is convenient for
performance-feel edits). Editing writes `delay` and re-realises;
completely orthogonal to swing.

## Data and config

Per-event metadata (stored via the existing UUID + take-extension
mechanism, alongside `detune`):

    delay            : integer (millibeats, signed)

Config:

    cfg.swing         = { shape = Swing, period = musicalUnit }   -- global slot
    cfg.colSwing[c]   = { shape = Swing, period = musicalUnit }   -- per column
    cfg.rowPerBeat    : integer                                   -- already exists

`Swing` is serialised as its control-point list. `musicalUnit` is one
of `'beat'`, `'8th'`, `'16th'`, `'bar'`, ... resolved to a PPQ period
against the local tempo map at render time.

A small library of presets lives alongside:

    Swing.id                     -- {(0,0), (1,1)}
    Swing.classic(amount)        -- {(0,0), (0.5, 0.5 + amount), (1,1)}
    Swing.shuffle(amount)        -- triplet-feel parametric family

## Non-goals for v1

- **Full PWL curve editor** for user-defined swing shapes. V1 ships the
  preset family (`id`, `classic`, `shuffle`) and a numeric amount knob.
  The data model supports arbitrary PWL swings; only the UI is deferred.
- **Per-note swing override.** The (`intent`, `delay`) tuple is
  per-note; swing slots are per-column + global. Finer granularity
  would blur the view/realisation line.
- **User-visible tile operation.** Each slot already carries its period;
  tiling is only useful internally if a composition path needs it.
- **Automatic reGrid on swing change.** Swing stays a pure view
  transformation by default; destructive snapping happens only when
  the user asks for it.
