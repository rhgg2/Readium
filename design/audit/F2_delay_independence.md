# F2 — Delay independence  ✅ RESOLVED (qualified)

**Invariant**: a delay-only edit changes `ppq` (realised) and nothing
else: `ppqL`, `endppqL`, `endppq`, `frame` all untouched. The map
`delay → ppq` is the integer bijection given by `timing.delayToPPQ`.

**Falsifying test**: nudge a note's delay; expect `endppq`, `ppqL`,
`endppqL`, `frame` byte-identical.

---

## Resolution

The invariant holds **for every edit `delayRange` lets through**, which
is every delay edit reachable via vm. The original audit framed
`clearSameKeyRange`'s clamp branch as a "latent F2 violation under
negative-delay siblings" — that framing was wrong. Same-`(chan, pitch)`
truncation lives in **realised space** because MIDI gives one voice
per `(chan, pitch)` and a realised collision must shorten one of the
parties regardless of intent geometry. The truncated `endppq` is "the
moment we now intend to end, forced by the voice collision" — still
intent in the F3 sense, just with its value chosen by realised
constraints. See `docs/trackerManager.md` (Single voice per (chan,
pitch) — realised space) for the policy statement.

What that means for F2: if a user-driven edit *would* trigger CSK's
clamp, `delayRange` blocks the edit upstream. Edits that bypass
`delayRange` (direct `tm:assignEvent`, foreign MIDI on rebuild, or
seeded test fixtures) can legitimately see endppq adjust to honour the
voice constraint — and that's correct MIDI behaviour, not a bug.

### Real F3 bug fixed in this pass

`um:addEvent` previously shifted **both** `ppq` *and* `endppq` by
`delayToPPQ(delay)` when a non-zero delay was on the payload. Shifting
endppq is unrelated to any voice collision — it's a stale realisation
shift on a field that's intent. Today no caller passes `delay ≠ 0` to
`addEvent`, so it was unreachable; pinned by `tests/specs/
tm_clear_same_key_spec.lua` "F3 #3" so a future caller can't trip it.

### Acknowledged side effect (T1 territory, not F2)

**`resizeNote` deletes attached PAs that fall outside `[P1, P2)` on a
forward-delay edit (tm:325–341).** P1 = new realised onset, P2 =
unchanged endppq. PAs between old and new onset are orphaned. F2's
letter is preserved (the note's own fields are untouched). Flag for T1
to confirm this is the intended PA reseat behaviour.

---

## Detailed walk

### vm-side delay-only writers

Three sites in viewManager send `{ delay = ... }` and nothing else:

#### 1. `editEvent` stop 5–7 — vm:610–629 ✓

```lua
elseif stop == 5 or stop == 6 or stop == 7 then
  if not util.isNote(evt) then return end
  local old = evt.delay
  ...
  newDelay = sign * mag
  ...
  local minD, maxD = delayRange(col, evt)
  newDelay = util.clamp(newDelay, math.ceil(minD), math.floor(maxD))
  tm:assignEvent('note', evt, { delay = newDelay })
```

Update payload is exactly `{ delay = newDelay }`. ✓

#### 2. `nudgeDelay` — vm:1342–1347 ✓

```lua
local function nudgeDelay(col, note, dir, coarse)
  local minD, maxD = delayRange(col, note)
  local old = note.delay
  local new = util.nudgedScalar(old, math.ceil(minD), math.floor(maxD), dir, coarse and 10 or nil)
  if new ~= old then tm:assignEvent('note', note, { delay = new }) end
end
```

Same. ✓ Reachable from solo-cursor nudge and selection multi-nudge
(vm:1394–1399 calls `applyNudge` with `kind = 'delay'`).

#### 3. `queueResetDelays` (delete-on-delay-cell) — vm:1462–1468 ✓

```lua
local function queueResetDelays(col, locs)
  for _, evt in pairs(locs) do
    if evt.type ~= 'pa' and evt.delay ~= 0 then
      tm:assignEvent('note', evt, { delay = 0 })
    end
  end
end
```

Same. ✓

**No other vm path sends a pure `{ delay = ... }` update.** Other paths
that touch delay (`reswingCore`'s post-clamp at vm:1062,
`quantizeKeepRealisedScope` at vm:1166) bundle delay with ppq/ppqL/
frame and are not delay-only edits — F2 doesn't apply.

### tm-side: `assignEvent` → `realiseNoteUpdate` → `assignNote` → `resizeNote`

#### `realiseNoteUpdate` — tm:451–459 ✓

```lua
local function realiseNoteUpdate(evt, update)
  local dOld = delayToPPQ(evt.delay)
  local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
  if update.ppq ~= nil then
    update.ppq = update.ppq + dNew
  elseif dNew ~= dOld then
    update.ppq = evt.ppq + (dNew - dOld)
  end
end
```

For a delay-only edit (`update = { delay = newDelay }`):
- `dOld = delayToPPQ(evt.delay)` (integer; round-at-source)
- `dNew = delayToPPQ(newDelay)` (integer)
- `update.ppq` is nil → `elseif` branch → `update.ppq = evt.ppq + (dNew - dOld)`

`evt.ppq` here is um's REALISED ppq (`um:init` reads from `mm:notes()`
verbatim). So new realised = old realised + (dNew - dOld) = old intent
+ dNew. ✓ Integer bijection preserved.

