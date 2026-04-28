# midiManager

Abstraction over REAPER's MIDI take API. Provides stable per-event identity
(notes and ccs), per-event metadata that survives save/load, and a batched
mutation lock.

## Identity & persistence

Every uuid'd event has a metadata blob in **take extension data** under
two key families:
- `P_EXT:rdm_keys` — comma-separated list of all UUID texts. Loader's entry point.
- `P_EXT:rdm_<uuidTxt>` — `util.serialise`d field table per event.

Stale keys (present in `rdm_keys` but no longer in `uuids`) are cleared by
writing an empty string to their extension slot — REAPER treats this as
deletion. UUIDs are monotonic integers, base-36 encoded; the namespace is
unified across notes and ccs.

### Notes — notation-event carrier

Every note carries a UUID stored as a REAPER **notation event**
`NOTE <chan> <pitch> custom rdm_<base36uuid>`, co-located with the note at
the same ppq. UUIDs are universal: every note gets one on load whether or not
it carries metadata.

On load, duplicates, missing UUIDs, and collisions are reconciled:
1. Dedup identical `(ppq, chan, pitch)` notes, keeping the longest. Losers are
   flushed before sysex is read so their cascade-deleted notation events don't
   leave us holding stale text/sysex idxs.
2. Scan notation events into `noteSidecars` and bind to notes by tag; the first
   notation event at a tag claims its note (`note.uuid`, `note.uuidIdx`).
3. Any note with a shared UUID is reassigned a fresh one (metadata cloned);
   any note without a UUID gets a new one and a queued notation-event insert.
   Notation events that didn't claim a note (no surviving note at that tag, or
   a duplicate at a tag already claimed) are queued for deletion.
4. All sysex mutations — set/delete/insert — flush in a single bracketed pass
   alongside the cc dedup deletes and reconcile rewrites. A closing read pass
   refreshes `idx` and `uuidIdx` on the surviving entries.

### CCs — sidecar-sysex carrier (sidecar-on-touch)

CCs (and the cc-family events `pa`/`pb`/`pc`/`at`) acquire a UUID **only when
metadata is written**. Plain automation streams stay free of overhead until
Readium touches them.

The carrier is a coincident sysex with a Readium magic prefix
(`F0 7D 52 44 4D ... F7` on disk; `7D 52 44 4D ...` body when handled via
`MIDI_*TextSysexEvt(... type=-1 ...)` — REAPER frames it). The body encodes
`(uuid, msgType, chan, [cc|pitch], val)` so the carrier can re-bind to its
event at load time even after drift.

Sidecars sit alongside ordinary sysex but are routed to an internal
`sidecars` table during load — Readium only surfaces notes and CCs to its
upper layers, so plain sysex/text events have no public accessors.

**Reconciliation (load-time).** Sidecars don't have a REAPER-side anchor to
their target the way notation events have to notes, so matching has to handle
drift. The reconcile pass runs four stages, each rebucketing the still-unbound
sidecars and ccs by a key chosen for that stage's notion of "same" — finer
early, coarser late. A uuid can't migrate to a different controller, so
`(msgType, chan, id)` is always part of the key. Bound pairs are spliced
out of the working sets so the next stage's buckets are automatically
clean. Bias is to keep metadata attached to *something* and route
uncertainty via the `ccsReconciled` signal — silent loss is worse than a
flagged guess.

1. **Stage 1 — exact.** Bucket by `(msgType, chan, id, ppq, val)` and
   pair off. Catches everything that moved as a unit (glue, item shift).
   Silent — bind only, no event and no sidecar rewrite.
2. **Stage 2 — value-drifted.** Bucket by `(msgType, chan, id, ppq)` and
   pair off; val may differ. Catches an external value-edit that didn't
   move the cc. Emits `valueRebound` with `oldVal`/`newVal`.
3. **Stage 3 — consensus offset.** Bucket by `(msgType, chan, id)`.
   Histogram offsets implied by every (sidecar, candidate) pair. If a unique top
   vote-getter passes the threshold (≥ 50% of bucket sidecars, minimum 2
   voters), apply that offset across the bucket. Emits `consensusRebound`
   per bind. Catches the common "user dragged a group of ccs in REAPER's
   editor" case (selection is per-event-type, so sidecars stay behind while
   ccs move uniformly).
4. **Stage 4 — per-orphan.** For each remaining sidecar, count candidates
   left in its bucket: 0 → `orphaned`, 1 → `guessedRebound`, ≥2 →
   `ambiguous`. Multi-candidate ambiguity drops the metadata rather than
   guessing — better to surface a flagged loss than attach metadata to a
   provably-wrong event.

After binding the bound cc gets `uuid` and `uuidIdx` (the sysex index of its
sidecar); metadata from `rdm_<uuid>` is merged onto the cc just like for
notes. Non-silent binds (stages 2-4) also rewrite the sidecar's ppq + body
so the next load is stage-1 silent. Sidecars unbound after reconcile
(orphaned / ambiguous) are deleted from the take and their `rdm_<uuid>`
ext-data is purged by the stale-key sweep.

