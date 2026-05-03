# slotStore

Source-of-truth for sample slot assignments on a track. The JSFX is now a
decoded-audio cache; cm holds the canonical slot table and slotStore
mediates every change.

## Storage model

Slot data lives in `cm:get('slotEntries')` at the **track tier**,
persisted via `P_EXT:ctm_config`. Shape:

```
slotEntries = {
  [idx] = { path = 'Continuum/<base>-<rand8>.<ext>', ... },
  ...
}
```

`idx` is 0-indexed to match MIDI PC values and the JSFX slot index.
`path` is **always project-relative** — resolved against
`reaper.GetProjectPath(0)`, which transparently returns REAPER's default
media folder for unsaved projects and the project's own media folder
once saved. Keeping the cm value relative means the on-save migration
just moves bytes; cm contents are unchanged.

Future per-slot fields (SH_START, SH_END, basenote, loop mode) will sit
on the same entry. Unknown fields persist round-trip (cm prunes only
unknown *top-level* keys).

## Ownership of the audio bytes

slotStore copies every assigned file into `<projectMedia>/Continuum/`
under a randomised name. The source file is never referenced after
assignment — Continuum owns the bytes, which matters for forthcoming
destructive editing. Originals are never modified.

The JSFX `@serialize` continues to round-trip the decoded audio so
warm-start is fast, but cm wins on conflict: every FX (re-)attach
triggers a `sweep()` that re-issues the load mailbox for every entry.

## Save migration

The project's media folder is empty-pre-save and project-local
post-save. When the resolved path changes, slot files have to follow.
`migrate(newPath, oldPath)` moves each entry's bytes from the old
resolved path to the new one. cm `path` strings are relative so they
need no rewrite.

The expected trigger is the empty→saved transition; Save As works
identically. If `oldPath` is nil or equals `newPath`, migrate is a
no-op. Sweep can run independently of migrate — they target different
boundaries (FX-attach vs. project-path change).

## Dependency injection

The factory takes:

- `cm` — config manager.
- `fileOps` — `{ copy(src,dst)→bool, move(src,dst)→bool, mkdir(dir)→() }`.
- `loadSlot(idx, relPath)` — gmem load mailbox writer. Forwards the
  project-relative path; the JSFX composes the absolute against the
  separately-published project prefix and persists `relPath` in
  `@serialize` so subsequent boots can re-load autonomously.

Tests pass call-recording stubs; production wires the real
io.open/os.rename/`reaper.RecursiveCreateDirectory` and
`samplerLoadSlot` from `continuum.lua`.

## API

```
newSlotStore(cm, fileOps, loadSlot) → store

store:assign(idx, srcPath, projectPath) → bool
  -- Copy srcPath into <projectPath>/Continuum/, write cm, fire loadSlot.
  -- Returns false if the copy fails.

store:sweep() → ()
  -- Replay every entry through loadSlot (rel paths). Called on FX
  -- (re-)attach. Continuum publishes the project prefix separately
  -- (samplerSetPrefix) before invoking sweep.

store:migrate(projectPath, oldProjectPath) → bool
  -- Move slot files from old → new project media folder.
  -- Returns true if any file was moved.
```
