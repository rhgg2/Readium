# Aliases — pooled events with transformations

A working design doc for the alias/pooled-event feature. Future
`docs/aliases.md` is distilled from this once code lands.

An **alias** is a copy of an existing event that follows its source under
a stored transformation. When the source mutates, the alias is
re-derived. Aliases form trees: aliases of aliases obey the same rule.
The result is a lightweight algorithmic-composition substrate inside a
single Continuum take.

---

## Identity & persistence

### Spec tree on the root

The whole descendant tree of an aliased event lives as metadata on the
**root** — the topmost ancestor with no parent. Nothing canonical lives
on the materialised children.

```lua
note.aliases  = {                                  -- ordered, creation-time
  { id='1', xform={'dppq=120', 'dpitch=7'},
    children = {
      { id='1.1', xform={'dppq=240'}, children={} },
    },
  },
  { id='2', xform={'dppqL=480'}, children={} },
}
note.aliasCtr = 3                                  -- next id allocator
```

- `id` — base-36 monotonic, allocated per-root from `aliasCtr`. Stable
  across rebuilds and save/load. Spec-paths are root-relative, so global
  uniqueness isn't needed.
- `xform` — ordered list of op strings (see **Op vocabulary**). Empty
  list = identity. List concatenation = morphism composition.
- `children` — ordered list of nested specs, same shape recursively.

`aliases` and `aliasCtr` go on the metadata field whitelist for both
notes and ccs (the cc sidecar carrier already supports arbitrary
metadata).

### Materialised events

Every emitted alias is a real MIDI event with two fields of metadata:

```lua
parentUuid = '<root_uuid>'   -- which root's tree owns me
specPath   = '1.1.2'         -- dotted id path from root to my spec node
```

Both are written fresh each rebuild. The materialised event's own UUID
is **ephemeral** — regenerated on every rebuild (sidecar/notation
events come and go with it). The persistent identity of an aliased
event is `(parentUuid, specPath)`, not its MIDI UUID.

Per-child user metadata (anything the user wants a specific child to
"carry") goes in the spec node, not on the materialised event — because
the event is ephemeral.

---

## Op vocabulary

```
time      : dppq, dppqL, ppqscale, ppqLscale
duration  : ddur, ddurL, durscale
pitch     : dpitch, ddetune
value     : dvel, dval, valscale
channel   : dchan
delay     : ddelay
```

Each op is **single-parameter**, encoded as `'<opkind>=<value>'`.

- `d*` ops add: `state.f ← state.f + value`.
- `*scale` ops multiply around 0: `state.f ← state.f * value`.

"Scale around anchor `a`" is built from composition:
`['dppq=-a', 'ppqscale=k', 'dppq=+a']`. Coalescence merges the trailing
`dppq` with later nudges. The op vocabulary stays unparameterised by
context.

### Composition and coalescence

A transform list is applied left-to-right over the parent's resolved
state. Composition of transforms is concatenation. Two children of the
same parent have independent transforms; a child of a child composes.

**Coalescence:** when an edit appends a new op, if the trailing op in
the existing list is the same kind, merge by op-specific arithmetic
(`d*` adds, `*scale` multiplies). Only adjacent same-kind ops merge —
intervening different-kind ops block coalescence (since ops don't
commute in general).

### Per-event-type validity

Not every op makes sense on every event type. `dpitch` is meaningless
on a cc; `dval` is meaningless on a note (vel uses `dvel`). At
alias-creation time the parent's type is known, so only valid ops are
offered. A transform can always be carried forward across rebuilds even
if it contains no-op-on-this-type ops — they fail closed (skip, no
mutation). The validity table lives in `aliases.lua`.

---

## Resolution

### Rebuild walk (tm-side)

On every `'reload'` from mm, tm:

1. Sweeps events; treats every event with `parentUuid` metadata as a
   **stale materialisation** and queues it for deletion.
2. Builds a `uuid → root_event` index from non-materialised events.
3. For each root, BFS its spec tree. At each node:
   - Resolve fields = `applyOps(parent_resolved_fields, spec.xform)`.
   - Check the **claims** map (see **Precedence**). If claimed, skip
     emission of this node. Continue walking children with the
     would-be-resolved fields as their parent state — children resolve
     independently of whether intermediate ancestors materialised.
   - If unclaimed, queue an emit with `parentUuid` + `specPath`, and
     claim the slot.
4. Flush queued deletes and adds in a single `mm:modify`.

Roots and depth-0 plain events are placed first, so real-beats-alias is
a corollary of BFS order, not a separate rule.

### Touched-set optimisation

Full rebuild on every reload churns sidecars/notation events
unnecessarily — most reloads only touch one root's subtree. The
optimisation:

