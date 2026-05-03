# Clipboard Design

## Storage

Persisted to REAPER ExtState via `util:serialise`/`util:unserialise`, so the clipboard survives script restarts (close Continuum, navigate to another take, relaunch).

```lua
clipboard = {
  mode = "single" | "multi",
  numRows = N,             -- height of copied region in grid rows
  cols = {                  -- one entry per copied column, in order
    {
      type = "note"|"cc"|"pb"|"at"|"pa"|"pc"|"sx",
      id = <number|nil>,    -- column id (cc number, note col id, etc.)
      midiChan = <number>,  -- source channel (1-16)
      selGroups = {G1, G2}, -- which selection groups were included
      events = {            -- ALL events in range, including overflow
        { row = R, rowOffset = F, endRow = R2, endRowOffset = F2, <field = value, ...> },
        ...
      },
    },
  },
}
```

## Timing

The grid is a quantised view of continuous data. The clipboard operates on the underlying events, not grid cells. Both modes preserve exact timing.

Each event stores:
- `row` — relative row (1-based from selection top)
- `rowOffset` — fractional position within the row (0.0 to <1.0, as a proportion of the source row's PPQ width)

On paste, the target PPQ is computed as:

```
targetPPQ = cursorRowPPQ + (row - 1) * targetPPQPerRow + rowOffset * targetPPQPerRow
```

Events stay in their row. Micro-timing within the row scales proportionally to the target grid resolution, so rhythmic structure maps correctly regardless of PPQ/row differences.

## Note duration

Notes have an associated note-off. Handling depends on whether the note-off falls within the selected row range:

- **Note-off in selection:** stored as `endRow`/`endRowOffset`. On paste, placed using the same row/rowOffset scaling as the note-on.
- **Note-off outside selection:** `endRow`/`endRowOffset` are nil. On paste, the note plays until the next note in the same column truncates it.
- **Note-off in selection but note-on isn't:** ignored — the note is not selected.

On cut, a note whose note-on is in the selection is deleted entirely (including its note-off), regardless of where the note-off falls.

## Modes

The single/multi distinction determines how paste *interprets* the data, not how timing or event collection works.

### Single-column: paste values

Copies from one column. On paste, values are written into whatever column the cursor is in, reinterpreted through the target column's type.

The selection group determines identity vs modifier semantics:

- **CC, AT, PB, PC, PA:** The value is the event. Pasting a value creates an event. Pasting nothing (or zero) deletes one.
- **Note pitch (selgrp 1):** Pitch is the identity field. Pasting a pitch creates a note (with default velocity). Empty deletes.
- **Note velocity (selgrp 2):** Velocity is a modifier. It attaches to existing notes at matching rows. No note at that position, no effect. Does not create or delete notes.
- Scalar values (cc, at, pa, pc, pb, note velocity) can paste across compatible column types.

### Multi-column: paste events

Copies whole events across one or more channels. On paste, events are transplanted into the target channel(s). Column structure adapts naturally — `mm:modify()` writes the MIDI events and the trackerManager rebuild discovers any new columns.

## Copy

Reads the selected region. Grabs all events in range (including overflow). Sets `clipboard.mode` based on whether the selection spans one column or multiple.

## Cut

Same as copy, then removes/resets the source:

- **CC, AT, PB, PC, PA:** Delete the events (value is identity).
- **Note pitch (selgrp 1 or full note):** Delete the notes (including note-off, wherever it falls).
- **Note velocity (selgrp 2 only):** Reset velocity to the previous note's velocity in that column. If no previous note, use default velocity.

All events in the range are affected, including overflow. All destructive operations go through `mm:modify()`.

## Paste

Cursor position determines the target: row PPQ gives the starting time, column/channel gives the destination. The clipboard's dimensions determine the footprint — the user does not select a destination rectangle.

### Multi-column channel mapping

The clipboard records each column's source channel. On paste, the first channel maps to the cursor's channel, and subsequent channels are offset accordingly. Channels clamp at 16.

### Multi-column paste as `mm:modify()`

Multi-column paste writes MIDI events directly. TrackerManager rebuild after `modify()` discovers any new columns. Paste does not need to explicitly manage column structure.
