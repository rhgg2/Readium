# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## What This Is

Continuum is a REAPER (DAW) script written in Lua 5.4 that provides a
tracker-style MIDI editor. It runs inside REAPER with no build system
or linter, but there is a test harness under tests/. 

## Coding style

IMPORTANT! Aim for limpid elegance, and use whatever paradigm is most
expressive and direct. Be compact, but clear.

Always check the functions in util.lua and use them where possible.

**`ppq` is always lowercase**, even when it starts a new word in a
camelCase identifier: `newppq`, `endppq`, `topppqL`, `cursorppq`. The
`L` suffix on logical-frame variants (`ppqL`, `endppqL`) is the only
capital allowed in these names.

## Architecture

The codebase uses a **layered manager pattern** where each layer
transforms data from the layer below and propagates changes upward via
callbacks.

```
continuum.lua          -- entry point, wires everything together
  └─ midiManager     -- abstraction over REAPER's MIDI take API
       └─ trackerManager  -- parses MIDI into tracker channels/columns
            └─ viewManager    -- builds a renderable grid, editing, clipboard
                 └─ renderManager  -- ImGui rendering and input handling
configManager        -- 5-tier config (global → project → track → take → transient)
util                 -- shared utilities (serialisation, base36, assign)
timing               -- pure module: swing transforms + delay-PPQ helpers
tuning               -- pure module: temperament + (pitch, detune) ↔ (step, octave)
```

**Cross-cutting models.** Two concepts span every layer and have
dedicated docs:

- **Time** — three frames (logical / intent / realisation), connected by swing (logical↔intent) and delay (intent↔realisation). See `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation (channel-wide stream). The view layer above the realisation line never touches pb directly. See `docs/tuning.md`.

When working anywhere near time or pitch, read these first — they're
the canonical source for the frame distinctions and invariants.

**Data flow:** midiManager reads raw REAPER MIDI events →
trackerManager organises them into channels with typed columns (note,
cc, pb, etc.) → viewManager maps events onto a row/column grid and
handles editing/clipboard → renderManager draws the grid via ImGui and
routes input back to viewManager commands.

**Change propagation:** Each manager exposes a signal-keyed callback
protocol via `util.installHooks`. See each manager's docs for the
signals it emits.

**Factory/closure pattern:** All managers use `newXxxManager()`
factory functions that return a table of methods closing over private
local state. There are no metatables or class hierarchies.

**Respect the layers:** Each manager should only talk to its immediate
neighbours. Never reach through a layer to manipulate data that
belongs to a lower or higher manager — prefer issuing commands through
the public interface of the adjacent layer. If a higher layer needs
something done, it should call a method on the layer below, not poke
at that layer's internal structures or bypass it to reach further
down.

## Key Conventions

- **Module loading:** `loadModule('name')` in `continuum.lua` uses `require` with a path derived from `debug.getinfo`. Modules register globals (e.g., `newMidiManager`, `util`).
- **1-indexed MIDI channels:** Internally channels are 1..16 (REAPER uses 0..15). The +1 offset is applied on read and -1 on write to REAPER APIs.
- **Location-based access:** Notes, CCs, and sysex events are accessed by 1-indexed location. All getters return shallow copies; mutations go through `assign*` methods.
- **Mutation locking:** MIDI mutations must happen inside `mm:modify(fn)`. The only exception is metadata-only `assignNote` calls (fields beyond ppq/endppq/pitch/vel/chan).
- **UUID identity:** Every note gets a base-36 UUID stored as a REAPER notation event. Custom metadata per note is persisted to take extension data via `util:serialise`/`util:unserialise`.
- **`util.REMOVE` sentinel:** Passing `util.REMOVE` as a value in an assign call deletes that key.
- **Serialisation format:** Custom escaped format using `{}=,` delimiters (not JSON or Lua table syntax). Used for both note metadata and config persistence.
- **Timing & tuning models live in the repo:** `docs/timing.md` for the three-frame model (logical / intent / realisation, swing, delay) and `docs/tuning.md` for the pitch model (detune as intent, pb as realisation, fake-pb absorber, orthogonality). These are canonical — don't duplicate in memory.