- mm tracks a **touched set** during `modify`: every `add*` / `assign*`
  / `delete*` call records the affected uuid (or "structural" sentinel
  for grid-level changes that affect everyone).
- `'reload'` fires with `data = { touched = {<uuid>=true, ...} }` (or
  `{ touched = 'all' }` for take swaps and bulk operations).
- tm rebuild only re-emits subtrees whose root is in `touched`. Other
  roots' materialisations stay in MIDI untouched.

Edge: if a materialised alias is touched (user nudged a child),
`route()` (see **Mutation**) writes the change to the root's spec, then
the root counts as touched and its subtree re-emits. The materialised
event being directly touched is never the rebuild trigger — the spec
update is.

This optimisation is Phase 2.5. v1 ships without it; the touched
mechanism is added once we have realistic alias trees to profile against.

### Avoiding rebuild loops

tm's rebuild plants new materialisations via `mm:modify`, which fires
its own `'reload'`. To avoid an infinite loop, the rebuild-driven
modify carries a flag: `mm:modify(fn, { silent = true })` skips the
trailing reload. tm sets this when its writes are derived from spec
state and add no new user intent.

---

## Mutation

Every editing command is tagged with one of four roles. Routing through
`aliasRouter.route(evt, opkind, value)` is uniform; the role decides
what `route` does.

### Relative — composes into transform

If `evt.parentUuid` is set, walk to the spec node, append the op,
coalesce. Otherwise mutate the event directly.

| command | op |
|---|---|
| `nudgeBack/Forward` (`adjustPosition`) | `dppq` |
| `growNote`/`shrinkNote` (`adjustDuration`) | `ddur` |
| `nudgeCoarse/Fine Up/Down`, pitch | `dpitch` |
| `nudgeCoarse/Fine Up/Down`, vel | `dvel` |
| `nudgeCoarse/Fine Up/Down`, val | `dval` |
| `nudgeCoarse/Fine Up/Down`, delay | `ddelay` |
| `insertRow`, `deleteRow` | `dppq` per affected event |
| (new) `shift` | dispatch by cursor kind |
| (new) `scale` | dispatch by cursor kind |

`insertRow`/`deleteRow` compose `dppq` into aliased children even when
their parent lies outside the shifted region. The alias drifts from its
parent — accepted.

### Absolute — severs

If `evt.parentUuid` is set, sever first (pluck-and-promote, see
**Severance**), then apply the op to the now-root. Otherwise mutate
directly.

| command | why |
|---|---|
| typed pitch input (qwerty row), repitching | sets pitch absolutely |
| `noteOff` | inserts a note-off boundary |
| `interpolate` | writes computed absolute values |
| `quantize`, `quantizeKeepRealised` | snaps logical ppq to grid |

### Structural — alters the spec tree

| command | behaviour |
|---|---|
| `delete`, `deleteSel`, `cut` (on aliased event) | remove spec node; sever-and-promote its children to new roots |
| `copy`, `paste`, `duplicateDown/Up` (in alias mode) | add a new spec node under the source's root |
| `sever` (new, `Ctrl+.`) | pluck-and-promote without other modification |

### Recompute — neither composes nor severs

| command | why |
|---|---|
| `reswing*` | recomputes intent from logical via swing curve; spec transforms operate on logical and intent symmetrically and stay valid |

---

## Precedence and collisions

**Rule.** Place events in BFS order from roots, depth 0 first, ties by
spec-creation order. First arrival owns the slot.

The slot key is the realisation key:
- Notes: `(chan, pitch, ppq)`.
- CCs: `(chan, msgType, id, ppq)`.

A would-be alias whose slot is taken is **suppressed** for this
rebuild cycle: not emitted to MIDI, but its spec is untouched. Its
descendants resolve from the would-be-resolved fields (as if the alias
had emitted) and may themselves emit, suppress, etc.

When the blocker moves or the alias's transform changes such that the
slot is free, the next rebuild emits the previously-suppressed alias —
**resurface**. The mechanism is the same BFS walk; no special case.

**Real-beats-alias** falls out: a real (non-aliased) event is a depth-0
node in its own (possibly trivial) tree, placed before any depth-≥-1
descendant of any tree.

---

## Severance

### Sever-and-promote

To sever a spec node `S` from its parent:

1. Locate `S` by `(parentUuid, specPath)` in the root's spec tree.
2. Pluck the subtree rooted at `S` from its parent's `children` list.
3. Materialise `S` as a new top-level event:
   - Use `S`'s currently-resolved fields, computed from the now-vanished
     parent state. (This is what the materialised MIDI event already
     holds, so no recomputation needed if we route through the live
     event.)
   - Drop `parentUuid` and `specPath`; keep the rest of `S`'s metadata.
   - Allocate a fresh permanent UUID for the new root.
