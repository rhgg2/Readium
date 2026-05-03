---
status: ⚠️ HOLDS at the three snap callsites; spec is silent on stops that bypass snap
---

# G2 — Off-grid edits snap to cursor row  ⚠️ HOLDS at snap callsites; bypassed at three stops

**Invariant**: `editEvent` on an off-grid event repins `(ppq, ppqL,
frame)` to the cursor row in current frame; for notes, logical
duration (`endppqL − ppqL`) is preserved exactly.

**Falsifying scenario**: seed an off-grid note (e.g. via swing change
after authoring); type a new pitch over it from a different row;
expect the note's `ppq` and `ppqL` repinned to cursor row, and
`endppqL − ppqL` preserved.

---

## Verdict

The `snap` helper itself is correct: ppq goes to `cursorppq`
(on-grid by F4), ppqL goes to `ec:row() * logPerRowNow` (row-aligned
in current frame), frame restamps to current, and for notes
logical duration is preserved by literal arithmetic
(`update.endppqL = cursorppqL + (endppqL_old - ppqL_old)`).

But snap is wired into **three of the eight stops**. The other five
either bypass snap deliberately (delay, vel, octave) or short-circuit
before reaching it (return-early stops). That's not a bug per se —
the design intent appears to be "snap fires for stops that re-author
time, not for stops that edit metadata" — but the source-doc spec
doesn't distinguish, so this is a spec/code gap to settle.

### Snap callsites

| Stop                               | Site            | Calls snap? |
|------------------------------------|-----------------|-------------|
| stop 1 — pitch on existing note    | vm:740          | ✓           |
| stop 1 — pitch with no resident    | vm:761 (placeNewNote) | n/a (always lands at cursorppq via fresh-note path) |
| stop 2 — octave on existing note   | vm:774          | ✗           |
| stop 5/6/7 — delay on note         | vm:796          | ✗           |
| stop 0/3/4 — vel hex on note       | vm:812          | ✗           |
| stop 0/3/4 — vel hex on PA         | vm:807          | ✓           |
| stop 0–4 — val/shape on cc/at/pc/pb (existing) | vm:853 | ✓     |
| stop 0–4 — val/shape on cc/at/pc/pb (fresh) | vm:855–860 | n/a (lands at cursorppq via fresh path) |

So **three sites strictly satisfy G2** as written; **three sites
bypass snap on existing off-grid events** (octave, delay, vel on
notes); two are fresh-event paths that land at cursor by
construction.

### Findings

1. **Octave (stop 2) does not snap.** vm:773–775 runs
   `tm:assignEvent('note', evt, { pitch = pitch })` with no time
   repin. The user types an octave digit on an off-grid note → pitch
   shifts ±12, ppq stays off-grid. Inconsistent with stop 1 (pitch
   repitch), which *does* snap. Either octave should snap to match
   stop 1's repitch semantics, or stop 1's snap is itself the
   anomaly. Worth a design-review line.
2. **Delay (stops 5–7) does not snap.** Defensible: delay edits
   the realised offset relative to the existing intent ppq;
   repinning intent would change what "delay" is being applied to.
   But strict G2 says it should snap.
3. **Vel hex on note (stops 0/3/4) does not snap.** Defensible:
   velocity is independent of time, repinning would be surprising.
   But strict G2 says it should snap.

### Snap helper itself — vm:716–726 ✓

```lua
local function snap(update)
  if not evt or evt.ppq == cursorppq then return update end
  update.ppq         = cursorppq
  update.ppqL = cursorppqL
  update.frame       = frameNow
  if evt.endppq then
    update.endppqL = cursorppqL + (endLogicalOf(evt) - logicalOf(evt))
    update.endppq         = ctx:rowToPPQ(update.endppqL / logPerRowNow, col.midiChan)
  end
  return update
end
```

Trigger: `evt.ppq ~= cursorppq`. cursorppq is `rowToPPQ(ec:row(),
chan)` (vm:702), with `ec:row()` integer, so cursorppq is on-grid in
current frame. The trigger fires iff evt is off-grid relative to the
cursor row's on-grid ppq — which is exactly "evt is off-grid in
current frame" when the editor surfaced evt at the cursor row in the
first place.

Writes:

- `update.ppq = cursorppq` — on-grid by F4 ✓
- `update.ppqL = cursorppqL = ec:row() * logPerRowNow` — row-aligned
  in current frame ✓
