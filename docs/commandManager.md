# commandManager

Central registry for named actions and the keys that invoke them. vm (and
any future manager split) registers command handlers by name; rm binds
default keys and drives dispatch from its ImGui render loop. Also holds
the physical-keyboard → note-input layouts used when typing notes into
the grid.

Two orthogonal tables live on the manager:

- `commands[name] = fn` — what the command does
- `keymap[name]   = { keyspec, ... }` — which keys trigger it

Keeping them name-addressable (rather than closing keys over handlers
directly) lets rm invoke commands by name outside the keymap path —
mouse-wheel scrolling and the swing editor both do this — and lets vm
wrap existing commands without threading through the dispatch loop.

## Registration lifecycle

```
newCommandManager(cm)                  -- empty commands + empty keymap
  → newViewManager(tm, cm, cmgr)       -- vm calls registerAll{...}, then wrap(...)
  → newRenderManager(vm, cm, cmgr)     -- rm calls installDefaultKeymap(ImGui)
```

vm registers the full command table in one bulk `registerAll`, then
applies a set of `wrap` calls for cross-cutting behaviour (see below).
rm installs the default keymap at construction; users will eventually
layer overrides on top.

## Dispatch & result protocol

rm's key-handling loop iterates `cmgr.keymap`, matches ImGui key +
modifier state, and invokes `cmgr.commands[name]()`. The handler's first
return value is a control code consumed by rm:

| return          | meaning                                                   |
|-----------------|-----------------------------------------------------------|
| `nil` (default) | command handled; stop scanning further bindings this frame |
| `'quit'`        | exit the script                                           |
| `'modal'`       | open a text-input popup; second return is the modal state |
| `'swingEditor'` | open the swing editor overlay                             |
| `'fallthrough'` | command ran but did not consume the keypress              |

Handlers that need to pass state back (currently only modals) return it
as the second value.

Commands invoked by name outside the keymap path (mouse wheel,
swing-editor buttons) ignore the result code and just run for effect.

## Wrapping

`wrap(name, wrapper)` replaces `commands[name]` with
`wrapper(originalFn)`. It exists so vm can bolt cross-cutting behaviour
onto whole groups of commands without touching each handler:

- **mark-mode paste cancel** — first paste press in mark mode clears the
  selection instead of pasting, so the explicit second press pastes at
  the cursor.
- **auto-unstick** — nudge / grow / duplicate / interpolate / row-insert
  / reswing / quantize commands drop the sticky-selection flags after
  running, so the edited region stays visible but doesn't extend on the
  next cursor move.
- **auto-clear selection** — after `delete` / `deleteSel` / `cut` the
  affected events are gone, so the empty selection rect is cleared.

Wrappers compose; calling `wrap` on an already-wrapped command stacks
outside the previous wrapper.

## Note-input layouts

`layouts` declares four physical-keyboard maps (`qwerty`, `colemak`,
`dvorak`, `azerty`). Each layout is a two-row array:

- **row 1** (Z-row on qwerty) = base octave, 15 semitones, C → D+1oct
- **row 2** (Q-row on qwerty) = +1 octave, 17 semitones, C → F+1oct

Entries are single-char strings or integer codepoints (for non-ASCII
keys on azerty). Positions across layouts are musically corresponding —
the Nth slot in row 1 is the same semitone in every layout.

At load time, `layouts` is folded into `chars[name][code] = { semi,
octOff }` — a flat per-layout lookup keyed by character code. The
derivation lives next to the declaration so the two stay in sync; edit
`layouts` and the LUT rebuilds on next load.

`cmgr:noteChars(char)` resolves a typed character under the active
layout (`cm:get('noteLayout')`). The layout is re-read on every call so
a config change takes effect without rebuilding vm.

## Conventions

- **Command names are flat strings.** `advBy0` … `advBy9` are generated
  in a loop rather than using a namespaced form — the dispatch table is
  a simple string-keyed map, not a tree.
- **Keyspec shape.** Each entry in `keymap[name]` is either a plain key
  constant or `{ key, mod1, mod2, ... }`. Mods are OR'd together.
- **Multiple bindings per command** are supported — the `keys` array
  holds any number of keyspecs, all dispatch to the same command.
- **No automatic unregister.** Commands live for the session; replacing
  one is done via `register` (overwrite) or `wrap` (compose).

---

## API reference

### Construction

```
newCommandManager(cm)            -- cm used for live noteLayout lookup
```

### Registering commands

```
cmgr:register(name, fn)          -- add or overwrite one command
cmgr:registerAll(tbl)            -- bulk { name = fn, ... }
cmgr:wrap(name, wrapper)         -- commands[name] = wrapper(orig); no-op if unregistered
cmgr:invoke(name, ...)           -- call by name; no-op if unregistered
```

`fn` returns `nil`, `'quit'`, `'modal'`, `'swingEditor'`, or
`'fallthrough'` (optionally with a second state value — see dispatch
protocol).

### Keymap

```
cmgr:bind(name, keys)            -- keys is an array of keyspecs
cmgr:bindAll(tbl)                -- bulk { name = keys, ... }
cmgr:installDefaultKeymap(ImGui) -- seed bindings; ImGui supplies Key_*/Mod_* constants
```

A keyspec is either a key constant (e.g. `ImGui.Key_UpArrow`) or a table
`{ key, mod1, mod2, ... }` where mods are OR'd.

### Note input

```
cmgr:noteChars(char)             -> { semi, octOff } or nil
cmgr.layouts                     -- raw per-layout declaration (read-only)
```

`char` is the integer character code produced by ImGui text input.
`semi` ∈ 0..16, `octOff` ∈ 0..1. Active layout resolves from
`cm:get('noteLayout')` on each call.

### State tables

```
cmgr.commands                    -- { name = fn }
cmgr.keymap                      -- { name = { keyspec, ... } }
```

rm reads these directly in its render loop; they are not private.
