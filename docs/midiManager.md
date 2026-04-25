# midiManager

Abstraction over REAPER's MIDI take API. Provides stable note identity,
per-event metadata that survives save/load, and a batched mutation lock.

## Identity & persistence

Every note carries a UUID (monotonic integer, base-36 encoded as `rdm_<txt>`)
stored as a REAPER **notation event** of the form
`NOTE <chan> <pitch> custom rdm_<base36uuid>`, co-located with the note at the
same ppq. UUIDs give notes an identity independent of REAPER's ordinal indices,
which shift as events are inserted/deleted.

Per-note metadata (anything beyond the standard event fields) is persisted to
the take's **extension data** under two key families:
- `P_EXT:rdm_keys` — comma-separated list of all UUID texts. Loader's entry point.
- `P_EXT:rdm_<uuidTxt>` — `util.serialise`d field table per note.

Stale keys (present in `rdm_keys` but no longer in `uuidTbl`) are cleared by
writing an empty string to their extension slot — REAPER treats this as
deletion.

On load, duplicates, missing UUIDs, and collisions are reconciled:
1. Dedup identical `(ppq, chan, pitch)` notes, keeping the longest.
2. Scan notation events, attach UUIDs to notes via `notesLUT[ppq|chan|pitch]`.
3. Any note with a shared UUID is reassigned a fresh one (metadata cloned);
   any note without a UUID gets a new one and a new notation event.
4. Rescan sysex/text after step 3 because inserting notation events renumbered
   indices — need fresh `uuidIdx` per note plus a clean sweep for non-UUID
   sysex/text events.

## Mutation contract

All write paths (`add*`, `delete*`, `assign*`) must run inside `mm:modify(fn)`.
`modify` disables MIDI sort, runs `fn` under a lock, re-sorts, then reloads
(which fires callbacks). Calling a mutator outside `modify` raises.

**Metadata-only carve-out:** `assignNote(loc, t)` where `t` touches none of
`ppq, endppq, pitch, vel, chan, muted` writes straight to extension data and
skips the lock, the reload, and callbacks. This is the hot path for editor
annotations that don't alter the MIDI stream.

## Callbacks & reload

`fire` is installed via `util.installHooks(mm)`, exposing `addCallback` /
`removeCallback`. On every reload, callbacks run as `fn(changed, mm)` with
`changed = { take = bool, data = bool }`. `data` is always true on reload;
`take` is true only when `load` received a different take than the current one.

## Conventions

- **Channels are 1..16 internally**, offset by +1 from REAPER's 0..15. All
  getters return 1-indexed; all setters shift back on write.
- **Pitchbend is centred on 0**, range -8192..8191. Stored on the wire as
  `(val + 8192)` split LSB/MSB into msg2/msg3.
- **`muted` is true-or-absent**, never stored as `false`. Callers pass
  `muted=false` to clear; `util.REMOVE` is not supported (REAPER-native flag,
  not metadata).
- **Locations are not stable across reloads.** They're 1-indexed snapshots of
  REAPER event order at load time. Don't cache a loc across a `modify`.
- **Accessors return shallow clones** with `idx`/`uuidIdx` stripped
  (`INTERNALS`). Mutating the returned table has no effect — write via
  `assign*`. Never interleave iterators with mutations; collect first.

## CC encoding

REAPER packs CC-family events into `(chanmsg, msg2, msg3)`. `reconstruct()`
fans this out by `msgType`:

| msgType  | msg2           | msg3           |
|----------|----------------|----------------|
| `cc`     | controller     | value          |
| `pa`     | pitch          | value          |
| `pc`/`at`| value          | 0              |
| `pb`     | (val+8192) lo7 | (val+8192) hi7 |

Shape codes follow REAPER's `MIDI_SetCCShape`: `step, linear, slow,
fast-start, fast-end, bezier` → 0..5. `tension` is only meaningful for
`bezier` and is cleared when the shape moves away from it.

## Sysex / text events

`eventTypeLUT` maps names to REAPER's event-type integer
(`sysex=-1, text=1, …, notation=15`). Notation events (type 15) that match the
`rdm_<uuid>` pattern are *not* exposed via `sysexes()` — they belong to their
note. All other notation events are surfaced as `msgType='notation'`.

## LUT discipline

Name→code LUTs are declared canonically; the inverse (`chanMsgTypes`,
`shapeNames`, `textMsgTypes`) is derived in a loop so the two directions can't
drift.

---

## API reference

### Construction & lifecycle

```
newMidiManager(take)     -- load immediately; take may be nil
mm:load(take)            -- (re)initialise from a REAPER take; fires callbacks
mm:reload()              -- reload current take
```

### Callbacks

```
mm:addCallback(fn)       -- fn(changed, mm) on every reload
mm:removeCallback(fn)
```

### Mutation

```
mm:modify(fn)            -- run fn under lock; sort disabled during fn,
                         -- reload (with callbacks) on exit
```

### Notes — location-based, identified internally by UUID

```
mm:getNote(loc)          -> copy of note, or nil
mm:notes()               -> iterator: for loc, note in mm:notes() do
mm:addNote(t)            -> new loc
  t: { ppq, endppq, chan, pitch, vel, [muted], [<metadata...>] }  (required fields mandatory)
mm:assignNote(loc, t)    -- merge t into note
  event fields: ppq, endppq, chan, pitch, vel, muted
  metadata fields: anything else — set to util.REMOVE to delete
  touching any event field triggers a REAPER write; pure-metadata calls skip the lock
mm:deleteNote(loc)       -- also removes the associated notation event
```

### CCs — location-based

```
mm:getCC(loc)            -> copy, or nil
mm:ccs()                 -> iterator
mm:addCC(t)              -> new loc
  t: { ppq, chan, val, [msgType='cc'], [cc], [pitch], [shape='step'], [tension], [muted] }
  val/cc/pitch interpreted per msgType (see "CC encoding" table)
  shape ∈ {step, linear, slow, fast-start, fast-end, bezier}; tension ∈ [-1,1], bezier only
mm:assignCC(loc, t)      -- merge t into CC; msgType change re-encodes msg2/msg3
mm:deleteCC(loc)
```

### Sysex / text — location-based

```
mm:getSysex(loc)         -> copy, or nil
mm:sysexes()             -> iterator
mm:addSysex(t)           -> new loc
  t: { ppq, msgType, val }
  msgType ∈ {sysex, text, copyright, trackname, instrument, lyric,
             marker, cuepoint, notation}
mm:assignSysex(loc, t)
mm:deleteSysex(loc)
```

### Take data

```
mm:take()                -> current REAPER take (read-only)
mm:resolution()          -> PPQ per quarter note
mm:length()              -> take length in PPQ, ignoring item looping
mm:timeSigs()            -> array of { ppq, num, denom } in take-relative ppq
                         -- entry 1 is synthetic at ppq=0, carrying the time sig
                         --   in force at the take's start (from prior marker or
                         --   TimeMap_GetTimeSigAtTime fallback)
                         -- subsequent entries are markers strictly inside the take
                         -- tempo-only markers (num==0) are skipped
```

### Interpolation

```
mm:interpolate(A, B, ppq) -> val at ppq between scalar events A and B
```

Uses the shape/tension carried on A (REAPER convention: a point's shape
governs the curve from that point to the next). Returns `A.val` for
`step` / no-shape / zero-span pairs. Shape evaluation uses the standard
REAPER codes (`linear`, `slow`, `fast-start`, `fast-end`) plus a
recovered cubic-Bézier handle table indexed by tension ∈ [-1, 1].

Pure function of its arguments — no take state touched.
