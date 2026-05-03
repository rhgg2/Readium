# mm callback signalling revamp

**Status:** steps 1–3 landed.
- Step 1 — signal-keyed `installHooks`, mm/tm/cm migrated to single signals each.
- Step 2 — mm.reload split into `takeSwapped` / `notesDeduped` /
  `uuidsReassigned` / `reload`. tm forwards the reconciliation kinds and
  consumes `takeSwapped` into its rebuild flag. tm.rebuild and
  vm:rebuild now take a plain `takeChanged` bool. Inline
  "Removed N duplicate events!" print is gone.
- Step 3 — display consumers not wired yet; signals fire, no UI subscribes.
- Step 4 (cc-sidecar) — still upstream of `cc-sidecar-metadata`.

The reconciliation payload schema landed simpler than the original sketch
(see below): `{ ppq, chan, pitch, droppedCount }` for `notesDeduped` and
`{ oldUuid, newUuid, ppq, chan, pitch }` for `uuidsReassigned`. Producing
`keptUuid` / `droppedUuids` honestly would require reordering the load
path so notation events scan before dedup; out of scope for this revamp.

## Goal

Replace mm's coarse `changed = { take, data }` callback payload with a
tagged-signal stream. Each signal stands on its own — callers subscribe to
the kinds they care about and receive only those. This makes silent
reconciliation events (note dedups, uuid collisions, later cc orphans /
rebinds) visible to higher layers and ultimately to the user.

## Current shape

```
mm:addCallback(fn)
fn(changed, mm) on every reload
changed = { take = bool, data = bool }
```

`installHooks` (in util) is shared by mm, tm, cm. All three pass `self` as a
second arg; no caller uses it.

## New shape

A signal is a value `{ signal = '<kind>', data = <table> }`. Callers register
per-kind:

```
mm:addCallback(signal, fn)        -- filtered: fn fires only for this kind
fn(data)                           -- payload only; no mm/self arg
```

### Signal taxonomy

| signal | when | data |
|---|---|---|
| `reload` | every reload (baseline rebuild trigger) | none |
| `takeSwapped` | reload received a different take | none |
| `notesDeduped` | (ppq,chan,pitch) collisions resolved on load | `{ events = [{ppq,chan,pitch,keptUuid,droppedUuids}, ...] }` |
| `uuidsReassigned` | shared-uuid collisions resolved on load | `{ events = [{oldUuid,newUuid}, ...] }` |
| later: `ccsDeduped`, `ccsOrphaned`, `ccsRebound` | cc-sidecar reconciliation | analogous shapes |

### Firing rules

- Reconciliation signals fire only when there's something to report; no
  zero-event calls.
- Each reconciliation signal fires once per reload, payload bundles all
  events of that kind.
- Order within a reload: `takeSwapped` (if applicable), then any
  reconciliation signals, then `reload` last — subscribers handle the
  reconciliation info before they rebuild from current state.

### Why split rather than one omnibus `reconciled`

Filtering at registration cuts both ways: a uuid-keyed cache wants to
subscribe to `uuidsReassigned` specifically, not "anything that got fixed".
Banner UI subscribes to all kinds by registering N times — cheap. One
omnibus signal forces every consumer to walk a payload tree they mostly
don't care about.

## `installHooks` generalisation

`util.installHooks` becomes signal-keyed:

```
fire = util.installHooks(owner)
-- owner:addCallback(signal, fn), owner:removeCallback(signal, fn)
fire(signal, data)
```

cm and tm migrate at the same time. Their existing payloads collapse to a
single signal each (e.g. cm fires `'configChanged'` with its
`{key, level}` payload) until they have reason to split further.

## Pure-metadata `assignNote` carve-out

Unchanged. Metadata-only writes still skip reload entirely → no signals
fire. The carve-out is for hot annotation paths; firing on every keystroke
is wrong. The revamp is about load-time reconciliation.

## Migration

1. Rewrite `util.installHooks` to be signal-keyed. Update mm/tm/cm `fire`
   call sites and existing `addCallback` callers to pass a single signal
   name (`'reload'` for mm, `'configChanged'` for cm, etc.). No new
   behaviour yet — just shape.
2. Split mm's single `'reload'` into `reload` + `takeSwapped` + reload-time
   reconciliation paths. Wire note dedup + uuid-collision counters into
   `notesDeduped` / `uuidsReassigned`.
3. Update consumers that should display reconciliation (renderManager
   transient banner, or trackerManager log).
4. cc-sidecar-metadata builds on this — adds `ccsDeduped`, `ccsOrphaned`,
   `ccsRebound`.

## Test plan

- Hand-craft a take with two notes at identical (ppq, chan, pitch) of
  different lengths. Reload. Assert `notesDeduped` fired once, `events`
  has length 1, `keptUuid` is the longer note.
- Hand-craft two notation events sharing a uuid. Reload. Assert
  `uuidsReassigned` fired once, `events` has length 1, `newUuid` differs
  from `oldUuid`.
- Reload a clean take. Assert only `reload` fired.
- Reload with a different take pointer. Assert `takeSwapped` fires before
  `reload`.
- Register two callbacks for different signals; trigger a load that
  produces both; assert each fires exactly once with its own payload.
