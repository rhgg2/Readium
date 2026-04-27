# configManager

Five-tier config store. Reads merge all tiers (most-specific wins); writes
target a single tier. cm is the sole source of truth for valid keys and
owns every table it hands out.

## Schema

The valid set of keys is declared inline as `declarations`, an ordered
array of `{ key, default }` pairs. The array form lets **declared-but-nil**
coexist with non-nil defaults without ambiguity: presence in the array
marks a key as valid; the default slot being `nil` simply means no initial
value.

Enforcement is split:

- **In-code use is strict.** `get`/`getAt`/`set`/`remove`/`assign` raise on
  any key not in the schema.
- **Persisted data is tolerant.** Unknown keys read back from disk / ext
  state are silently pruned on load, so a renamed key in a stale project
  file doesn't error.

Colour keys are flat and dotted (`colour.bg`, `colour.rowBeat`, …) rather
than nested. This preserves per-colour override semantics across levels —
a track setting `colour.cursor` doesn't wipe the project's other colours.

## Ownership

cm owns its cache tables. Every read deep-clones on the way out; every
write deep-clones on the way in. Callers never alias cm's state, and
never need to clone themselves — mutating the result of `cm:get` has no
effect on cm.

## Levels & merge

```
global  → project → track → take → transient
less specific ──────────────────→ more specific
```

The merged view is built by starting from schema defaults, then layering
each level's cache in order. A key's resolved value is whichever level's
cache last set it (or the default if none did). `getLevel(key)` walks
the same stack from most to least specific and returns the first level
defining the key, or nil.

`take` and `track` levels require a take context (see below). Without
one they contribute nothing to the merge.

`transient` is the most-specific tier and never persists. It is reserved
for view-layer overrides that should auto-vanish when the script
reloads (e.g. `viewManager`'s match-grid-to-cursor frame override). On
`setContext` the transient cache reloads to empty along with the rest.

## Storage backends

| level     | backend                                            |
|-----------|----------------------------------------------------|
| global    | Lua file at `<script-dir>/rdm_cfg.txt`             |
| project   | `SetProjExtState(0, 'rdm', 'config', …)`           |
| track     | track `P_EXT:rdm_config`                           |
| take      | take `P_EXT:rdm_config`                            |
| transient | none — in-memory only, reset to `{}` on reload     |

The four persisted backends use `util.serialise` / `util.unserialise`
(the shared escaped format). Parse failures fall through to an empty
table.

## Context

`cm:setContext(take)` sets the active take and derives its track from
`GetMediaItemTrack`. It refreshes all four cache tiers and fires a
callback. Passing `nil` clears the take/track context — `global` and
`project` remain available; `getAt('track'|'take', …)` returns an empty
table or nil values.

## Signals

cm fires one signal, `'configChanged'`. Payload shape varies by call site:

- `{ key = <name>, level = <level> }` — targeted writes (`set`, `remove`).
  Consumers can filter on the keys they depend on, and on `level` to
  distinguish their own writes from others' (`viewManager` uses this to
  skip self-release on its own transient-tier writes).
- `{ level = <level> }` — bulk `assign` (keyless).
- `{}` — `setContext` reload. No `level`; treat as "any key may have changed".

## Conventions

- **util.REMOVE** is honoured only inside `assign(level, updates)` as a
  per-key delete sentinel. `set` and `remove` take explicit arguments.
- **Unknown keys raise** from in-code entry points; from persistence
  they're pruned.
- **Caches are lazy.** First read through any getter triggers a full
  refresh; `setContext` refreshes eagerly.

---

## API reference

### Construction & context

```
newConfigManager()              -- no take context; global/project only
cm:setContext(take)             -- take may be nil to clear; fires callback
```

### Callbacks

```
cm:subscribe('configChanged', fn)      -- fn(data); see "Signals" above
cm:unsubscribe('configChanged', fn)
```

### Reading

```
cm:get(key)            -> merged value (deep copy)
cm:getAt(level, key)   -> value at that level only (deep copy), or nil
cm:getAt(level)        -> full cache table at that level (deep copy)
cm:getLevel(key)       -> level name currently defining key, or nil
```

`level` ∈ `{ 'global', 'project', 'track', 'take', 'transient' }`.

### Writing

```
cm:set(level, key, value)       -- fires 'configChanged' { key, level }
cm:remove(level, key)           -- fires 'configChanged' { key, level } if present
cm:assign(level, updates)       -- fires 'configChanged' { level } (keyless)
```

`updates` is a `{ key = value }` table; a value of `util.REMOVE` deletes
that key. Any unknown key in `updates` raises before any write happens.
