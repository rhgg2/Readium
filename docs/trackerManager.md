# trackerManager

Parses a midiManager's MIDI stream into tracker-style channels with typed
columns, resolves microtuning and timing (swing + per-note delay), and
exposes a batched mutation interface that writes back to mm. Rebuilds
automatically whenever mm or cm fires.

## Channel & column model

16 channels, one per MIDI channel. Each channel carries a `columns` table:

| kind     | shape                                  | source                    |
|----------|----------------------------------------|---------------------------|
| `notes`  | dense array, index = lane              | mm notes (lane in metadata) |
| `pb`     | singleton column or nil                | mm cc, msgType=`pb`       |
| `pc`     | singleton column or nil                | mm cc, msgType=`pc`       |
| `at`     | singleton column or nil                | mm cc, msgType=`at`       |
| `ccs`    | sparse dict keyed by CC number         | mm cc, msgType=`cc`       |

Every column has `events` (array sorted by **intent** ppq). `cc` columns
additionally carry `cc` (the controller number). Presentation order is a
vm concern — tm imposes none.

Poly-aftertouch (`pa`) events do **not** get their own column. They
attach to the note column whose voice they modulate (see *PA binding*
below), appearing as `{ type='pa', pitch, vel, ppq }` entries mixed into
that column's `events`.

## Lane identity

Note columns carry no identity beyond their position among note columns
in the channel. A note's "lane" is that position, persisted per note
under the `lane` key. Lane counts are stable across rebuilds via
`cfg.extraColumns[chan].notes`, a per-channel high-water mark:

- rebuild grows it when live allocation exceeds it;
- lanes only shrink via explicit user action in vm.

`extraColumns` is also the single source of "columns the user has opened
per channel" — columns present in extras but not backed by events are
materialised as empty, so consumers see a uniform `channel.columns`
irrespective of whether a column is data-driven or user-opened.

```
extraColumns[chan] = {
  notes = <count>,
  pc = true, pb = true, at = true,
  ccs = { [ccNum] = true },
}
```

## Update manager (um)

tm's private write-side object. All mutations — from vm and from tm's
own rebuild-time housekeeping — funnel through `um`, which applies them
to a local cache and accumulates mm-facing ops. `um:flush()` commits the
batch in one `mm:modify` call. `um` is re-created once per rebuild, so
its view of mm matches tm's own.

The sections below reference `um` by name because its frame and
encoding choices (cents not raw, realised not intent) are the reason
several conventions exist.

## Pitchbend: raw, logical, detune

**Detune** is a per-note metadata field (signed cents) carried only by
**col-1 notes** — i.e. notes in lane 1, the first note column of the
channel. Pb is a channel-wide stream, so only one note column per
channel can drive microtuning; by convention that is lane 1. Higher
lanes inherit whatever pb is in force.

Two views of the same pb stream coexist:

- **Raw** is what REAPER stores: signed -8192..8191, centred on 0.
- **Logical** is what the musician authored: cents relative to
  prevailing detune. `logical = raw − detune(chan, ppq)`, where
  `detune(chan, ppq)` is the detune of the latest col-1 note starting
  at or before `ppq` (0 if none).

Inside `um`, `pb.val` is **always cents**; conversion to raw happens
only on load (`rawToCents`) and at flush (`centsToRaw`). The cents
window is `cm:get('pbRange') * 100` per side.

