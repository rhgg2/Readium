# util

Shared utilities used across every manager. No state of its own — a grab
bag of the idioms that would otherwise be reinvented in each file.

## The `REMOVE` sentinel

`util.REMOVE` is a unique table used as a delete marker in field-wise
merges. `util:assign(t, {k = util.REMOVE})` clears `k` from `t`.

The same semantics is honoured by `mm:assignNote` / `mm:assignCC` /
`cm:assign` at their entry points — a caller building an updates table
can mix sets and deletes uniformly without a second code path.

REAPER-native boolean flags (`muted`) opt out: they clear by assigning
`false`, not `REMOVE`, because they are not metadata and the backend
has no "absent" state.

## Serialisation format

`util:serialise` / `util:unserialise` implement a custom escaped format
used for note metadata (via `mm`) and config persistence (via `cm`).
Not JSON, not Lua syntax:

- `{k1=v1,k2=v2}` for tables.
- strings/numbers/booleans are unquoted; scalars decode back to their
  original type (numbers via `tonumber`, literals `true`/`false`).
- the four delimiter chars `{ } , =` plus `\` itself are backslash-escaped.
- cycles raise.
- trailing characters after a complete value raise.

Parse failures at callsites are caught and treated as empty tables; the
serialise side is strict.

## Callback installation

`util:installHooks(owner)` is the shared fire-and-listener protocol. It
installs `addCallback` / `removeCallback` on `owner` and returns a
`fire(...)` closure the owner invokes on every notable event. mm, tm,
vm, and cm all wire callbacks through this — the `changed, manager`
argument shape is a convention between callers, not enforced here.

## Pure predicates vs. self methods

Functions that take no implicit `self` are defined with `util.foo`
(dot) so they can be passed directly as `filter` / `keyFn` arguments to
`util:seek`, `util.between`, etc. Methods that operate on the util
"namespace" are defined with `util:foo` (colon). The split matters:
`util.isNote` is a first-class predicate, `util:clone` is not.

## Event-list helpers

`util:seek` and `util.between` assume a ppq-sorted input array. `between`
uses half-open `[lo, hi)` intervals so adjacent windows tile without
double-counting. Both take an optional filter predicate, letting callers
restrict to note-ons, particular channels, etc. without a pre-pass.

## Conventions

- **`clone` is shallow; `deepClone` is recursive.** `clone(src, exclude)`
  drops keys present in the `exclude` set — used by mm accessors to strip
  `idx`/`uuidIdx` internals before returning copies.
- **`snapTo` moves at least one interval.** A value already on a boundary
  advances by a full step — callers never get a no-op snap.
- **`nudgedScalar` is the canonical "arrow key" combinator.** Integer
  unit step without an interval, snap-to-next with one, clamped either way.
- **`setDigit` supports half-step entry** via `half` — used by the
  shift-digit path in the grid.
- **`dotimes(n, v)` overloads on type** — function `v` means "call n
  times for side effect"; anything else means "build an n-array of v".

---

## API reference

### Printing

```
util:print(...)                  -- tab-joined to REAPER console, nil warned
util:print_r(tbl)                -- recursive dump with cycle detection (dev)
```

### Tables

```
util:assign(t1, t2)       -> t1  -- merge t2 into t1; REMOVE clears
util:add(tbl, v)          -> v   -- tbl[#tbl+1] = v, then return v
util:clone(src, exclude, deep)   -- shallow by default; deep recurses
util:deepClone(src)              -- = clone(src, nil, true)
util.REMOVE                      -- sentinel for delete-in-assign
```

### Event lists (ppq-sorted)

```
util:seek(items, mode, key, filter, keyFn)
  mode ∈ {before, at-or-before, after, at-or-after}
  keyFn defaults to function(x) return x.ppq end
  filter optional predicate
  returns the hit item or nil
util.between(events, lo, hi, filter)
  iterator over events with ppq in [lo, hi); filter optional
util.isNote(e)                   -- predicate: has endppq
```

### Numerics

```
util:clamp(v, lo, hi)
util:round(n, to)                -- to optional (snap multiple)
util:snapTo(v, dir, interval)    -- next multiple of interval in dir, never no-op
util:nudgedScalar(v, lo, hi, dir, interval)
                                 -- snapped or unit-stepped, clamped
util:setDigit(val, d, pos, base, half)
                                 -- write digit d at place pos in base, zero below
util:oneOf('a b c', txt)         -- whitespace-split membership
util:dotimes(n, v)               -- loop fn, or build n-array of v
```

### Serialisation

```
util:serialise(value, exclude)   -- strict; cycles raise
util:unserialise(input)          -- strict; trailing chars raise
```

`exclude` in `serialise` is a `{key=true}` set of keys to skip on the
outermost (and only the outermost — recursion does not inherit it) table.

### Callback protocol

```
fire = util:installHooks(owner)
  installs owner:addCallback(fn), owner:removeCallback(fn)
  returns fire(...) — each listener runs with the forwarded args
```