`realiseNoteUpdate` only writes `update.ppq`. ✓ `ppqL`, `endppqL`,
`endppq`, `frame` untouched at this stage.

#### `um:assignEvent`'s clearSameKeyRange branch — tm:466–489 ⚠️ latent

```lua
function um:assignEvent(evtType, evtOrLoc, update, opts)
  ...
  if evtType == 'note' then
    if evt then
      realiseNoteUpdate(evt, update)
      if not (opts and opts.trustGeometry)
         and (update.pitch ~= nil or update.ppq ~= nil or update.endppq ~= nil) then
        local P     = update.ppq    or evt.ppq
        local Pend  = update.endppq or evt.endppq
        local pitch = update.pitch  or evt.pitch
        local clamped = clearSameKeyRange(evt.chan, pitch, P, Pend, evt)
        if clamped ~= Pend then update.endppq = clamped end
      end
      assignNote(evt, update)
```

After `realiseNoteUpdate` adds `update.ppq`, the gate `update.ppq ~=
nil` is true and `clearSameKeyRange` runs even for delay-only edits.

`clearSameKeyRange` (tm:412–428):

```lua
elseif clampEnd and n.ppq > P and n.ppq < clampEnd then
  clampEnd = n.ppq
```

For a delay-only edit, `P = update.ppq = newRealised`, `Pend =
evt.endppq` (intent). `n.ppq` is the *realised* ppq of a same-pitch
sibling (since `notesByLoc` stores realised). So the check is
"realised onset of any same-pitch sibling falls strictly between our
new realised onset and our intent endppq".

By V1, same-pitch siblings have disjoint *intent* intervals — so the
sibling's intent ppq is ≥ our `endppq`. But `n.ppq` here is realised,
not intent. **If the sibling has a negative delay, sibling.realised <
sibling.intent**, so realised could fall inside our `(newRealised,
intentEndppq)` window. In that case `clamped < Pend` and `update.endppq
= clamped` is set — an **F2 violation**.

Reachable but unlikely: requires a same-pitch sibling at exactly the
intent boundary with a negative delay large enough to bring its
realised onset back into our endppq range. The vm-side `delayRange`
doesn't bound against next-same-pitch from other columns, so this gap
isn't pre-emptively closed.

#### `assignNote` → `resizeNote` — tm:384–410, 325–382

`assignNote` (tm:384):

```lua
if update.ppq ~= nil or update.endppq ~= nil then
  resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq)
  update.ppq, update.endppq = nil, nil
end
...
if next(update) then assignLowlevel('note', n, update) end
```