**Fake pb (detune absorber).** When a col-1 note's `detune` differs
from prevailing `detune` just before it, a pb must seat at the note
boundary to absorb the raw step while keeping the logical stream
unchanged. That pb is tagged `fake=true` (persisted as cc metadata via
`mm:assignCC` / `mm:addCC`'s lazy-sidecar path). Fake pbs are hidden
from the pb column unless an interp shape pulls them into view
(`hidden = cc.fake and (shape==nil or 'step')`); the host note for
delay inheritance is just the col-1 note at exactly `cc.ppq` whenever
`cc.fake` is set.

`markFake` / `unmarkFake` toggle the pb's `fake` flag. The host note
carries no marker — it's recovered geometrically.

## Intent vs realised frame

**Delay** is a per-note metadata field (signed milli-QN, defaulted to
0) that nudges only the note-on off its nominal ppq. The note-off
stays at intent. This creates two views of the note's onset:

- **Intent ppq** is where the note nominally sits (the musician's
  authored position, and what vm renders).
- **Realised ppq** is where mm stores the note-on (intent plus the
  delay offset).

`endppq` is intent in both views — it never carries the delay
offset. A positive delay therefore shrinks the realised duration by
exactly `delayToPPQ(delay)`; a negative delay extends it. This is
classical tracker semantics (sub-row note-on nudge).

vm speaks intent; mm and `um` internals speak realised. The invariant:

```
realised.ppq    = intent.ppq + delayToPPQ(delay)
realised.endppq = intent.endppq                      -- delay does not shift the end
```

is maintained at the vm boundary:

- `tm:rebuild` strips delay from `ppq` via `tidyCol` before exposing
  events (intent frame out). `endppq` is left alone — already intent.
- `um:addEvent` / `um:assignEvent` add delay back to `ppq` before
  routing writes to mm (realised frame in). `endppq` passes through.

A delay change with no ppq update pins intent and shifts realised
onset by the delta (`realiseNoteUpdate`). Ppq comparisons inside
rebuild run in the realised frame — `tidyCol` is the sole shift into
intent.

Fake pbs inherit their host note's `delay` at rebuild time so
`tidyCol` shifts both into intent frame together. Without this, a
delayed note and its absorber would desynchronise at the vm boundary.

## Swing

tm is only a registry here: `cfg.swing` (global) and `cfg.colSwing[c]`
(per column) hold slot names referring into `cfg.swings`. The semantics
— what a slot *is*, how factors compose, how apply/unapply work — live
in `timing.lua` and `design/swing.md`.

`tm:swingSnapshot(override)` hands callers a frozen view of the
currently registered swing with `apply`/`unapply` closures ready to
use. Pass `override` to substitute alternative slot names or shadow the
library (preset edits need the authoring and target composites for the
same name side-by-side).

## Mutation contract

Edits enter tm through the four methods below, which delegate to `um`.
Never reach around them to mm directly. Because `um` is rebuilt each
rebuild, **don't cache `loc` values across a flush** — their validity
ends there.

```
tm:addEvent(type, evt)               -- local apply + stage add
tm:assignEvent(type, evt, upd, opts) -- local apply + stage assign
tm:deleteEvent(type, evt)            -- local apply + stage delete
tm:flush()                           -- commit staged ops in one mm:modify
```

Semantics:

- **Rejected updates.** Changing a note's `chan` or `lane` via
  `assignEvent` is rejected (prints a warning and drops the call).
- **Single voice per (chan, pitch).** `clearSameKeyRange` truncates or
  deletes overlapping same-key notes around any add or move. Matches
  the post-hoc normalisation rebuild runs for foreign MIDI, so callers
  don't have to think about cross-column collisions. A caller staging
  a coherent monotone batch (where the end-state has no new same-key
  overlaps) can pass `opts.trustGeometry` on `assignEvent` to skip the
  per-write clamp; rebuild's group-by-pitch pass is the backstop.
  Reswing uses this — without it, the first-processed of two legato
  siblings sees its endppq clipped against the second's still-old ppq.
- **Detune changes (col-1 notes).** `assignNote` seats a pb at the
  boundary if needed, retunes the raw stream forward to the next note,
  then drops the boundary if it became redundant.
- **PA follows host.** Resizing or moving a note shifts attached PAs
  with it when the shift preserves the window; otherwise PAs outside
  the new window are deleted and the last trimmed PA's value becomes
  the note's `vel`.
- **Fake-pb housekeeping.** `addPb` unmarks fake on the affected
  boundary; `deletePb` either really deletes or re-marks fake
  depending on whether detune and neighbour detune agree.
- **Flush re-entrancy.** `flush` snapshots and clears `adds/assigns/
  deletes` **before** calling `mm:modify`, because mm's callbacks can
  reach back into the same um (e.g. via `setMutedChannels`). Without
  the up-front clear, in-flight ops would be re-emitted.

## Rebuild

Triggered by:
- mm `'reload'` signal — always rebuilds. The take-swap flag travels via
  the separate mm `'takeSwapped'` signal, captured into a transient flag
  and consumed by the next reload (mm guarantees the firing order);
- cm `'configChanged'` signal, except for `vmOnlyKeys` (`mutedChannels`,
  `soloedChannels`) which do not touch tm's structural view.

tm also forwards the reconciliation signals it receives from mm
(`takeSwapped`, `notesDeduped`, `uuidsReassigned`) to its own subscribers,
so layers above tm needn't reach into mm.

Reentrancy-guarded by `rebuilding`. Steps:

1. **Seed + normalise notes.** Walk mm notes once. Any note lacking
   `detune`/`delay` is seeded with `0` via metadata-only `assignNote`
   (no lock). Build `(chan,pitch)` groups, then truncate overlaps
   under a single `mm:modify` so every subsequent walk sees clean
   intervals.
2. **Allocate lanes.** `allocateNoteColumn` prefers the persisted
   `note.lane`; falls through to first-fit, then spills to a new
   column. If the preferred lane doesn't exist yet, columns are pushed
   until it does. Lane changes write back via `mm:assignNote`.
3. **Single CC walk.** Distributes by `msgType`:
   - `pb` — emit logical-cents events with detune context and hidden
     flag; accumulate per channel so the column installs only when at
     least one event is visible.
   - `pa` — attach to note column containing `(pitch, ppq)`.
   - `cc` — append to `ccs[cc]`.
   - `at` / `pc` — append to the channel's singleton column.
4. **Reconcile extras.** Grow `extraColumns[chan].notes` if live
   allocation exceeded it; pad empty note lanes; materialise
   user-opened singletons/ccs that carry no events. Writes back via
   `cm:set` if the high-water mark grew.
5. **tidyCol.** Strip delay into intent frame and sort each column's
   events by intent ppq.

Then `um = createUpdateManager()` and tm fires the `'rebuild'` signal
(no payload).

## Column allocation rules

`noteColumnAccepts(col, ppq, endppq)`:

- same start tick as any existing note ⇒ reject (always spill);
- overlap amount > `cm:get('overlapOffset') * resolution` with any
  single existing note ⇒ reject;
- two or more existing notes overlap this one ⇒ reject.

Otherwise the column accepts.

## PA binding

`findNoteColumnForPitch(chan, pitch, ppq)` prefers the **active voice**
— a note whose interval contains `ppq` with matching pitch. If no voice
is active, any column containing any note of that pitch accepts. PAs
with no matching pitch anywhere in the channel are dropped.

## Muting

vm owns the effective mute set (persistent mute ∪ solo-implied mute)
and pushes it via `tm:setMutedChannels(set)`. tm:

- stores it in `lastMuteSet` (used to tag later-added notes in um);
- idempotently syncs REAPER's native muted flag on every existing note
  through `um:assignEvent`, then flushes.

Mute state is a vm-side concern — it **does not** trigger a structural
rebuild (see `vmOnlyKeys`).

## Conventions

- **Channels 1..16**, inherited from mm.
- **Ppq throughout.** Intent frame at the vm boundary, realised frame
  inside um and toward mm. `timing.delayToPPQ` is the sole converter.
- **pb.val in cents** inside tm; raw conversion only at load and flush.
- **Fake pb flag.** `pb.fake` is the sole marker (persisted as cc
  metadata); always toggle through `markFake`/`unmarkFake`.
- **`util.REMOVE`** as a value in `assignEvent` deletes the field
  (passed through to mm).
- **Location lifetime.** `loc` values are valid only within a single
  rebuild-to-flush window; um's `notesByLoc` / `ccsByLoc` are rebuilt
  fresh each rebuild.

---

## API reference

### Construction & lifecycle

```
newTrackerManager(mm, cm)   -- wires callbacks on mm/cm and rebuilds
tm:rebuild(takeChanged)     -- manual rebuild; takeChanged defaults to false
```

### Signals

```
'takeSwapped'      data = nil                       -- forwarded from mm
'notesDeduped'     data = { events = [...] }        -- forwarded from mm
'uuidsReassigned'  data = { events = [...] }        -- forwarded from mm
'rebuild'          data = nil                       -- fires at end of every rebuild
```

```
tm:subscribe(signal, fn)         -- fn(data) on each fire
tm:unsubscribe(signal, fn)
```

See `docs/midiManager.md` for the reconciliation signal payload shapes.

### Channel data

```
tm:getChannel(chan)         -> channel table, or nil
tm:channels()               -> iterator: for chan, channel in tm:channels()
```

Channel shape:
```
{
  chan    = 1..16,
  columns = {
    notes = { <col>, <col>, ... },       -- dense, index = lane
    ccs   = { [ccNum] = <col>, ... },    -- sparse
    pc    = <col> | nil,
    pb    = <col> | nil,
    at    = <col> | nil,
  },
}
```

Column shape: `{ events = { ... }, [cc = <ccNum>] }`. Events are sorted
by intent ppq.

### Global data

```
tm:length()                 -> take length in PPQ
tm:resolution()             -> PPQ per quarter note
tm:timeSigs()               -> array of { ppq, num, denom }
tm:editCursor()             -> edit cursor in take-relative PPQ
tm:interpolate(A, B, ppq)   -> passthrough to mm:interpolate; value at ppq
                               between scalar events A and B, using A's
                               shape / tension
```

### Swing

```
tm:swingSnapshot(override)  -> {
  global,                   -- resolved factor array or nil
  column,                   -- { [chan] = factor array or nil }
  apply(chan, ppq)   -> ppq,
  unapply(chan, ppq) -> ppq,
}
```

`override` (optional): `{ swing=name, colSwing={[c]=name} }`. Omit to read from cm.

### Mutation

```
tm:addEvent(evtType, evt)
tm:assignEvent(evtType, evtOrLoc, update, opts)
tm:deleteEvent(evtType, evtOrLoc)
tm:flush()                  -- no-op if nothing staged
```

`evtType` ∈ `{note, pb, cc, pa, at, pc, sysex, text, ...}`. `note` and
`pb` go through high-level ops (detune bookkeeping, same-key clearing,
fake-pb housekeeping); other types pass through as low-level
add/assign/delete on mm.

Event fields accepted on `addEvent('note', evt)`:
`{ ppq, endppq, chan, pitch, vel, [lane=1], [detune=0], [delay=0], [muted], [<metadata...>] }`.

Event fields accepted on `addEvent('pb', evt)`:
`{ ppq, chan, val (cents), [shape], [tension] }`.

`evt.frame` and `evt.straightPPQ` (and `evt.straightEndPPQ` for
notes), when supplied by the caller, pass through as sidecar metadata
at the mm layer. tm itself never inspects or fills them — their
semantics live entirely in vm. Callers that want a frame on an
authored event must stamp it themselves before calling `addEvent`.
Delay nudges shift `ppq` / `endppq` only — `straightPPQ` is
delay-independent and rides through unchanged.

Update values may include `util.REMOVE` to delete the field.

### Mute

```
tm:setMutedChannels(set)    -- set = { [chan] = true }; pushed by vm,
                            -- idempotently syncs mm note.muted and
                            -- tags later-added notes
```

### Transport

```
tm:play()                   -- REAPER Main 1007
tm:stop()                   -- REAPER Main 1016
tm:playPause()              -- REAPER Main 40073
tm:playFrom(ppq)            -- seek edit cursor to ppq, then play
```
