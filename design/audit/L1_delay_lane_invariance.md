# L1 — Delay can't change lane allocation  ✅ HOLDS

**Invariant**: `noteColumnAccepts` judges in intent space (subtracts
`delayToPPQ(delay)` on both sides). Changing only `delay` on a note
cannot push it into another column or spring a new one.

**Falsifying test**: two same-pitch notes in lanes 1 and 2; delay-nudge
the lane-1 note across the lane-2 onset in realised time; assert the
lane-1 note's lane is still 1 after rebuild.

---

## Verdict

L1 holds. The mechanism is algebraic recovery: `noteColumnAccepts`
reconstructs intent from `(realised, delay)` on both sides of every
comparison, and a delay-only edit preserves intent for the edited note
*and* every sibling. So the predicate's answer is invariant, the
persisted `note.lane` is honoured at rebuild, and no spill column is
sprung.

The broader reading (no third-party note changes lane via a CSK
cascade) holds for the codebase as it stands: every callsite that
writes `delay` routes through vm's `delayRange` first.

### Rule to extract into docs

> **Every delay write must go through `delayRange`.** L1's broader
> reading is upheld by the channel-wide same-pitch arm of
> `delayRange`, which caps `realised` at the previous same-pitch
> sibling's intent endppq. Without that cap, a delay edit can move a
> note's realised onset into a same-pitch sibling's intent window,
> which trips `clearSameKeyRange` at rebuild and can cascade into a
> lane change on a third-party note. The audit found no callsite
> bypassing the gate; future writes of `note.delay` (direct
> `tm:assignEvent({ delay = ... })` in particular) must clamp through
> `delayRange` for the same reason.

---

## Detailed walk

### `noteColumnAccepts` — tm:603–619 ✓

```lua
local function noteColumnAccepts(col, note)
  local lenient = cm:get('overlapOffset') * mm:resolution()
  local noteppqI    = note.ppq - delayToPPQ(note.delay or 0)
  local noteEndppqI = note.endppq
  local dominated = 0
  for _, evt in ipairs(col.events) do
    local evtppqI = evt.ppq - delayToPPQ(evt.delay or 0)
    if noteppqI == evtppqI then return false end
    if noteppqI < evt.endppq and evtppqI < noteEndppqI then
      local threshold = (evt.pitch == note.pitch) and 0 or lenient
      local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
      if overlapAmount > threshold then return false end
      dominated = dominated + 1
    end
  end
  return dominated < 2
end
```

Every comparison is intent-vs-intent:

- onsets: `noteppqI` and `evtppqI`, both `realised − delayToPPQ(delay)`.
- ends: `evt.endppq` and `noteEndppqI`, both intent in storage (F3).
- threshold: `lenient` is `cm:get('overlapOffset') * resolution`,
  delay-independent.

The recovery `intent = realised − delayToPPQ(delay)` is exact in ℤ:
`delayToPPQ` rounds at source (F2), so for any note whose realised was
written as `intent + delayToPPQ(delay)`, the subtraction returns the
original intent without rounding error.

Therefore: hold the intents (of the edited note *and* every sibling
event in `col.events`) constant, and the predicate's value is
constant.

### Sole caller — `allocateNoteColumn` (tm:621–639) ✓

```lua
local function allocateNoteColumn(channel, note)
  local notes = channel.columns.notes
  if note.lane then
    local col = notes[note.lane]
    if col and noteColumnAccepts(col, note) then
      return col, note.lane
    end
    if not col then
      while #notes < note.lane do pushNoteCol(channel) end
      return notes[note.lane], note.lane
    end
    -- Exists but won't fit; fall through to first-fit / spill.
  end
  for i, col in ipairs(notes) do
    if noteColumnAccepts(col, note) then return col, i end
  end
  return pushNoteCol(channel)
end
```

`allocateNoteColumn` is only called from rebuild step 2 (tm:705). The
flow on a delay-only edit:

1. Delay edit lands as `note.delay = D'` and `note.ppq = oldIntent +
   delayToPPQ(D')` (via `realiseNoteUpdate` → `resizeNote`; see F2
   walk).
2. mm flush → `tm:rebuild` re-iterates `mm:notes()`. `note.lane`
   persisted from prior rebuild.
3. `noteColumnAccepts(notes[note.lane], note)` recovers intent =
   `oldIntent + delayToPPQ(D') − delayToPPQ(D') = oldIntent`. The
   prior siblings already in `col.events` have unchanged intents (they
   weren't touched). Predicate answer ≡ pre-edit answer ≡ true (since
   the persisted lane was previously valid). ✓
4. Returned lane = `note.lane`; the `if note.lane ~= lane` guard at
   tm:706 doesn't fire; no `pushNoteCol`. ✓

### Iteration stability ✓

`mm:notes()` iterates by location (insertion order). A delay-only edit
changes `delay` and `ppq` fields, not the note's location. Iteration
order is stable across the edit, so each note sees the same prior
siblings in `col.events` when allocation runs.

### vm-side delay-only writers — same three sites as F2 ✓

`editEvent` stop 5–7 (vm:610–629), `nudgeDelay` (vm:1342–1347), and
`queueResetDelays` (vm:1462–1468) all send `{ delay = newDelay }`
through `delayRange`'s clamp first (or, for `queueResetDelays`, set
`delay = 0` which trivially can't violate any bound). delayRange's
`sameP` arm bounds `n.realised` at the prev same-pitch sibling's
*intent* endppq (`prevSameEnd` is the realised end of the prev
same-pitch note, but realised endppq = intent endppq since delay
doesn't shift endppq — F3). So no UI-driven delay edit can move
`n.realised` into the `(B.ppq, B.endppq)` window of any same-pitch
sibling B.

That matters for the broader-reading caveat below.

### Broader reading: CSK cascade closed at the gate ✓

L1 strictly says "the edited note doesn't change column" — that's what
the algebraic recovery above proves. The broader reading ("no note
changes column because of a delay edit") would also have to rule out
indirect cascades via `clearSameKeyRange` (tm:421–445) at rebuild step
1:

- CSK clamps a sibling B's `endppq` based on **realised** sibling
  positions (F2 resolution: CSK is realised by MIDI spec).
- A delay edit on A could in principle move A.realised between
  B.ppq (realised) and B.endppq (intent). That would shrink B.endppq
  and could change `noteColumnAccepts` for some unrelated note C
  trying to share B's column.

`delayRange`'s same-pitch arm forecloses this: it caps A.realised at
the prev same-pitch sibling's endppq. By V1, same-pitch siblings have
disjoint intent intervals, so any same-pitch B has B.endppq ≤
prev-same-pitch's endppq ≤ A.realised. A can never sit inside B's
intent window. ✓

All three vm-side delay writers go through this gate; no other site in
the codebase writes `delay` directly. See the "rule to extract" at the
top.

### Summary

| Path                              | Holds L1? |
|-----------------------------------|-----------|
| `editEvent` stop 5–7 delay edit   | ✓         |
| `nudgeDelay`                      | ✓         |
| `queueResetDelays` (delay → 0)    | ✓         |
