# midiManager `load` rewrite

## Goal

Replace the current intricate `mm:load` (multiple read passes, two `scanText()`
re-reads after mid-load mutations, `rewireCcSysexIdxs`) with a flow that:

- reads each REAPER stream once during the in-memory phase,
- does dedup / UUID unification / reconcile on in-memory tables,
- queues all REAPER mutations and flushes them in idx-safe order,
- does one closing read pass to refresh `idx` / `uuidIdx` on the surviving entries.

In-memory tables (`notes`, `ccs`, `ccSidecars`) start dense, become sparse as
losers / orphans are nil'd, then are compacted at the end.

## Renames already done (pre-rewrite)

The closure-locals in `newMidiManager` have been renamed:

- `noteTbl` → `notes`
- `ccTbl` → `ccs`
- `sidecarTbl` → `ccSidecars`
- `uuidTbl` → `uuids`

`sr:reconcile`'s parameter is still called `sidecars` — it's an independent
function whose API is generic over its args. Its return field
`unboundSidecars` is unchanged.

## Key constraints driving the structure

1. **`MIDI_DeleteNote` cascade-deletes the note's notation text event.**
   This means note deletes shift text/sysex idxs. We can't read sysex first
   and then delete notes — held sysex idxs would go stale.

2. **`MIDI_DeleteCC` does not cascade.** CC and text/sysex idx spaces are
   independent.

3. **CC dedup needs sidecar info** (stage-1 preference: a cc whose
   `(ppq, val)` matches some sidecar in the same `(msgType, chan, id)` bucket
   is preferred as the survivor). So sidecars must be read before CC dedup.

4. **All deletes must be flushed batched, descending idx.** No
   delete-as-you-go — capture idxs from the read, queue, sort descending, then
   flush under one `MIDI_DisableSort` / `MIDI_Sort` bracket.

The combination of (1) and (3) forces a split read: notes first, dedup notes,
then read ccs + sysex. Two read phases before the in-memory passes, plus the
closing refresh read. Still a big win over today's three reads + two
`scanText()` re-reads.

## Step-by-step

### 1. Reset state

```lua
notes, ccs, ccSidecars, uuids, maxUUID, lock = {}, {}, {}, {}, 0, false
```

### 2. Read notes

Single sweep into `notes` (dense). Each entry:

```
{ idx, ppq, endppq, chan, pitch, vel, [muted] }
```

### 3. Note dedup → flush

Group `notes` by `(ppq, chan, pitch)`. Longest `endppq` wins.

- Nil losers in `notes`, queue `noteDeletes` (idxs).
- Build `notesByTag[ppq|chan|pitch] = winner`.
- Flush `noteDeletes` (DisableSort/Sort, descending). Cascade kills losers'
  notation text events — harmless because sysex is unread.

Emit `notesDeduped { events = [{ ppq, chan, pitch, droppedCount }, ...] }`
if any.

### 4. Read ccs + text/sysex

`ccs` (dense):

```
{ idx, ppq, msgType, chan, [cc|pitch], val, shape, [tension], [muted] }
```

`noteSidecars` (a flat list of every `NOTE … ctm_<uuid>` notation event;
allows multiple per tag for orphan detection):

```
{ idx, ppq, chan, pitch, uuid }
```

`ccSidecars` (decoded magic-prefix sysex events):

```
{ idx, ppq, msgType, chan, [cc|pitch], val, uuid }
```

Also: `metadata = loadMetadata()`. Bump `maxUUID` from metadata keys so
fresh allocations don't collide with persisted slots.

### 5. CC dedup

Bucket `ccs` by `(ppq, chan, msgType, id)`. Within each group, prefer
stage-1 candidates (a cc whose `(ppq, val)` matches some sidecar in the same
`(msgType, chan, id)` bucket); fall back to the highest-loc cc in the group.
Survivor logic must match today's `dedupCCs` exactly.

- Nil losers in `ccs`, queue `ccDeletes` (idxs).

Emit `ccsDeduped` if any.

### 6. UUID unification (notes ↔ noteSidecars)

Walk `noteSidecars`. For each notation event:

- If `notesByTag[tag]` exists and that note has no uuid yet:
  set `note.uuid`, `note.uuidIdx = noteSidecar.idx`, bump
  `UUIDCount[uuid]`.
- Else: orphan (no kept note at this tag, or another notation event already
  claimed this note). Queue `noteSidecarDeletes` (its idx).

Then walk surviving `notes`:

- **Collision** (`UUIDCount[note.uuid] > 1`): allocate fresh uuid via
  `assignNewUUID`, deep-clone `metadata[old]` to `metadata[new]`,
  queue `noteSidecarRewrites { idx = note.uuidIdx, ppq = note.ppq,
  body = "NOTE <chan-1> <pitch> custom ctm_<newTxt>" }`. Decrement old
  UUIDCount, set new to 1.
- **No uuid**: allocate fresh uuid via `assignNewUUID`,
  queue `noteSidecarInserts { ppq, chan, pitch, uuid }`. (`note.uuidIdx`
  stays nil; final read fills it.)

