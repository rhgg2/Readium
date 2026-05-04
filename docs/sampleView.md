# sampleView

Take-independent view rendered when `cm:get('viewMode') == 'sample'`. Owns
the file browser + slot list UI but no persistent state of its own —
selection lives in transient locals, sample assignments live in the
sampler JSFX (driven via gmem mailboxes).

## Identity model

Sample mode keys against a **REAPER track**, not a take. The track is
chosen explicitly through the toolbar picker drawn by `trackerPage`,
which lists tracks carrying the Continuum Sampler FX (supplied by the
`listSamplerTracks` injection from `continuum.lua`). On entry to
sample mode `continuum.lua` defaults the picked track to the parent
track of the last-active take, then `cm:clearTake()` drops the take
context so take-tier reads stop resolving against it.

`sv:setTrack(track)` is the single rebind path. It calls
`cm:setTrack(track)` and clears the transient `currentSample` override
so the merged read falls back to the new track's stored slot (or the
schema default). Test seams construct sv with `cm = nil`, exercising
the local field only.

## gmem boundary

The view never speaks gmem directly. Three writer functions are injected
at construction and live in `continuum.lua`:

- `loadSlot(slot, path)`     → write the path into slot 0..N-1.
- `previewSlot(slot, bounds)` → audition slot N (bounds=1 honours
  SH_START/SH_END, bounds=0 plays the full file).
- `previewPath(path)`         → load the file into the hidden preview
  slot (idx N_SAMPLES) and audition it. Used to scrub through files in
  the browser without consuming a real slot.

Injection keeps `sampleView` testable in the pure-Lua harness; tests
substitute call-recording stubs.

## Layout

Three side-by-side `BeginChild` panes inside the body region:

1. **Folder tree** (left) — recursive `TreeNode` walk rooted at
   `cm:get('sampleBrowserRoot')` (or `$HOME` if unset). Clicking a node
   updates `currentFolder`.
2. **Audio files** (middle) — `[▶][filename]` rows for `currentFolder`.
   Play icon → `auditionPath(full)`. Selectable single-click → select.
   Selectable double-click → `loadSelectedIntoCurrent()`.
3. **Slots** (right) — `[▶][NN name]` rows for slots 0..N_SLOTS-1. Play
   icon → `auditionSlot(idx)`. Selectable click → `currentSample = idx`.

The `##` label suffixes on `SmallButton` give every play icon a unique
ImGui ID (full path for files, slot index for slots) so identical
filenames in different folders don't collide.

## API

```
sv:setTrack(track)        → ()        -- rebinds cm to track; clears transient
sv:getTrack()             → track | nil
sv:listTracks()           → { { track, name }, ... }   -- candidate sampler tracks
sv:setSelectedFile(path)  → ()        -- mainly for tests
sv:getSelectedFile()      → path | nil
sv:loadSelectedIntoCurrent() → bool   -- false if no file selected
sv:auditionPath(path)     → bool      -- false if path is nil
sv:auditionSlot(idx)      → ()        -- always with bounds=1
sv:draw(ctx)              → ()        -- entry point from trackerPage
```

`auditionPath` and `auditionSlot` are thin enough that their bodies are
small, but they exist as named methods so the icon click path is
testable without ImGui.
