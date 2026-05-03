# F1 — ppqL pinning  ✅ FIXED

**Invariant**: every authored event with a `frame` stamps
`evt.ppqL = row · logPerRow_frame`. For an event whose `ppqL` is an
integer multiple of `logPerRow_frame`,
`ctx:rowToPPQ(row, chan) == evt.ppq` exactly.

**Falsifying test (per the doc)**: author a note at row r, then read
back `ppqL`; expect `r · logPerRow_currentFrame`.

This audit walks every site in viewManager (and editCursor's clipboard)
that writes `ppqL` or `endppqL`.

---

## Resolution

All three classes of bug below are fixed. The unifying invariant —
**`(ppqL, endppqL, frame)` are a unit; updates preserve the pairing**
— is now structurally enforced for tail rewrites (the new
`assignTail` helper folds the assign + frame restamp into one call,
so writing `endppqL` alone requires bypassing it) and policy-named
for PAs (`paFrame(host, chan)` builds the canonical hybrid: host's
swing slots, current's rpb).

| Class | Sites | Pattern |
|---|---|---|
| A — partner-field omission | 2 paste truncate-last | Write `endppqL` alongside `endppq` |
| B — frame/logical incoherence | 9 tail-rewrite sites + `quantizeKeepRealised` + `reswingCore` restamp | `assignTail` for tail rewrites; explicit endppqL re-derive in quantize; `reswingCore` rebases ppqL/endppqL by logPerRow ratio when frame restamps |
| C — PA frame policy | 2 PA emitters (`editEvent`, `pasteVelocities`) | `paFrame(host, chan)` — host swing/colSwing, current rpb |

Regression tests in `tests/specs/vm_logical_ppq_spec.lua`, each
individually verified to fail without its respective fix.

---

## Verdict summary  *(historical — bugs below all addressed above)*

**Holds in the common case (frame.rpb stable across the take's
lifetime).** In every authoring path, when no rpb change has occurred,
`evt.ppqL = author_row · logPerRow_currentFrame` and the falsifying
test passes.

### Real F1 bugs (unconditional)

1. **`pasteSingle` truncate-last (ec:673–675)** and
   **`pasteMulti` truncate-last (ec:815–818)** write `endppq` without
   writing `endppqL`. The note's tail goes from on-grid to off-grid
   silently. **This bug holds even when frames match — the simplest fix
   target.**

### Real F1 bugs (cross-rpb only — common-case-clean)

These re-stamp `endppqL` (or `ppqL`) without re-stamping `frame`, so a
note authored at rpb=A and edited at rpb=B ends up with `frame.rpb=A`
but ppqL/endppqL fields in coordinates that don't match A's logPerRow:

- `applyNoteOff` (vm:826–828, 835–838) — endppqL written, frame not.
- `adjustDurationCore` (vm:893–897) — endppqL written, frame not.
- `insertRowCore` spanning extension (vm:1241–1244) — endppqL written,
  frame not.
- `deleteRowCore` spanning trim/clip (vm:1263–1274) — endppqL written,
  frame not.
- `queueDeleteNotes` survivor extension (vm:1432–1448) — endppqL pulled
  from *next survivor's* ppqL; frame not updated. Cross-frame stitching.
- `placeNewNote` truncate-last (vm:505–508) — last note's endppqL set
  to new note's ppqL; last's frame not updated.
- `quantizeKeepRealisedScope` (vm:1149–1184) — start ppq/ppqL/frame
  rewritten via `at(newRow)`, but `endppqL` is left untouched. Frame and
  endppqL desync when rpbs differ.
- `reswingCore` with `restamp` (vm:1077–1083) — frame restamped to
  current; ppqL/endppqL not touched. If source rpb ≠ current rpb,
  post-reswing ppqL is in old-rpb units while frame says current.

### Acknowledged "benign approximation"

- `editEvent`'s PA write (vm:656–661) and `pasteVelocities`'s PA write
  (ec:612–617): PA stamps `ppqL = cursorppqL` (current logPerRow) but
  `frame = note.frame` (host's). Code comment at vm:652–655 explicitly
  acknowledges this as "benign approximation"; strictly violates F1 when
  `host.frame.rpb ≠ current rpb`.

---

## Detailed walk

### 1. `stamping(chan)` — vm:299–311 ✓

```lua
local s = { ppq = ctx:rowToPPQ(rowS, chan),
            ppqL = rowS * logPerRow,
            frame = f }
```

`f = currentFrame(chan)`, `logPerRow = logPerRowFor(f.rpb)`. Holds by
construction: `ppqL/logPerRow_f = rowS`.

### 2. `editEvent` snap path — vm:548–558 ✓ in common case

```lua
update.ppq = cursorppq
update.ppqL = cursorppqL    -- = ec:row() * logPerRowNow
update.frame = frameNow
```

`cursorppqL = ec:row() · logPerRowNow` and `frameNow.rpb = current rpb`,
so `ppqL/logPerRow_frame = ec:row()` (integer). ✓

For notes the off-grid path also writes
`endppqL = cursorppqL + (endLogical - logical)`. Common case ✓.

⚠️ **Edge case**: if `evt.frame.rpb ≠ current rpb`, then
`evt.endppqL - evt.ppqL` is in *evt's* logPerRow units, so the new
`endppqL` is not an integer multiple of `logPerRow_current`. The
on-grid round-trip property of the tail fails.

### 3. `editEvent`'s new-note via `placeNewNote` — vm:588–593, 501–516

```lua
local new = { ppq = cursorppq, ppqL = cursorppqL, ..., frame = frameNow }
placeNewNote(col, new)
```

Inside placeNewNote:

```lua
update.endppqL = ctx:ppqToRow(update.endppq, update.chan)
                 * logPerRowFor(update.frame.rpb)
```

`update.frame.rpb = current rpb`, ✓.

⚠️ Truncate-last branch (vm:505–508):

```lua
tm:assignEvent('note', last, {
  endppq = update.ppq,
  endppqL = update.ppqL,
})
```

Sets `last.endppqL = update.ppqL` but leaves `last.frame` alone. **F1
violation when last was authored at a different rpb than current.**

### 4. `editEvent`'s PA write — vm:656–661 ⚠️ acknowledged

```lua
tm:addEvent('pa', {
  ppq = cursorppq, ppqL = cursorppqL,    -- current logPerRow
  chan = col.midiChan,
  pitch = note.pitch, val = val,
  frame = note.frame,                     -- HOST'S frame
})
```

Comment at vm:652–655 acknowledges as "benign approximation". Strictly
violates F1 when `note.frame.rpb ≠ current rpb`.

### 5. `editEvent`'s non-note path — vm:689–697 ✓

```lua
util.assign(update, {
  ppq = cursorppq, ppqL = cursorppqL,
  chan = col.midiChan, frame = frameNow,
})
tm:addEvent(type, update)
```

Frame and ppqL both in current. ✓

### 6. `moveLaneEvent` — vm:710–738 ✓

```lua
local f, logPerRow = frameAndLogPerRow(chan)
tm:assignEvent(col.type, evt, {
  val = toVal,
  ppq = newppq,
  ppqL = newRow * logPerRow,
  frame = f,
})
```

When `toRow` is integer and unclamped, `newRow = toRow` (integer) ✓.
When clamped, `newRow = ctx:ppqToRow(newppq)` (fractional); F1 part 2
vacuously true. Internally consistent. ✓

### 7. `applyNoteOff` — vm:818–840 ⚠️ cross-rpb

```lua
local logPerRow = ctx:ppqPerRow()
local function endLogical(ppq)
  return ctx:ppqToRow(ppq, col.midiChan) * logPerRow
end
...
tm:assignEvent('note', last, {
  endppq = newEnd,
  endppqL = endLogical(newEnd),
})
```

Frame not updated. ⚠️ **F1 violation when `last.frame.rpb ≠ current
rpb`.**

### 8. `adjustDurationCore` — vm:883–898 ⚠️ cross-rpb

```lua
local logPerRow = ctx:ppqPerRow()
...
tm:assignEvent('note', note, {
  endppq = newppq,
  endppqL = newppq == rawPPQ and newRow * logPerRow
                        or ctx:ppqToRow(newppq, chan) * logPerRow,
})
```

Same pattern as applyNoteOff. ⚠️

### 9. `adjustPosition` (single) — vm:970–995 ✓

```lua
tm:assignEvent('note', note, stamping(chan)(newStart, newEnd))
```

Integer rows + `stamping` updates everything (ppq, ppqL, endppq,
endppqL, frame). ✓

### 10. `adjustPositionMulti` — vm:916–958 ✓ (with G1 caveat)

```lua
local rowS = ctx:ppqToRow(n.ppq, chan) + rowDelta
local rowE = ctx:ppqToRow(n.endppq, chan) + rowDelta
tm:assignEvent('note', n, at(rowS, rowE))
```

If `n` was on-grid in current frame, `rowS` is integer ✓. If `n` was
off-grid, `rowS` is fractional; F1 holds (ppqL & frame mutually
consistent), but the off-grid offset is preserved rather than snapped
— flag for G1.

### 11. `quantizeScope` — vm:1122–1142 ✓

```lua
local newRow = util.round(sRow)
tm:assignEvent('note', e, at(newRow, newEndRow))
```

Integer rows + `at = stamping`. ✓

### 12. `quantizeKeepRealisedScope` — vm:1149–1184 ⚠️ cross-rpb

```lua
local at = stamping(chan)
...
local s = at(newRow)              -- ppq, ppqL, frame for start only
s.ppq, s.delay = newppq, newDelay
tm:assignEvent('note', e, s)
```

`at(newRow)` rewrites only start fields + frame; `endppqL` is **not**
touched. Frame=current paired with stale endppqL → desync when
rpbs differ. ⚠️

### 13. `reswingCore` — vm:1020–1092 ⚠️ cross-rpb

```lua
entry.newppq = round(tgt.fromLogical(chan, e.ppqL))
entry.newEndppq = round(tgt.fromLogical(chan, e.endppqL))
if opts.restamp then entry.newFrame = opts.restamp(chan) end
...
if p.newppq ~= e.ppq then u.ppq = p.newppq end
if p.newEndppq ~= e.endppq then u.endppq = p.newEndppq end
if p.newFrame ~= nil then u.frame = p.newFrame end
```

ppqL/endppqL **not** rewritten. Frame rewritten (to current, when
reswingScope) — ppq is recomputed via `target.fromLogical(e.ppqL)`.
Common case ✓; cross-rpb leaves ppqL in old-rpb units alongside
frame=current. ⚠️

### 14. `insertRowCore`/`deleteRowCore`'s `shiftEvent` — vm:1205–1219 ✓ in common case

```lua
local newppqL = logicalOf(e) + dLogical    -- dLogical = numRows · logPerRow_currentFrame
local update = { ppq = round(swing.fromLogical(chan, newppqL)),
                 ppqL = newppqL, frame = f }
```

Frame updated to current. If `e.frame.rpb == current.rpb`,
`newppqL = (oldRow + numRows) · logPerRow_current` ✓.

⚠️ Cross-rpb case: `newppqL` mixes two different `logPerRow` values.

### 15. `insertRowCore`/`deleteRowCore`'s spanning note tail — vm:1240–1245, 1262–1273 ⚠️ cross-rpb

```lua
tm:assignEvent('note', spanning, {
  endppq = ...,
  endppqL = newendppqL,    -- or topppqL = topRow · logPerRow_currentFrame
})
```

Frame **not** updated. ⚠️

### 16. `queueDeleteNotes` survivor extension — vm:1431–1448 ⚠️ cross-rpb

```lua
util.add(fixups, {
  evt = lastSurvivor,
  endppq = evt.ppq,
  endppqL = evt.ppqL or ctx:ppqToRow(evt.ppq, col.midiChan) * logPerRow,
})
```

Sets `lastSurvivor.endppqL` to the *next survivor's* ppqL (or a
current-frame `ppqToRow`). Frame **not** updated. ⚠️ Cross-frame
stitching: `lastSurvivor.frame` and the just-written `endppqL` may
live in different rpb-coordinate systems.

### 17. `clipboard.pasteSingle` — ec:644–649, 688–696 ✓ at note write

```lua
local e = util.assign({ ppq = ppq, ppqL = (r + ce.row) * logPerRow }, ce)
if ce.endRow then
  e.endppq = ...
  e.endppqL = eRow * logPerRow
end
...
tm:addEvent('note', { ..., ppqL = ce.ppqL,
                            endppqL = ce.endppqL or capEndppqL,
                            frame = frame, ... })
```

`logPerRow = ctx:ppqPerRow()` (current), `frame = currentFrame`. ✓

❌ **Truncate-last (ec:673–675) is broken unconditionally:**

```lua
if lastNote and events[1] and lastNote.endppq > events[1].ppq then
  tm:assignEvent('note', lastNote, { endppq = events[1].ppq })
end
```

**Only `endppq` is written; `endppqL` left stale.** Round-trip via
`ctx:ppqToRow(endppq) ≠ endppqL/logPerRow_current` after this edit,
*even when frames match*. **Real F1 violation.**

### 18. `clipboard.pasteMulti` — ec:815–818 ❌ same bug

```lua
if last and events[1] and last.endppq > events[1].ppq then
  tm:assignEvent('note', last, { endppq = events[1].ppq })
end
```

Identical: endppq written without endppqL.

### 19. `pasteVelocities`'s PA write — ec:612–617 ⚠️ acknowledged

```lua
tm:addEvent('pa', {
  ppq = ce.ppq, ppqL = ce.ppqL,        -- current logPerRow
  chan = ..., pitch = ..., val = ...,
  frame = note.frame,                    -- HOST'S frame
})
```

Same as editEvent's PA write — strictly violates F1 in cross-rpb case.
