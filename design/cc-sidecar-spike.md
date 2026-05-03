# CC sidecar carrier spike

**Status:** spec, not started. **Blocks:** `cc-sidecar-metadata.md`
implementation. **Scope:** mm only — no design code lands until the
carrier is proven.

## Goal

Confirm that REAPER round-trips the proposed sidecar sysex byte-for-byte
through every project operation a user might perform. If any operation
mangles the bytes or loses events, the carrier choice changes — the
design assumes sysex is a transparent free-form channel, and that has
to be verified before any of the metadata machinery is built.

## Carrier under test

```
F0 7D 'R' 'D' 'M' <type> <chan> <cc#> <val_lo7> <val_hi7> <uuid...> F7
```

For the spike, use a fixed payload so byte-equality is trivial to assert:

```
F0 7D 52 44 4D 0B 00 07 40 00 41 42 F7
   |  ----R/D/M-----  ^^ ^^ ^^ ^^ ^^ ^^ uuid base36 = "AB"
                      |  |  |  |  +- val_hi7 = 0
                      |  |  |  +---- val_lo7 = 0x40 (64)
                      |  |  +------- cc# = 7 (volume)
                      |  +---------- chan = 0
                      +------------- type = 0x0B (cc)
```

13 bytes total on disk / on wire. Per REAPER's API docs,
`MIDI_InsertTextSysexEvt` with `type = -1` expects the msg **without**
F0..F7 — REAPER adds the framing itself on serialise.
`MIDI_GetTextSysexEvt` returns the unframed body. So mm reads and
writes the 11-byte body; the framed form is what appears in the .rpp
and on the wire.

**Status:** spike run 2026-04-27, all programmatic ops pass against
the unframed-API path. Op 13 (.rpp hex grep) deferred for manual
closure but ops 2/3/4 (save+close+reopen) imply it.

## Operations to exercise

For each operation: insert sidecar(s), perform op, read back, assert.

| # | Operation | Acceptance |
|---|---|---|
| 1 | Insert sidecar via `MIDI_InsertTextSysexEvt(take, false, false, ppq, -1, payload)`, immediately re-read via `MIDI_GetTextSysexEvt`. | Bytes match exactly. ppq matches. |
| 2 | Save project, close REAPER, reopen, re-read. | As (1). |
| 3 | Insert two sidecars at different ppqs in one take, save+reload. | Both present, both at correct ppqs, bytes intact, ordering deterministic. |
| 4 | Insert sidecar at ppq P + a coincident cc at ppq P, save+reload. | Both events present at P. Coincidence preserved. |
| 5 | Insert sidecar in item A; create adjacent empty item B; glue A+B. | Sidecar present in glued item. ppq translation matches the item-start translation applied to ccs. |
| 6 | Insert sidecar in single item at ppq P; split item at ppq Q where Q < P. | Sidecar present in right-half item at translated ppq (P − Q). |
| 7 | Insert sidecar at ppq Q < split point; split. | Sidecar present in left-half item at original ppq. |
| 8 | Sidecar straddling split point — i.e. sidecar at exactly the split ppq. | Document REAPER's behaviour. Goes left, right, or duplicated? Pick whichever is consistent and design around it. |
| 9 | Item duplicated in arrange view (Ctrl-D / drag-copy). | Sidecar present in both copies, bytes intact. **Note for design:** duplicated items mean duplicated uuids in the global namespace — flag as known case for reload-time uuid collision handling. |
| 10 | Glue item containing sidecar with adjacent item also containing sidecars (with different uuids). | All sidecars present, all bytes intact, ppqs translated correctly. |
| 11 | "Apply track FX as new take" / freeze-style operations on the track. | Document whether the new take inherits sidecars. (Likely no — these render to audio; covered for awareness, not as a pass criterion.) |
| 12 | Drag sidecar's parent item to a different track. | Sidecar moves with item. |
| 13 | Save under .rpp, externally inspect file for the sidecar bytes (hex dump). | Bytes appear in the project file (sanity that .rpp serialisation isn't dropping unknown sysex). |

## Open API questions to resolve

These are blockers if unresolved — they affect what bytes the spike asserts on.

- **Framing:** does `MIDI_InsertTextSysexEvt` with `eventtype = -1` (sysex) expect the payload *with* `F0...F7` framing, or *without*? The native MIDI semantics include framing; REAPER's APIs are sometimes opinionated. Check by inserting both framed and unframed forms and reading back to see which round-trips.
- **Manufacturer ID:** verify `7D` is treated as a valid sysex byte (it should — non-commercial range is reserved for exactly this). Confirm no REAPER-side warning or sanitisation.
- **`MIDI_GetTextSysexEvt` byte interpretation:** confirm the returned `msg` is raw bytes (a Lua string), not text-decoded. The existing sysex round-trip in mm at midiManager.lua:399–406 reads them as `val` strings — same path.

## Pass / fail

**Pass:** all operations 1–10 round-trip the sidecar bytes exactly with correct ppq translation. Operations 11–13 inform design decisions but are not pass criteria.

**Fail:** any operation drops, modifies, or reorders bytes. If any of:

- **Bytes corrupted:** carrier is wrong. Look for an alternative — text events with a structured prefix? notation events with a non-NOTE prefix?
- **Events dropped:** sysex isn't a reliable carrier. Reconsider whether to attach sidecars to *coincident text events* on a per-cc basis instead.
- **ppq translation broken:** design needs an additional reconciliation tier or a smarter binding strategy. Worth knowing before committing.

A fail on operation 8 (straddle) is design-informing rather than blocking — adapt the design around whatever REAPER does.

## Form of the spike

A standalone REAPER action script (`tests/spike_sidecar.lua` or
similar) that:

1. Creates a fresh empty MIDI item.
2. Runs each operation programmatically where possible (1–4, 9, 10, 12).
3. For the operations that need user interaction (5–8, 11, 13), prints
   instructions and waits, then re-reads and reports.
4. Prints a pass/fail line per operation.

Operations 5–8 (glue/split) can be partially automated via
`reaper.Main_OnCommand` with the relevant action IDs, but split-at-ppq
requires the edit cursor to be set first — easier to write as a
prompted step.

Total time estimate: 1–2 hours including the manual steps.

## Output of the spike

A short writeup: pass/fail table, any surprises (op 8 outcome, framing
decision), and a green-light or recommendation to revise the design's
carrier choice.
