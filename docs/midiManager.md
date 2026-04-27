# midiManager

Abstraction over REAPER's MIDI take API. Provides stable per-event identity
(notes and ccs), per-event metadata that survives save/load, and a batched
mutation lock.

## Identity & persistence

Every uuid'd event has a metadata blob in **take extension data** under
two key families:
- `P_EXT:rdm_keys` — comma-separated list of all UUID texts. Loader's entry point.
- `P_EXT:rdm_<uuidTxt>` — `util.serialise`d field table per event.

Stale keys (present in `rdm_keys` but no longer in `uuidTbl`) are cleared by
writing an empty string to their extension slot — REAPER treats this as
deletion. UUIDs are monotonic integers, base-36 encoded; the namespace is
unified across notes and ccs.

### Notes — notation-event carrier

Every note carries a UUID stored as a REAPER **notation event**
`NOTE <chan> <pitch> custom rdm_<base36uuid>`, co-located with the note at
the same ppq. UUIDs are universal: every note gets one on load whether or not
it carries metadata.

On load, duplicates, missing UUIDs, and collisions are reconciled:
1. Dedup identical `(ppq, chan, pitch)` notes, keeping the longest.
2. Scan notation events, attach UUIDs to notes via `notesLUT[ppq|chan|pitch]`.
3. Any note with a shared UUID is reassigned a fresh one (metadata cloned);
   any note without a UUID gets a new one and a new notation event.
4. Rescan sysex/text after step 3 because inserting notation events renumbered
   indices — need fresh `uuidIdx` per note plus a clean sweep for non-UUID
   sysex/text events.

### CCs — sidecar-sysex carrier (sidecar-on-touch)

CCs (and the cc-family events `pa`/`pb`/`pc`/`at`) acquire a UUID **only when
metadata is written**. Plain automation streams stay free of overhead until
Readium touches them.

The carrier is a coincident sysex with a Readium magic prefix
(`F0 7D 52 44 4D ... F7` on disk; `7D 52 44 4D ...` body when handled via
`MIDI_*TextSysexEvt(... type=-1 ...)` — REAPER frames it). The body encodes
`(uuid, msgType, chan, [cc|pitch], val)` so the carrier can re-bind to its
event at load time even after drift.

Sidecars sit alongside ordinary sysex; mm filters them out of `sysexes()` by
prefix the same way `rdm_<uuid>` notation events are filtered for notes.

**Reconciliation (load-time).** Phase 1 implements **tier 1** only: bind by
exact `(ppq, msgType, chan, id, val)` fingerprint match. Anything that drifts
is silently parked unbound for now. Tiers 2–4 (value-drift, consensus offset,
per-orphan resolution) and the `ccsReconciled` signal are planned for the
follow-up phase, along with cc dedup.

After tier-1 binding the bound cc gets `uuid` and `uuidIdx` (the sysex index
of its sidecar); metadata from `rdm_<uuid>` is merged onto the cc just like
for notes.

## Mutation contract

All write paths (`add*`, `delete*`, `assign*`) must run inside `mm:modify(fn)`.
`modify` disables MIDI sort, runs `fn` under a lock, re-sorts, then reloads
(which fires callbacks). Calling a mutator outside `modify` raises.

**Metadata-only carve-out** (parallel for notes and stamped ccs):
- `assignNote(loc, t)` where `t` touches none of `ppq, endppq, pitch, vel,
  chan, muted` writes straight to extension data and skips the lock.
- `assignCC(loc, t)` where `t` touches none of `ppq, msgType, chan, cc, pitch,
  val, muted, shape, tension` *and* the cc already carries a uuid does the
  same. The "already carries a uuid" condition matters: the **first** metadata
  stamp on a plain cc inserts a sidecar sysex, which is a structural mutation
  and so requires the lock.

A structural assignCC on a uuid'd cc also rewrites the sidecar's position and
fingerprint bytes so the next load is tier-1 clean. `deleteCC` removes the
sidecar alongside the event.

## Signals

mm fires up to four kinds of signal per `load`. Subscribers register per
kind and receive only the payloads of that kind.

```
'takeSwapped'      data = nil                                -- only when load received a different take
'notesDeduped'     data = { events = [{ ppq, chan, pitch, droppedCount }, ...] }
'uuidsReassigned'  data = { events = [{ oldUuid, newUuid, ppq, chan, pitch }, ...] }
'reload'           data = nil                                -- every load
```

