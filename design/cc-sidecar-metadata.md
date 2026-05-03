# CC/PB/AT sidecar metadata

**Status:** phase 2 landed — full reconciliation pipeline (tiers 1-4),
`ccsReconciled` signal, sidecar rewrite + orphan delete on load. Phase 3
(cc dedup with rule-2 + `ccsDeduped` signal) still to come.
**Depends on:** `callbacks-revamp.md`.

## Goal

Give cc/pb/at events the same per-event metadata story notes already have:
stable uuid identity that survives save/load, a `ctm_<uuid>` ext-data slot for
arbitrary fields, and an `assignCC` API that merges metadata fields the same
way `assignNote` does.

Carrier: a coincident **sysex sidecar** with a Continuum magic prefix. (Note's
notation-event trick isn't available for non-note events — sysex is the only
free-form MIDI carrier REAPER preserves.)

## Why

Concrete pain that this unlocks:
- **Authored-row recovery for ccs:** record the intent ppq directly in
  metadata. Beats forward-roundtrip recovery; uniform with anywhere else
  intent-vs-realisation needs to be remembered for ccs. (First-touch
  caveat: stamping must capture *intent* ppq, not the realised ppq the
  cc currently sits at — typically by forward-roundtripping once at
  first stamp and recording the result.)
- **Cipher off the note:** fake-pb's cipher currently rides on the
  accompanying note's metadata, violating the detune/pb orthogonality
  invariant in spirit. With pb metadata, the cipher lives on the pb event.
- **No "owner" pointer for reswinging ccs:** each cc carries its own slot.
- **Pooled MIDI events** (later project): two events sharing one uuid are
  pool-linked; their shared metadata lives once in ext data. No separate
  pool-id; pool identity collapses into the uuid.

## Sidecar-on-touch

Plain (un-stamped) ccs **do not** auto-allocate uuids on load. A cc acquires
a sidecar only when something writes metadata to it via `assignCC`. Imported
automation streams stay free of overhead until Continuum touches them. Avoids
the "every event gets a sysex twin" doubling on dense automation.

## Sidecar format

A sysex with a magic prefix tagging it as Continuum identity, carrying a
fingerprint of the target event at last write time:

```
F0 7D 'R' 'D' 'M' <type> <chan> <cc#> <val_lo7> <val_hi7> <uuid...> F7
```

(Manufacturer ID `7D` is non-commercial, distinct from real device sysex.)

The 13-byte form above is the **on-disk / on-wire** sysex. mm passes
the 11-byte **body** (without `F0`/`F7`) to `MIDI_InsertTextSysexEvt`
and receives the body back from `MIDI_GetTextSysexEvt` — REAPER does
the framing itself per the API contract for `type = -1`.

The sidecar's own MIDI position is the load-time anchor — no body-encoded
ppq. REAPER moves all events together, so `sidecar.ownPpq` tracks where
the cc was at last write; tier 1 binds on positional coincidence with the
cc directly.

`<cc#>` is the controller number for `cc`, the note pitch for `pa`, and
reserved (zero) for `pb` / `pc` / `at` (one stream per channel — no cc#
needed). `<val>` is decorative for binding but powers tier 2's
"value-drifted" detection.

## Reconciliation tiers (load-time)

Sidecars don't have REAPER-side binding to their target the way notation
events have to notes. So matching has to handle drift. The bias is to
keep metadata attached to *something* and route uncertainty via the
signal stream — silent loss is worse than a flagged guess.

Process per load:

