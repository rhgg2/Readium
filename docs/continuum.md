# continuum

Entry point. Loads every module, wires the managers together in the
layered order, and drives the render loop via `reaper.defer`.

## Module loading

`loadModule(name)` is a thin `require` wrapper that resolves paths
relative to the script's own location (via `debug.getinfo`), so the
script loads the same way regardless of REAPER's current working
directory. Each module registers a global on load (`util`,
`newMidiManager`, etc.) — there are no return values to capture.

Load order is bottom-up through the manager stack:

```
util → configManager → midiManager → trackerManager
     → commandManager → viewManager → renderManager
     → samplerProbe
```

`util` comes first because everything else calls `util.installHooks`
during construction. `commandManager` loads before `viewManager`
because vm, ec and clipboard populate the command registry at
construction time. `editCursor` loads before `viewManager` because vm
constructs ec / clipboard from `newEditCursor` / `newClipboard`.

## Wiring

`Main()` runs once per invocation:

1. Look up the selected media item; bail with a console message if none.
2. Take the item's active take.
3. Build managers bottom-up:
   - `mm = newMidiManager(take)` — initial load is eager.
   - `cm = newConfigManager(); cm:setContext(take)` — context is set
     after construction so the four-tier cache refreshes against this
     take.
   - `tm = newTrackerManager(mm, cm)` — registers callbacks with both.
   - `cmgr = newCommandManager(cm)` — empty command/keymap tables.
   - `vm = newViewManager(tm, cm, cmgr)` — registers vm's editing
     commands, constructs ec and clipboard (which self-register their
     own navigation / clipboard commands via `:registerCommands(cmgr)`),
     then applies cross-cutting wrappers.
   - `renderer = newRenderManager(vm, cm, cmgr)` — registers rm's UX
     commands (modals, confirms, swing editor, quit), installs the
     default keymap, and creates the ImGui context.
4. `probeTrackerMode(mm, cm)` writes `transient.trackerMode` from the
   track's FX list before the first rebuild reads it. See
   `docs/samplerProbe.md`.
5. `renderer:init()` opens the window.
6. A defer loop drives each frame: the probe runs again at the top of
   each tick (cheap; gated on change so it only fires
   `configChanged` when the FX list actually flips), then
   `renderer:loop()` returns `true` while the script should keep
   running; `false` / `nil` ends the loop.

## Error handling

`run(fn)` clears the REAPER console, then `xpcall`s its argument
through `err_handler`. On error: the error message and traceback are
written to the console, and an empty `reaper.defer` is queued to keep
the script alive long enough for the user to read the console before
REAPER unloads it.

Errors inside the defer loop surface the same way — `renderer:loop`
runs under the same `xpcall` frame because each iteration schedules
itself via `reaper.defer(loop)`.

## Conventions

- **One MIDI item per session.** The script binds to the take at
  startup; changing REAPER's selection mid-session does not re-bind.
  Re-invoke the action to pick up a new item.
- **No teardown.** There is no explicit quit path — a command handler
  returning `'quit'` surfaces as `renderer:loop()` returning falsy,
  which simply stops scheduling further defers.

---

## API reference

```
loadModule(name)                 -- relative require, used by continuum.lua itself
Main()                           -- bound to the ReaScript action
```

No public Lua API — downstream code talks to the managers, not to
continuum itself.