Firing rules:
- `takeSwapped` fires before any reconciliation signals; `reload` fires
  last. Subscribers handling reconciliation see the events before the
  baseline rebuild.
- Reconciliation signals fire only when at least one event of that kind
  is present — no zero-event calls.
- `mm:modify` triggers a reload internally on exit, so every successful
  mutation produces a `'reload'` fire (with no `takeSwapped`).

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
(`sysex=-1, text=1, …, notation=15`). Two filters keep Readium's identity
machinery from leaking into `sysexes()`:
- Notation events (type 15) matching the `rdm_<uuid>` pattern belong to their
  note and are hidden.
- Sysex events (type -1) whose body starts with the Readium magic
  (`}RDM`, `7D 52 44 4D`) are cc sidecars and are hidden.

All other notation events surface as `msgType='notation'`; everything else
keeps its `eventTypeLUT` name.

## LUT discipline

Name→code LUTs are declared canonically; the inverse (`chanMsgTypes`,
`shapeNames`, `textMsgTypes`) is derived in a loop so the two directions can't
drift. `chanMsgLUT`, `BASE36`/`toBase36`/`fromBase36`, and `SIDECAR_MAGIC` are
hoisted to module scope so `newMidiManager` and `newSidecarReconciler` share
one source of truth.

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
mm:subscribe(signal, fn)           -- fn(data) on each fire of `signal`
mm:unsubscribe(signal, fn)
```

Signals: `'takeSwapped'`, `'notesDeduped'`, `'uuidsReassigned'`, `'reload'`.
See **Signals** above for the per-signal payload shapes and firing order.

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

### CCs — location-based, sidecar-on-touch UUID

```
mm:getCC(loc)            -> copy, or nil
mm:ccs()                 -> iterator
mm:addCC(t)              -> new loc
  t: { ppq, chan, val, [msgType='cc'], [cc], [pitch], [shape='step'], [tension], [muted] }
  val/cc/pitch interpreted per msgType (see "CC encoding" table)
  shape ∈ {step, linear, slow, fast-start, fast-end, bezier}; tension ∈ [-1,1], bezier only
mm:assignCC(loc, t)      -- merge t into CC
  event fields: ppq, msgType, chan, cc, pitch, val, muted, shape, tension
  metadata fields: anything else — set to util.REMOVE to delete
  pure-metadata + uuid present -> skip lock; pure-metadata + no uuid yet
    -> still requires lock (allocates a uuid + inserts a sidecar)
  any event-field change rewrites the sidecar fingerprint, and a ppq change
    moves the sidecar so next load is tier-1 clean
mm:deleteCC(loc)         -- also removes the sidecar and clears the rdm_<uuid> slot
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

---

## newSidecarReconciler — sidecar codec + binding

A second factory in the same file. Pure over its args; held as a factory
both for symmetry with `newMidiManager` and so specs can construct one
without REAPER state.

```
newSidecarReconciler() -> sr
sr:magic()             -> 4-byte string '}RDM' (filter prefix)
sr:encode(cc)          -> 11+-byte body, or nil for unknown msgType
  cc: { uuid, msgType, chan, [cc | pitch], val }
  body sans F0/F7 framing — pass straight to MIDI_InsertTextSysexEvt(...
    type=-1 ...). chan is 1..16; val is signed for pb, 7-bit otherwise.
sr:decode(body)        -> cc-shaped record, or nil
  Returns { uuid, msgType, chan, val } plus `cc` for msgType='cc' or
    `pitch` for msgType='pa'. Same shape encode accepts.
sr:tier1(sidecars, ccs) -> { binds = [{sidecarIdx, ccIdx}, ...],
                              unboundSidecarIdxs, unboundCcIdxs }
  Both inputs are 1-indexed arrays of cc-shaped records (sidecars are
  decode output + sysex ppq). Binds by exact (ppq, msgType, chan, id, val)
  match; a cc is claimed at most once. Unbound entries park for higher
  tiers (not yet implemented).
```

**Wire format.** `}RDM <typeNib> <chan> <id> <val_lo7> <val_hi7> <uuid-base36>`
where `typeNib` is the chanmsg high nibble (0xA..0xE) and `id` is the
controller for cc, pitch for pa, 0 for pb/pc/at. REAPER frames with
`F0`/`F7` on serialise.