For delay-only post-realiseNoteUpdate, `update = { delay, ppq }`. After
`resizeNote(n, newRealised, n.endppq)`, ppq/endppq cleared from
`update`. Then `assignLowlevel('note', n, { delay = newDelay })` writes
delay only. ✓ ppqL/endppqL/frame never touched.

`resizeNote` non-col-1 (tm:343–346):

```lua
if not col1 then
  assignLowlevel('note', n, { ppq = P1, endppq = P2 })
  return
end
```

`P2 = n.endppq` (unchanged) — written through `assignLowlevel` but
semantically unchanged. ✓ endppq byte-identical post-flush.

`resizeNote` col-1 (tm:348–382):

```lua
local oldppq = n.ppq
local D   = n.detune
local L   = logicalAt(n.chan, P1)
local C1  = detuneBefore(n.chan, oldppq)
local NP1 = nextNotePPQ(n.chan, oldppq)
local oldPb = pbAt(n.chan, oldppq)

assignLowlevel('note', n, { ppq = P1, endppq = P2 })
...
-- pb absorber dance: delete at oldppq, reseat at P1
```

ppq=P1 (new realised), endppq=P2 (= n.endppq, unchanged). ✓ endppq
byte-identical post-flush. ppqL/endppqL/frame: never named, never
touched.

The pb absorber dance moves the fake pb from oldppq to P1 — that's a
pb side effect (T1 territory, not F2's concern about the note's own
fields).

#### PA deletion in `resizeNote` — tm:325–341 ⚠️ flag for T1

```lua
local function resizeNote(n, P1, P2)
    local col1  = n.lane == 1
    local shift = P1 - n.ppq
    if shift ~= 0 and P2 - n.endppq == shift then
      forEachAttachedPA(n, function(evt)
        assignLowlevel('pa', evt, { ppq = evt.ppq + shift })
      end)
    else
      local lastPA
      forEachAttachedPA(n, function(evt)
        if evt.ppq <= P1 or evt.ppq >= P2 then
          ...
          deleteLowlevel('pa', evt)
        end
      end)
      ...
    end
```

For delay-only: `shift = P1 - n.ppq = dNew - dOld ≠ 0`, but `P2 -
n.endppq = 0 ≠ shift` (assuming nonzero delta). So the first branch
(uniform PA shift) is skipped, and PAs outside `[P1, P2)` are deleted.

For positive delay deltas, PAs that sat at `evt.ppq < P1` (between
old realised onset and new realised onset) are orphaned and deleted.
For negative delta, P1 < oldppq, and PAs at `evt.ppq >= n.ppq > P1`
all satisfy `evt.ppq > P1`; combined with `evt.ppq < P2`, no PAs
deleted.

**Not an F2 violation** — F2's named fields (`ppqL`, `endppqL`,
`endppq`, `frame`) on the note itself are untouched. But it's a
side-effect that callers may not expect; flag for **T1** to confirm
this PA reseat semantics is intended.

### Integer bijection

`timing.delayToPPQ` (timing.lua:270):

```lua
function M.delayToPPQ(d, res)
  return util.round(res * (d or 0) / 1000)
end
```

Rounds at source → integer-valued for any rational `d`. `evt.ppq` is
integer (REAPER's ppq space). `update.ppq = evt.ppq + (dNew - dOld)`
stays integer. ✓

The reverse map `ppqToDelay` is `1000 * p / res` (no rounding) and is
used only for bound math (`delayRange`), not for round-tripping. The
"integer bijection" in F2 refers to the forward direction `delay →
ppq`, which holds.

### Summary of writers actually touching F2's named fields

| Field    | Writers in delay-only path                          |
|----------|-----------------------------------------------------|
| `ppq`    | `realiseNoteUpdate` (tm:454–458) ✓ deliberately     |
| `endppq` | `clearSameKeyRange` clamp branch (tm:480) ⚠️ edge  |
| `ppqL`   | none ✓                                              |
| `endppqL`| none ✓                                              |
| `frame`  | none ✓                                              |

Common-case clean. The single latent gap is the `clearSameKeyRange`
clamp under negative-delay same-pitch siblings.
