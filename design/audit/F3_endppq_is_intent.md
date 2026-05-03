# F3 — endppq is intent at every layer  ✅ RESOLVED

**Invariant**: `endppq` is intent at mm, tm, vm storage. Only `ppq`
carries the realisation/intent split. `tm:rebuild`'s `tidyCol` strips
delay only from `ppq`, never from `endppq`.

**Falsifying test (per the doc)**: `tm:addEvent('note', { …, delay =
500 })` directly; after rebuild, expect `endppq` unchanged from the
caller's value.

---

## Resolution

Of the three findings the original audit listed, only one was a real
F3 violation. (1) and (2) confused intent semantics with the
realised-space MIDI voice constraint; (3) was a real shift bug.

### Re-examined: (1) and (2) are NOT F3 violations

The audit treated `clearSameKeyRange`'s truncate-to-`P` (1) and
clamp-to-`n.ppq` (2) as endppq-stained-with-realised. But MIDI's
single-voice-per-`(chan, pitch)` rule lives in realised space — when a
realised collision forces a note to shorten, the new endppq IS the
moment we now intend to end. F3 says "endppq is intent at every
layer" in the sense of "delay never bakes into endppq"; it doesn't say
"endppq's value can't be derived from realised geometry". CSK
deliberately works in realised space and writes the collision point
into endppq — that's correct.

vm-side `delayRange` is the gate that prevents user-driven edits from
ever creating these collisions, so on the user-visible surface F3 is
trivially preserved. See `docs/trackerManager.md` (Single voice per
(chan, pitch) — realised space) for the policy.

### Fixed: (3) `um:addEvent` shifted endppq by delay

```lua
if d ~= 0 then
  evt.ppq = evt.ppq + d
  if evt.endppq then evt.endppq = evt.endppq + d end   -- ❌ removed
end
```

Adding `d` to `endppq` is unrelated to any voice collision — it's
just a stale parallel of the ppq shift on a field that's intent. The
fix drops the endppq shift; ppq still shifts to realised, and CSK then
runs in its proper realised-vs-intent shape (P realised, Pend intent).

Unreachable today (no caller passes `delay ≠ 0` to addEvent), but
pinned by `tests/specs/tm_clear_same_key_spec.lua` "F3 #3" so a future
caller can't trip it.

---

## Detailed walk

### vm endppq writers — all intent ✓