1. **Exact.** `sidecar.ownPpq == cc.ppq`, full fingerprint match
   (chan, type, cc#, val). Bind silently. Catches anything that moves
   sidecar and cc together (glue, item shift) — REAPER moves all events
   as a unit.
2. **Value-drifted.** Same ppq, same (chan, type, cc#), val differs.
   Bind, emit `valueRebound`. Catches external edit of the cc's value
   with no positional change.
3. **Consensus offset.** For each (chan, type, cc#) bucket of remaining
   orphans + unbound ccs, histogram the implied offsets. If a dominant
   offset emerges (≥ threshold of orphans agree), apply it globally,
   bind, emit `consensusRebound`. Catches the common case: user
   selected a group of ccs in REAPER's MIDI editor and dragged them.
   Selection is per-event-type, so sysex sidecars stay behind while
   ccs move uniformly.
4. **Per-orphan resolution.** For each remaining orphan, by candidate
   count among unbound ccs with matching (chan, type, cc#):
   - 0 candidates → `orphaned`. The cc is genuinely gone.
   - 1 candidate → `guessedRebound`. Only one place the metadata
     could go; bind there. Low-confidence because no consensus
     supports it (e.g. user dragged a single cc).
   - ≥2 candidates → `ambiguous`. Multiple plausible targets, no way
     to pick. Drop the metadata; better than attaching it to a
     provably-wrong event.

After all binds, rewrite the bound sidecars' positions to match their
ccs so the next reload starts from a clean tier-1 state.

**Open knob:** consensus threshold for tier 3. Lean: ≥ 50% of orphans
agree on an offset, with a minimum count of 2 (a single orphan with a
single candidate is the `guessedRebound` case, not consensus). Tune
with real-world feel.

Per-sidecar nearest-search is **not** considered. Multi-candidate
ambiguity drops the metadata rather than guessing — the signal makes
that visible to the user.

## Dedup

Dedup runs **after** reconciliation, the reverse of the note flow (where
dedup precedes binding). The order matters: dedup needs to know which
duplicate carries metadata so rule 2 can keep the right one.

Dedup ccs by `(ppq, chan, type, cc#)`. **Rule 2:** keep the one with a
uuid (preserves user-stamped metadata). If both have uuids, fall back to
"latest loc." Fire `ccsDeduped` with `keptHadUuid` per group as the
audit trail.

(Two ccs at same time on same controller is contradictory; this matches
note dedup's spirit. Skipping dedup risks silent metadata loss when an
external edit produces duplicates.)

## API delta

```
mm:getCC(loc)         -- returns event with .uuid (nil if untouched) and
                      -- metadata fields merged in
mm:assignCC(loc, t)   -- splits t into event-fields vs. metadata
                      -- event-field changes:
                      --   - move event in REAPER
                      --   - if uuid present, also rewrite/move sidecar
                      -- metadata-field changes:
                      --   - if uuid nil, allocate uuid + insert sidecar
                      --     (under modify lock — sysex insert)
                      --   - write to ctm_<uuid> ext-data slot
                      -- pure-metadata + uuid-already-present: carve-out as
                      -- per assignNote
mm:deleteCC(loc)      -- also delete sidecar, clear ext-data slot
```

`pb` / `at` / `pa` / `pc` ride along (they're already msgType variants of
cc, share the loc space).

Sidecars are routed to an internal `sidecarTbl` during load and never
surface to upper layers (mm has no public sysex API).

## Signals

Two new mm signals, parallel to `notesDeduped` / `uuidsReassigned`. Both
fire only when non-empty and forward through tm via `tm:forward`.

```
ccsReconciled {
  events = [
    { kind = 'valueRebound',     uuid, ppq, chan, type, cc, oldVal, newVal },
    { kind = 'consensusRebound', uuid, ppq, chan, type, cc, offset },
    { kind = 'guessedRebound',   uuid, ppq, chan, type, cc },
    { kind = 'ambiguous',        uuid, candidatePpqs = {...} },
    { kind = 'orphaned',         uuid, lastPpq, chan, type, cc },
    ...
  ]
}

ccsDeduped {
  events = [
    { ppq, chan, type, cc, droppedCount, keptHadUuid },
    ...
  ]
}
```

The omnibus `ccsReconciled` collapses all metadata-relocation outcomes
into one signal — they're variations of the same operation (metadata
trying to find its event). A subscriber that wants only the data-loss
subset filters on `kind == 'orphaned' or 'ambiguous'` in its handler.
Dedup stays separate because it's a categorically different operation
(events removed, not metadata relocated).

`orphaned` and `ambiguous` events are the user-visible failure cases
("3 cc metadata records lost on load") — banner UI can surface them
distinctly from the silent-success rebinds.

## uuid namespace

Reuse the existing per-take monotonic counter (`ctm_keys` ext-data
registry). uuids are globally unique within the take; no separate cc
namespace. Pool-id (later) is just a uuid shared by multiple events.

## Test plan

Per tier:
- **Tier 1:** stamp a cc, save, reload. Round-trip preserves metadata,
  no `ccsReconciled` event fires.
- **Tier 2:** stamp a cc, externally edit its value, reload. Metadata
  preserved, sidecar rewritten, one `valueRebound` event fires.
- **Tier 3 (consensus):** stamp several ccs, simulate uniform ppq shift
  on the cc events but not the sidecars, reload. All rebind via
  `consensusRebound` events with shared `offset`.
- **Per-orphan, single candidate:** stamp one cc, drag only that cc
  externally, reload. One `guessedRebound` event fires.
- **Per-orphan, no candidate:** stamp a cc, externally delete it,
  reload. One `orphaned` event fires.
- **Per-orphan, multiple candidates:** stamp a cc; externally add
  another cc with the same (chan, type, cc#) at a different ppq; move
  the original. Reload. One `ambiguous` event fires; metadata dropped.
- **Sidecar-only deletion:** stamp a cc, externally delete just the
  sidecar (cc untouched), reload. cc reverts to untouched (no uuid),
  one `orphaned` event fires for the lost metadata.
- **Pb round-trip:** stamp a pb event, save, reload. Encoding handles
  the `cc# = 0 sentinel` and `val_lo7/val_hi7` split correctly.
- **Dedup rule 2:** craft two ccs at identical (ppq, chan, type, cc#),
  one stamped one plain. Reload. The stamped one survives, `ccsDeduped`
  fires with `keptHadUuid == true`.
- **Carve-out (already-stamped):** stamp metadata onto a cc that
  already has a uuid; assert no reload/signal fires (parity with note
  carve-out).
- **Carve-out (first stamp):** stamp metadata onto an untouched cc;
  assert it requires the modify lock (sysex insert).

## Out of scope (this project)

- Pooled-event duplication semantics (separate project; this just makes
  the underlying identity available).
- Migrating fake-pb cipher off notes onto pb events (separate project;
  uses this).
- Per-sidecar nearest-search heuristics. Multi-candidate ambiguity
  drops metadata rather than guessing — see reconciliation notes.
- Any heuristic recovery beyond consensus offset + single-candidate
  rebind.