**Dedup (pre-reconciliation).** ccs are dedup'd by `(ppq, chan, msgType,
id)`. Survivor in each group is picked to match what reconciliation will
do next:

1. **Prefer stage-1 candidates.** A cc is a stage-1 candidate if some
   sidecar exists in the same `(msgType, chan, id)` bucket at the same
   ppq with matching val — i.e. the reconciler would bind to it silently.
   If any group member is a candidate, the survivor comes from that
   subset.
2. **Tiebreak by highest loc.** Within the preferred subset (or the whole
   group if no candidates), the latest-loc cc wins.

Sidecars are not touched at this stage. A sidecar whose preferred cc has
just been dropped — or that never had one — flows through reconciliation
as a `valueRebound` / `consensusRebound` / `guessedRebound` / `ambiguous`
/ `orphaned` event, and the post-reconcile cleanup deletes orphan
sidecars. The stale-key sweep in `saveMetadata` purges any
`rdm_<uuid>` ext-data left behind. Emits `ccsDeduped` with one event per
group; running before reconciliation means dedup has no uuid attachments
to report, so the event no longer carries `keptHadUuid`.

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
fingerprint bytes so the next load is stage-1 clean. `deleteCC` removes the
sidecar alongside the event.

`addCC(t)` mirrors the lazy-sidecar pattern: if `t` carries any non-structural
key it allocates a uuid + inserts a sidecar in the same shot. Plain ccs
(no metadata) skip the allocation entirely. Symmetric with `addNote`'s
unconditional uuid, but lazy — most ccs never need one.

## Signals

mm fires up to six kinds of signal per `load`. Subscribers register per
kind and receive only the payloads of that kind.

```
'takeSwapped'      data = nil                                -- only when load received a different take
'notesDeduped'     data = { events = [{ ppq, chan, pitch, droppedCount }, ...] }
'uuidsReassigned'  data = { events = [{ oldUuid, newUuid, ppq, chan, pitch }, ...] }
'ccsReconciled'    data = { events = [...] }                 -- omnibus: see below
'ccsDeduped'       data = { events = [{ ppq, chan, msgType, cc, pitch, droppedCount }, ...] }
'reload'           data = nil                                -- every load
```

`ccsReconciled` events come in five kinds. The shared fields are `kind`,
`uuid`, `chan`, `msgType`, and (per msgType) `cc` or `pitch`. Per-kind extras:

```
{ kind = 'valueRebound',     ppq,     oldVal, newVal }   -- stage 2
{ kind = 'consensusRebound', ppq,     offset }           -- stage 3
{ kind = 'guessedRebound',   ppq }                       -- stage 4
{ kind = 'ambiguous',        candidatePpqs = {...} }     -- stage 4 (no bind)
{ kind = 'orphaned',         lastPpq }                   -- stage 4 (no bind)
```

`ppq` on the rebind kinds is the bound cc's ppq (where the metadata now
lives). `lastPpq` on `orphaned` is the sidecar's own ppq (where the cc
*was*); orphaned/ambiguous events have no bound cc to point at. A
subscriber that wants only the data-loss subset filters on
`kind == 'orphaned' or 'ambiguous'`.

Firing rules:
- Order on a single load is `takeSwapped` → `notesDeduped` →
  `uuidsReassigned` → `ccsDeduped` → `ccsReconciled` → `reload`.
  Subscribers handling reconciliation/dedup see the events before the
  baseline rebuild. `ccsDeduped` precedes `ccsReconciled` because the
  reconciler runs over an already-deduped cc list — orphans (sidecars
  whose preferred cc was just dropped) surface as proper reconcile
  events rather than silent dedup losses.
- Reconciliation/dedup signals fire only when at least one event of that
  kind is present — no zero-event calls.
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

## Text / sysex events

Readium reads two text-event types and ignores the rest:
- Notation events (REAPER type 15) matching the `rdm_<uuid>` pattern bind
  to their note via `note.uuidIdx`.
- Sysex events (REAPER type -1) whose body starts with the Readium magic
  (`}RDM`, `7D 52 44 4D`) are cc sidecars and feed the `sidecars` table.

Everything else passes through untouched — Readium neither surfaces nor
mutates plain sysex/text events.

## LUT discipline

Name→code LUTs are declared canonically; the inverse (`chanMsgTypes`,
`shapeNames`) is derived in a loop so the two directions can't drift.
`chanMsgLUT` and `BASE36`/`toBase36`/`fromBase36` are hoisted to module
scope so they're shared across helpers without drift.

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

Signals: `'takeSwapped'`, `'notesDeduped'`, `'uuidsReassigned'`,
`'ccsDeduped'`, `'ccsReconciled'`, `'reload'`. See **Signals** above for
the per-signal payload shapes and firing order.

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

## Sidecar wire format

`}RDM <typeNib> <chan> <id> <val_lo7> <val_hi7> <uuid-base36>` where
`typeNib` is the chanmsg high nibble (0xA..0xE) and `id` is the controller
for cc, pitch for pa, 0 for pb/pc/at. REAPER frames with `F0`/`F7` on
serialise. Encode/decode live as private closures inside `newMidiManager`;
reconcile is a `do`-block in `mm:load`.