Emit `uuidsReassigned` if any reassigns happened.

**Open question (preserve vs tighten):** today's code silently leaves
orphan notation events in REAPER. This plan deletes them. Confirm with
user before merging.

### 7. Sidecar reconcile (ccs ↔ ccSidecars)

Take a dense snapshot of the live (non-nil) `ccs` and `ccSidecars`, pass to
`sr:reconcile`. For each bind:

- `bind.cc.uuid = bind.sidecar.uuid`,
  `bind.cc.uuidIdx = bind.sidecar.idx`. Bump `maxUUID` if needed.
- If `not bind.silent`: queue
  `ccSidecarRewrites { idx = bind.sidecar.idx, ppq = bind.cc.ppq,
  body = sr:encode(bind.cc) }`.

For each `unboundSidecar`:
- Nil it in `ccSidecars`.
- Queue `ccSidecarDeletes` (its idx).

Emit `ccsReconciled` if any events.

### 8. Flush all queued ops

One `MIDI_DisableSort` / `MIDI_Sort` bracket. Order:

a. **Sets first** (no idx shift):
   `MIDI_SetTextSysexEvt` for `noteSidecarRewrites` and `ccSidecarRewrites`.

b. **Deletes descending**:
   - `MIDI_DeleteCC` for `ccDeletes`, descending. (Independent idx space —
     could go anywhere in the bracket; bundled here for tidiness.)
   - `MIDI_DeleteTextSysexEvt` for `noteSidecarDeletes ∪ ccSidecarDeletes`,
     merged and sorted descending. All idxs are from the step-4 read; sets
     in (a) don't shift them; deletes in descending order keep each
     remaining target stable.

c. **Inserts last**:
   `MIDI_InsertTextSysexEvt` for `noteSidecarInserts`. Their idxs aren't
   tracked — the final read pass picks them up.

(Note deletes already happened in step 3, before the sysex read.)

### 9. Compact

`notes`, `ccs`, `ccSidecars` → dense. (`util.compact` if it exists, otherwise
a 6-line helper.)

### 10. Final read pass — refresh idxs

Build LUTs over the now-compacted tables:

- `notesByTag[ppq|chan|pitch]` → note ref (unique post-dedup).
- `ccsByTag[ppq|chan|msgType|id]` → cc ref (unique post-dedup).
- `ccsByUuid[uuid]` → cc ref.

Walk REAPER:

- `MIDI_GetNote(i)` → tag → `note.idx = i`.
- `MIDI_GetCC(i)` → tag → `cc.idx = i`.
- `MIDI_GetTextSysexEvt(i)`:
  - notation event (type 15, parses as `ctm_<uuid>`):
    tag → `note.uuidIdx = i`.
  - magic sidecar (type −1, `}RDM` prefix): decode uuid →
    `cc.uuidIdx = i` (when the uuid maps to a kept cc).

### 11. Metadata merge + persist + signals

For each kept note: `util.assign(note, metadata[note.uuid])`,
`uuids[note.uuid] = note`.

For each kept cc with uuid: `util.assign(cc, metadata[cc.uuid])`,
`uuids[cc.uuid] = cc`.

`saveMetadata()` — persists current `uuids` to ext data, sweeps stale keys.

Fire signals in documented order:

```
takeSwapped → notesDeduped → uuidsReassigned → ccsDeduped → ccsReconciled → reload
```

Each fired only if its event list is non-empty (except `takeSwapped` /
`reload`, which follow their own conditions).

## What to delete from current load

- `dedupNotes()` (its work folds into step 3).
- `scanText()` (replaced by step 10's final read).
- `rewireCcSysexIdxs()` (folds into step 10).
- The mid-load `MIDI_DisableSort` / `MIDI_Sort` pairs around the notation-insert
  loop and around the reconcile flush — collapsed into the single bracket in
  step 8 (plus the standalone bracket in step 3 for note deletes).

Helpers worth keeping (unchanged):

- `loadMetadata`, `saveMetadata`, `saveMetadatum`.
- `assignNewUUID`.
- `parseUUIDNotation`.
- `sr:reconcile`, `sr:encode`, `sr:decode` — the reconciler is already pure
  over its args and stays as-is.

## Test strategy

- Run `lua tests/run.lua` after each meaningful step. 250 tests today; all
  must continue to pass.
- Pay attention to `tests/specs/sidecar_reconcile_spec.lua` — the reconciler
  interface is unchanged, but the wiring around it (when sidecars are read,
  what shape `ccs` is in when reconcile is called) is changing.
- All five signal contracts (`notesDeduped`, `uuidsReassigned`, `ccsDeduped`,
  `ccsReconciled`, `reload`) must continue to fire with the documented
  payload shapes and in the documented order. See `docs/midiManager.md` §
  Signals.

## Acceptance

- 250+/250 tests pass.
- `mm:load` is shorter and has one less control-flow phase (no
  scanText/rewire dance).
- The signal contract in `docs/midiManager.md` is preserved verbatim.
- No regression in the sidecar reconciliation behavior — same binds, same
  events, same flush ordering as observed externally.
</newTxt></pitch></chan-1>