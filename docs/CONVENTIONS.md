# Documentation conventions

One Markdown doc per source file, living under `docs/<file>.md`. The doc
owns the prose; the source file carries only what the code itself can't
say.

## Audience

The reader can read Lua and understand local code. They do **not** need to
be told what a function does if its name says it; they do need to know the
WHYs that aren't visible from any single call site — invariants across
files, REAPER/engine quirks, ordering constraints, lifecycle rules.

## Shape of a file doc

Thematic prose first, API reference second.

**Thematic sections** (include only those that apply):
- purpose / one-line summary at the top
- identity & persistence model (if the file owns persistent state)
- mutation / locking contract (if there is one)
- callbacks / lifecycle / reload semantics
- conventions — units, indexing offsets, sentinel values, muted/optional
  field conventions, anything that's true across the whole module
- wire-format / external-API quirks (e.g. REAPER packs X into Y)
- cross-cut invariants that hold between functions
- any non-obvious global discipline (LUTs derived to stay in sync,
  two-pass loads and why)

**API reference** — compact signatures grouped by theme. Include:
- the signature in a code block
- arg fields with required/optional marking and legal ranges
- return shape when non-trivial
- short prose only where the signature leaves something load-bearing
  unsaid (e.g. `util.REMOVE` semantics, metadata-only carve-outs,
  side-effects on adjacent state)

Do **not** repeat in prose what the signature already says. If the only
thing you can write about a function is "returns a copy of X, or nil",
the signature alone is enough.

## Shape of the source file

- **Header:** single line, `-- See docs/<file>.md for the model and API reference.`
  No docstring essay. No per-function preambles.
- **Inline comments:** only where they encode a non-obvious WHY.
  Good: "notation event encodes (chan, pitch) at ppq, so keep it in sync",
  "rescan: step 3 inserted notation events, so uuidIdx values are stale",
  "Writing an empty string effectively removes the extension data".
  Bad: "update the existing note", "get cc events", "create new note".
- **Section dividers** are fine if they aid navigation in a long file; drop
  them if the function names make them redundant. Use them to label *logical
  groups* of adjacent functions, not to decorate single functions. Two
  levels, stacked by scope — dash counts are exact, casing is load-bearing:
  - `---------- NAME` — 10 dashes, ALL CAPS. Top-level partitions
    (e.g. `PRIVATE`, `PUBLIC`).
  - `----- Name` — 5 dashes, Title Case. Subsections within a partition
    (e.g. `Swing`, `Update manager`, `Rebuild`, `Transport`, `Mutation`,
    `Lifecycle`).
  Labels are one line, no trailing punctuation, no prose. Keep subsection
  names aligned with the thematic sections in the doc where they overlap.
- Single-word comments restating the next line's effect are always out.

## Workflow

1. Draft `docs/<file>.md` **before** touching the source. Review the
   draft for shape and coverage before any strip.
2. Once the doc is agreed, do the source strip in one pass: replace the
   header, trim inline filler, keep the WHY comments.
3. Sanity-check (syntax, tests) before moving on.

## Keeping docs in sync

**Any change to a documented file must update its doc if the change
touches anything the doc describes.** The doc is the source of truth for
cross-file semantics; letting it drift is worse than having no doc.
Things that require a doc update:
- new/removed/renamed public method → API reference
- change to mutation/lock/callback contract → thematic section
- change to encoding, offsets, sentinel values, conventions → conventions
- new cross-cut invariant that a reader couldn't reconstruct from one
  function

Pure internal refactors that preserve every documented property need no
doc change.