| line | site                       | source of value                  | space  |
|------|----------------------------|----------------------------------|--------|
| 306  | `stamping.endppq`          | `ctx:rowToPPQ(rowE, chan)`       | intent |
| 506  | `placeNewNote` truncate-last | `update.ppq` (cursorppq)       | intent |
| 511  | `placeNewNote` new endppq  | `next.ppq or length`             | intent |
| 555  | `editEvent` snap path      | `ctx:rowToPPQ(endppqL/lpr)`      | intent |
| 827  | `applyNoteOff` undo        | `next.ppq or length`             | intent |
| 836  | `applyNoteOff` set         | `clamp(targetppq, ...)`          | intent |
| 894  | `adjustDurationCore`       | `clamp(rawPPQ, ...)`             | intent |
| 1080 | `reswingCore`              | `round(target.fromLogical(...))` | intent |
| 1216 | `shiftEvent`               | `round(swing.fromLogical(...))`  | intent |
| 1242 | `insertRowCore` spanning   | `round(swing.fromLogical(...))`  | intent |
| 1264 | `deleteRowCore` spanning   | `round(swing.fromLogical(...))`  | intent |
| 1272 | `deleteRowCore` clip       | `C = ctx:rowToPPQ(topRow)`       | intent |
| 1434 | `queueDeleteNotes` fixup   | `evt.ppq` (next survivor's intent) | intent |
| 1447 | `queueDeleteNotes` fixup   | `length`                         | intent |

`ctx:rowToPPQ` and `swing.fromLogical` both produce intent ppq.
`col.events` after `tidyCol` carry intent ppq. ✓

### ec endppq writers — all intent ✓

| line | site                         | source of value                    | space  |
|------|------------------------------|------------------------------------|--------|
| 647  | `pasteSingle` materialise    | `ctx:rowToPPQ(...)` clamped to endppq | intent |
| 674  | `pasteSingle` truncate-last  | `events[1].ppq`                    | intent |
| 690  | `pasteSingle` new note       | `ce.endppq or nextNotePPQ`         | intent |
| 800  | `pasteMulti` materialise     | `ctx:rowToPPQ(...)`                | intent |
| 817  | `pasteMulti` truncate-last   | `events[1].ppq`                    | intent |
| 845  | `pasteMulti` new note        | `e.endppq or capPPQ`               | intent |

All values flow from `ctx:rowToPPQ` (intent) or events already in
intent space. ✓

### tm endppq writers — three paths

#### `resizeNote` — tm:344, 358 ✓ intent passthrough

```lua
assignLowlevel('note', n, { ppq = P1, endppq = P2 })
```

`P2 = update.endppq or n.endppq`. `update.endppq` from caller is
intent (per vm/ec audit above); `n.endppq` is um's stored value, also
intent (mm doesn't bake delay into endppq, and um's `init` reads
mm:notes() verbatim — for endppq this is already intent). ✓

#### `clearSameKeyRange` truncate — tm:426 ❌ writes realised

```lua
local function clearSameKeyRange(chan, pitch, P, Pend, selfEvt)
    ...
    for _, n in pairs(notesByLoc) do
      if n ~= selfEvt and n.chan == chan and n.pitch == pitch then
        if n.ppq <= P and n.endppq > P then
          if n.ppq == P then util.add(toDelete, n)
          else util.add(toTruncate, n) end
        ...
    for _, n in ipairs(toTruncate) do assignNote(n, { endppq = P }) end
```

Truncated sibling's `endppq` is set to `P`. `P` is the second arg to
`clearSameKeyRange`. From `um:assignEvent` (tm:476):

```lua
local P = update.ppq or evt.ppq
```

After `realiseNoteUpdate` runs at tm:473, `update.ppq` is realised
(intent + dNew). So `P = realised onset of selfEvt`.

When `selfEvt.delay ≠ 0`, `P_realised ≠ P_intent`. Setting truncated
sibling's `endppq = P_realised` writes a realised value into endppq —
**F3 violation**.

After flush, mm stores the note with this realised endppq. On rebuild,
`tidyCol` only subtracts delay from `ppq`, not `endppq`, so the
sibling's endppq stays at our realised onset and never recovers.

**Reachability**:
- pitch change (`tm:assignEvent('note', evt, { pitch })`) on a delayed
  note that creates same-pitch collision: gate is `update.pitch ~=
  nil`, so clearSameKeyRange runs; if a sibling has the new pitch,
  truncate writes realised
- ppq change on a delayed note: `realiseNoteUpdate` makes
  `update.ppq = newIntent + dNew = realised`, P = realised, same issue
- delay change creating overlap (V1's edge case): same

In addEvent path (tm:501), `clearSameKeyRange` is called with
`evt.ppq` *after* the realised shift at tm:498:

```lua
if d ~= 0 then
  evt.ppq = evt.ppq + d
  if evt.endppq then evt.endppq = evt.endppq + d end
end
evt.endppq = clearSameKeyRange(evt.chan, evt.pitch, evt.ppq, evt.endppq, evt)
```

So P = realised here too. Truncated sibling's endppq = our realised
onset. Same F3 violation, but unreachable today since no caller passes
delay≠0 to addEvent (see (3) below).

#### `clearSameKeyRange` clamp + `update.endppq = clamped` — tm:480 ❌ writes realised

```lua
elseif clampEnd and n.ppq > P and n.ppq < clampEnd then
  clampEnd = n.ppq
end
...
return clampEnd
```

And caller:

```lua
if clamped ~= Pend then update.endppq = clamped end
```

`clampEnd` starts at `Pend = update.endppq or evt.endppq` (intent).
The clamp replaces it with `n.ppq` from `notesByLoc`, which for col-1
notes is **realised**. So `clamped` becomes a realised value, then
`update.endppq = clamped` writes that realised value into our endppq.

**Reachability**: same gate as F2's latent #1 — a same-pitch sibling
with negative delay (or some other delay arrangement) whose realised
onset falls strictly between our `P` and our `Pend`. Edge case but
real.

#### `um:addEvent` delay-shift — tm:491–502 ❌ but unreachable

```lua
function um:addEvent(evtType, evt)
  if evtType == 'note' then
    evt.detune = evt.detune or 0
    evt.delay  = evt.delay  or 0
    evt.lane   = evt.lane   or 1
    local d = delayToPPQ(evt.delay)
    if d ~= 0 then
      evt.ppq = evt.ppq + d
      if evt.endppq then evt.endppq = evt.endppq + d end    -- ❌ F3
    end
    evt.endppq = clearSameKeyRange(evt.chan, evt.pitch, evt.ppq, evt.endppq, evt)
    addNote(evt)
```

Adding `d` to `endppq` violates F3 directly. The doc flags this and
says "now pinned by the fix in this branch" — but the *code* I'm
reading still has the line. I read this as "pinned by a regression
test" rather than "the code's been fixed". The bug is real but
unreachable: every `tm:addEvent('note', ...)` caller passes no `delay`
field (defaulting to 0):

| call site                 | delay in payload? |
|---------------------------|-------------------|
| `placeNewNote` (vm:515)   | no — built from new-note `update` at vm:588–593 with no delay |
| `pasteSingle` (ec:688)    | no — `tm:addEvent('note', { ppq, endppq, ppqL, endppqL, chan, pitch, vel, lane, frame })` |
| `pasteMulti` (ec:844)     | no — same shape |

Confirmed unreachable. But the bug is in the code; should be fixed in
the cleanup pass alongside (1) and (2).

### Summary of writers

| writer                              | space written         | F3       |
|-------------------------------------|-----------------------|----------|
| vm × 14 sites                       | intent                | ✓        |
| ec × 6 sites                        | intent                | ✓        |
| tm `resizeNote` (×2)                | intent passthrough    | ✓        |
| tm `clearSameKeyRange` truncate     | **realised** when delay≠0 | ❌ reachable |
| tm `clearSameKeyRange` clamp → assignEvent | **realised** in edge case | ❌ reachable |
| tm `um:addEvent` delay-shift        | **realised** if delay≠0 passed | ❌ unreachable today |

Three F3 bugs in the same family: `clearSameKeyRange` and `um:addEvent`
both blur the realised/intent boundary on writes to `endppq`. The
underlying root cause is that `notesByLoc` stores **realised ppq /
intent endppq** for col-1 notes (mixed semantics from mm), and code
that reads `n.ppq` from there and feeds it into endppq writes is
crossing the streams.