4. The subtree under `S` follows: each descendant's `xform` was relative
   to `S`'s resolved state, which is now `S`'s baked-in field state, so
   the resolution math is unchanged. The `parentUuid`s in the descendants'
   metadata get updated to point at the new root.

`xform` on `S` is forgotten in the promotion — a root has no transform
because it has no parent.

### Cascade-delete vs sever-and-promote

`delete` on an aliased event removes its spec node. Its children's
default behaviour is **sever-and-promote** — they become new roots with
their currently-resolved fields baked in. UI offers cascade-delete as
an explicit alternative.

`delete` on a root: same rule — children of the root become new roots.

---

## Creation UX

- `` ` `` toggles **alias mode** (`vm.aliasMode`). Renderer shows a
  small indicator when on.
- In alias mode, `copy`/`paste` and `duplicateDown/Up` create aliased
  copies linked to their sources:
  - `dppq` derived from destination row offset relative to source.
  - `dpitch` derived from pitch offset (note column).
  - `dchan` derived from channel offset.
- Out of alias mode, these commands behave as today.
- `Ctrl+.` is `sever`.

The same routing path serves `paste`, `duplicate*`, `shift`, `scale`,
and the family of relative nudges — the only differences are which op
is composed and whether a new spec node is being created or an existing
one is being updated.

---

## Cycle prevention

Cycles cannot arise: every alias is a *new event*, and its `parentUuid`
is set at creation to point at an event that already exists. Editing a
materialised event can sever or update its transform, but never
re-parent. So the spec tree is a tree by construction.

---

## Visual representation

(Renderer-side; final design in `docs/renderManager.md` once landed.)

- Materialised aliases get a visual marker — a `cm`-defined role
  colour, probably a tint or border distinguishing them from plain
  events. Final choice deferred to Phase 7.
- Suppressed aliases (collision losers) are not rendered; v1 does not
  ghost them. Possible v1.1 enhancement.
- Alias-mode indicator in the toolbar.

---

## Phasing

| phase | scope |
|---|---|
| 0 | this design doc |
| 1 | schema, spec_id allocation, `aliases.lua` pure helpers, serialise round-trip |
| 2 | tm rebuild walker (full rebuild every reload, no touched-set yet) |
| 2.5 | touched-set optimisation: mm tracks mutations, `'reload'` carries `data.touched`, tm rebuild reads it |
| 3 | edit routing (`route()`), relative-command dispatch, coalescence on real takes |
| 4 | alias mode, creation hooks on copy/paste/duplicate |
| 5 | severance command + structural-command handling |
| 6 | new commands: `scale`, `shift` |
| 7 | renderer markers and alias-mode indicator |

Each phase has a regression-test surface; see `Test surface` below.

---

## Test surface

Tests live under `tests/specs/aliases_*.lua` plus pure-helper specs in
`tests/specs/aliases_helpers_spec.lua`.

**Phase 1** — pure helpers
- `applyOps` correctness for each op kind on each event type.
- Coalescence merges adjacent same-kind, leaves non-adjacent or
  different-kind alone.
- `find` / `pluckSubtree` on deep trees with non-trivial spec_paths.
- `util.serialise` round-trip on nested spec trees.

**Phase 2** — rebuild walker
- Single-level alias materialises with correct resolved fields.
- Three-level alias resolves transitively.
- Collision suppresses leaf, spec persists.
- Move blocker → alias resurfaces in next rebuild.
- Collision on intermediate node suppresses just that node;
  descendants still resolve from would-be state.

**Phase 3** — edit routing
- Relative edit on aliased child: transform updates, parent unchanged.
- Relative edit on plain event: behaves identically to today.
- Two same-kind nudges produce one coalesced op.

**Phase 4** — creation
- Alias-paste at row+4 produces spec under source with `dppq` matching
  4 rows.
- Duplicate down on existing alias creates a sibling (not nested) spec
  under the same root.

**Phase 5** — severance
- Sever preserves resolved field state at the moment of severance.
- Sever preserves the descendant subtree (children stay aliased to the
  newly-promoted root).
- Delete on root cascades children to new roots with cached fields.
- Absolute edit on aliased child severs and writes through.

**Phase 6** — new commands
- `scale 0.5` on a 4-event aliased group produces correctly-spaced
  resolved positions.
- `shift` composes into a single coalesced `dppq`.

---

## Open questions

- **Ghost rendering** of suppressed aliases (v1.1?).
- **`scale` in val cursor on a note** — does it mean `velscale`? Small
  UX call, settle in Phase 6.
- **Profiling** — when does the touched-set optimisation become
  necessary? Answer once realistic alias-tree sizes exist.