- `update.frame = frameNow` — restamps so (ppqL, frame) is coherent
  in the new frame's logPerRow ✓
- `update.endppqL = cursorppqL + (endLogicalOf(evt) - logicalOf(evt))`
  — preserves logical duration exactly: `update.endppqL - update.ppqL
  = (cursorppqL + Δ) - cursorppqL = Δ = evt.endppqL - evt.ppqL` ✓
- `update.endppq = ctx:rowToPPQ(update.endppqL / logPerRowNow, chan)`
  — derives realised end from the new logical end via the new
  frame's row map. For same-rpb cases (the common one),
  `update.endppqL / logPerRowNow = ec:row() + (Δ / logPerRowNow) =
  integer`, so endppq lands on-grid in new frame. For cross-rpb
  cases where `Δ` isn't an integer multiple of newLogPerRow,
  endppq lands at a fractional row → off-grid endppq. Head still
  on-grid; tail off-grid by construction.

The cross-rpb case is a real but acknowledged trade: the spec says
"logical duration preserved exactly", and that's what the code does.
The price is that the endppq may be off-grid in the new rpb — but
endppq isn't on the on-grid bit (G1), so display still works, only
some downstream operations that assume "tail is integer-row" might
read the tail as fractional.

### Delay survives the snap ✓ (with note)

Snap doesn't write `update.delay`. tm-side `realiseNoteUpdate`
(tm:460–468) sees `update.ppq` set and computes
`update.ppq = update.ppq + dNew = cursorppq + delayToPPQ(evt.delay)`.
After tm strips delay on rebuild, vm sees `evt.ppq = cursorppq`. So
the **vm-side intent ppq is at cursor row** — G2 (which is intent-
space) holds.

The realised onset audibly sits at `cursorppq + delayToPPQ(delay)`,
not at cursorppq. This is consistent: delay is preserved by snap,
which means "the user's delay on the source event still applies after
repinning". A user who wanted realised-on-grid would have to also
zero the delay (Backspace on the delay column). Worth noting in
docs but not a G2 violation.

### CSK side effects on snap ✓

When stop 1 (pitch) repins via snap, CSK runs in tm:assignEvent
because `update.pitch` is in the patch (tm:484). It clears
`(chan, new_pitch)` overlaps in the realised range
`[cursorppq + delayToPPQ(delay), update.endppq]`. Same-pitch
siblings in that range get truncated or deleted. ✓ for V1; doesn't
affect G2.

### Rule to extract into docs

> **`editEvent`'s snap helper fires only for stops that re-author
> time** — pitch repitch on existing note, value write on PA, value
> write on cc/at/pc/pb existing event. Stops that edit metadata
> independent of time (octave, delay, vel hex on note) don't snap;
> off-grid sources stay off-grid through those edits.
>
> The G2 spec as written says "editEvent on an off-grid event repins"
> without distinguishing stops; the code's policy is narrower.
> Either the spec should be narrowed (snap-callsite stops only), or
> octave should snap to match stop 1's repitch behaviour. Octave is
> the borderline case worth a design call: it's a primary musical
> attribute like pitch, but the user might expect a quick ±12-semi
> shift without time movement. Delay/vel are clearer: snapping them
> would surprise users.
>
> **Snap preserves logical duration exactly**, not realised
> duration. Same-rpb cases land both head and tail on-grid; cross-
> rpb cases land the head on-grid but the tail at a fractional row
> in the new logPerRow. The trade is deliberate — duration in
> logical-ppq is the authoring-stable quantity.
>
> **Snap doesn't reset delay.** Delay carries through, so realised
> onset = `cursorppq + delayToPPQ(delay)`, not `cursorppq`. Intent
> goes to cursor row (G2's claim); realised stays delay-shifted.
> Document for users who expect realised-on-grid; G2 strict reading
> is intent-space, so this isn't a violation.

### Summary

| Aspect                                           | Verdict |
|--------------------------------------------------|---------|
| Snap helper writes (ppq, ppqL, frame)            | ✓       |
| Logical duration preserved exactly               | ✓       |
| Endppq lands on-grid in new frame (same-rpb)     | ✓       |
| Endppq lands on-grid in new frame (cross-rpb)    | ⚠️ tail off-grid by construction (preserves duration, not row alignment) |
| All editEvent stops repin off-grid sources       | ✗ — three stops bypass snap (octave, delay, vel) |
| Delay zeroed on snap                             | ✗ (preserved through repin) |
