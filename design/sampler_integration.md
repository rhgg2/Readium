# Sampler integration — phase 1

Integrate `sampler/Continuum_Sampler.jsfx` with the tracker so a note in
the grid carries the sample it plays. Two pieces:

1. A **parts refactor** of grid columns — replaces hand-enumerated
   `note` / `noteWithDelay` flat shapes with a composable parts list.
   Behaviour-preserving on its own; lands first.
2. A **`SAMPLE` per-note field** plus track-level **tracker mode** — in
   tracker mode the PC column disappears as a user surface and is
   synthesised from per-note sample values on lane-1 notes.

Phases 2 and 3 of the user's vision (sampler instance → name list via
gmem; in-tracker sample browser UI) plug into the SAMPLE concept
established here without changing its shape; not designed in this doc.

## Mental model

`SAMPLE` is the per-note **authoring intent**: which sample does this
note play. The PC stream is the **realisation** the synth needs. tm
owns the reconciliation, the same shape as detune→pb but simpler
(PCs are step-only, no boundary absorbers).

```
intent      : note.sample (every note in tracker mode, per-note sidecar)
realisation : PC stream on the channel (one PC per unique realised onset)
```

The MIDI constraint is "one PC stream per channel at any moment in
realised time". Notes that share a realised onset on the same channel
must therefore share a PC. The rule:

> Group notes by (channel, realised ppq). Within each group, the
> **leftmost lane** (lowest `lane`) wins — its `sample` is what the
> emitted PC carries. Other notes in the group are *shadowed*: their
> `sample` is still authored and stored, but inaudible until the
> shadower moves or is deleted.

Notes at distinct realised ppqs never conflict — each emits its own
PC. So a lane-2 melody over a lane-1 sustain can pick its own sample,
provided its onsets don't collide with lane-1 onsets.

vm hides the realisation surface (the PC column) when tracker mode is
on, exposes the intent surface (an in-cell `SAMPLE` part on every note
column), and dispatches edits straight onto the per-note field.
Shadowed notes render their own sample dimmed.

---

## Part 1 — composable column parts (refactor, no behaviour change)

Today every grid column has flat `stopPos` / `selGroups` arrays
enumerated per "kind" (`note`, `noteWithDelay`, `pb`, `cc`, `pa`, `at`,
`pc`). Adding a `sample` slot inside the note cell would push the
`note` family from 2 variants to 4. The current arithmetic
(`if stop == 5 or stop == 6 or stop == 7` in `editEvent`,
`setDigit(..., 7 - stop, ...)`) bakes column geometry into edit
dispatch.

Replace with a parts registry + per-column composed parts list.

### Part registry

```lua
-- editCursor.lua
local PARTS = {
  pitch    = { width = 3, stops = {0, 2}    },   -- C-4
  sample   = { width = 2, stops = {0, 1}    },   -- 7F
  velocity = { width = 2, stops = {0, 1}    },   -- 30
  delay    = { width = 3, stops = {0, 1, 2} },   -- 040
  pb       = { width = 4, stops = {0, 1, 2, 3} },
  scalar   = { width = 2, stops = {0, 1}    },   -- cc/at/pa/pc
}
```

`width` is in characters; `stops` are part-local cursor offsets.

### Per-column parts list

Built at `addGridCol` time, passed into `ec:decorateCol`:

```lua
local function noteParts(trackerMode, showDelay)
  local p = {'pitch'}
  if trackerMode then util.add(p, 'sample') end
  util.add(p, 'velocity')
  if showDelay then util.add(p, 'delay') end
  return p
end
```

Other types: pb → `{'pb'}`, cc/at/pa/pc → `{'scalar'}`.

### Decoration derives shape

`ec:decorateCol(col)` walks `col.parts` once and stamps:

```
col.stopPos    -- {Int}    absolute char offsets per stop
col.partAt     -- {String} part name for each stop  -- replaces selGroups
col.partStart  -- {Int}    stop index of first stop in this stop's part
col.width      -- Int      sum(part widths) + (#parts - 1) for separators
```

Separator between adjacent parts is one space. `partStart[stop]` lets
edit dispatch compute `digit = stop - partStart[stop]` directly,
killing the `7 - stop` arithmetic.

### Knock-on changes

**`editCursor.lua`**

- Every `selGroups[stop]` becomes `partAt[stop]` returning a string.
- `selectionStopSpan` walks parts in order, finds first/last whose name
  is in the requested set.
- `cycleHBlock` widens to all stops (whole column) — already does
  `1 .. #stopPos`, no change in shape, just runs over the new list.
- The "expand to col on H-block when only one selgroup" branch
  (`#grid.cols[cursorCol].selGroups == 1`) becomes
  `#col.parts == 1` (plus the same single-stop check on
  `#stopPos == 1`, kept for `pa`/etc.).

**`viewManager.lua` — `editEvent`**

```lua
local part = col.partAt[stop]
if part == 'pitch'    then ...
elseif part == 'velocity' then ...
elseif part == 'delay'    then ...
elseif part == 'sample'   then ...   -- added in Part 2
end
```

Half-digit index for multi-char parts:

```lua
local digit = stop - col.partStart[stop]   -- 0-based, left-to-right
```

Today's velocity branch (stops 3 and 4) becomes `part == 'velocity'`
with `digit ∈ {0,1}`. Today's delay branch (stops 5/6/7) becomes
`part == 'delay'` with `digit ∈ {0,1,2}`. The `setDigit`
position parameter is then `widthOfPart - 1 - digit`.

**`viewManager.lua` — `addGridCol`**

Width comes from the parts builder, not the inline ternary:

```lua
local parts = partsForCol(type, chan, key)   -- dispatches on type
gridCol.parts = parts
```

`ec:decorateCol(gridCol)` derives `width`, `stopPos`, `partAt`,
`partStart`. Drop `gridCol.width` from the `addGridCol` literal.

**`renderManager.lua`**

Cell rendering iterates `col.parts`, drawing each as its own sub-cell
at `col.x + partOffset[i]`. Adding a new part = adding one branch in
the part-renderer dispatch. The current monolithic format-string for a
note cell decomposes into one renderer per part name.

Selection rectangle x-coordinates (`c.x + c.stopPos[s]`) are unchanged
— `stopPos` keeps the same shape, just derived now.

**`editCursor.lua` — clipboard**

`copyCol`'s clip type is decided by the part under the cursor:
`pitch`/`sample`/`velocity`/`delay` map to today's note-stop-kinds,
`pb` → `pb`, `scalar` → `7bit`. The existing decision (`note` vs
`7bit` based on selgrp 1 vs 2 inside a note column) becomes
`'pitch' / 'velocity' → note / 7bit` more legibly.

`pasteVelocities` triggers when the destination part is `'velocity'`.

### Pinning tests (run before and after the refactor)

```
test_parts_pin_note          -- {'pitch','velocity'};
                                stopPos = {0,2,4,5}; width = 6
test_parts_pin_noteDelay     -- {'pitch','velocity','delay'};
                                stopPos = {0,2,4,5,7,8,9}; width = 10
test_parts_pin_pb            -- {'pb'}; stopPos = {0,1,2,3}; width = 4
test_parts_pin_cc            -- {'scalar'}; stopPos = {0,1}; width = 2

test_partAt_note             -- {'pitch','pitch','velocity','velocity'}
test_partAt_noteDelay        -- {'pitch','pitch','velocity','velocity',
                                 'delay','delay','delay'}

test_clipboard_note_to_note  -- copy(pitch) + paste → notes preserved
test_clipboard_vel_to_note   -- copy(velocity) + paste → pasteVelocities
test_selectionSpan_pitch     -- select pitch only → s1=1, s2=2
test_selectionSpan_delay     -- select delay only → s1=5, s2=7
```

### Done when

All existing tests pass unchanged. `selGroups` no longer appears in
the codebase. Adding a `sample` part in Part 2 requires zero changes
to the registry-walking code.

---

## Part 2 — `trackerMode` (track-level) + `SAMPLE` per-note

### Config schema

```lua
{ 'trackerMode',   false }   -- boolean; persists at 'track' tier
{ 'currentSample', 0     }   -- numeric; persists at 'take' tier
                             --   (analogous to currentOctave)
```

`trackerMode` is a single boolean per track, not `{[chan]=true}`. All
16 channels participate together. Future per-channel routing widens
this to a set; the synthesis code is already a per-channel loop, so
the change is one-line.

`trackerMode` is **structural** — not in `vmOnlyKeys`, triggers
rebuild on change.

### Per-note metadata

`note.sample`, uint 0..127. Stored on every note in tracker mode, in
the existing per-note metadata sidecar (same channel `detune`/`delay`
use). Default 0; rebuild seeds 0 on any note that lacks it, only when
`trackerMode` is on.

Shadowed notes still author the field; the value is just inaudible
under the current arrangement. Move or delete the shadower and the
formerly-shadowed sample surfaces.

### vm

**Column composition.** `noteParts(trackerMode, showDelay)` adds
`'sample'` between `'pitch'` and `'velocity'` when `trackerMode` is on.
Width grows from 6/10 to 9/13 chars accordingly.

**PC column hidden.** In the channel loop in `vm:rebuild`, skip
`c.pc` when `cm:get('trackerMode')`. Lane-1 notes still author PC
indirectly via `sample`; tm synthesises the actual PC stream.

**Edit dispatch.** New `part == 'sample'` branch in `editEvent`:

- Hex nibble accumulator on the two digits, same shape as velocity.
- Writes `tm:assignEvent('note', evt, { sample = newVal })` regardless
  of lane. Shadowing is a synthesis-time concern, not an editing one
  — the user can author a shadowed value and have it surface later.

**New-note stamp.** `placeNewNote` adds `update.sample =
cm:get('currentSample')` whenever `trackerMode` is on (any lane).

**Commands.**

```
toggleTrackerMode    -- flips cm:get('trackerMode'); writes at 'track'
inputSampleUp        -- cm:set('take', 'currentSample', clamp(+1, 0, 127))
inputSampleDown      -- cm:set('take', 'currentSample', clamp(-1, 0, 127))
```

Toggle command exposed in rm's command surface; key binding TBD.

**Rendering.** The `'sample'` part renderer in rm draws two hex chars
of `evt.sample`. Notes flagged `evt.sampleShadowed` (set by tm during
synthesis — see below) render in `colour.inactive` to signal that the
authored value is currently overridden by a leftmost-lane neighbour.

### tm

**Rebuild seed.** Step 1 (note normalisation), only when
`trackerMode`: for every note (any lane) where `sample == nil`, seed
`0` via metadata-only `assignNote`. Non-tracker tracks untouched.

**New rebuild step — PC synthesis.** Between current step 4 (extras
reconciliation) and step 5 (`tidyCol`):

```
if trackerMode then
  for chan = 1, 16 do
    -- Drop existing PCs (whether real, sidecar-marked, or stale)
    for _, pc in ipairs((channels[chan].columns.pc or {events={}}).events) do
      um:deleteEvent('cc', pc)
    end
    channels[chan].columns.pc = { events = {} }

    -- Group notes across all lanes by realised ppq; leftmost lane wins.
    local winners = {}    -- realisedPpq → { lane, note }
    local order   = {}
    for _, lane in ipairs(channels[chan].columns.notes) do
      for _, n in ipairs(lane.events) do
        n.sampleShadowed = nil               -- clear before re-deriving
        local rp = n.ppq + delayToPPQ(n.delay)
        local w  = winners[rp]
        if not w then
          winners[rp] = { lane = n.lane, note = n }
          util.add(order, rp)
        elseif n.lane < w.lane then
          w.note.sampleShadowed = true
          w.lane, w.note = n.lane, n
        else
          n.sampleShadowed = true
        end
      end
    end

    table.sort(order)
    for _, rp in ipairs(order) do
      local n  = winners[rp].note
      local pc = { ppq = rp, val = n.sample, fake = true,
                   msgType = 'pc', chan = chan }
      util.add(channels[chan].columns.pc.events, pc)
      um:addEvent('cc', pc)
    end
  end
end
```

`fake = true` distinguishes synthesised PCs from any user-authored
ones the rebuild walked in step 3. (Flag is informational here — the
delete-all + emit-all approach means no user-authored PC survives in
trackerMode anyway. The flag is kept so a future "show realised PCs"
diagnostic view has something to filter on.)

`sampleShadowed` is a synthesised flag on the note itself, in the same
spirit as `hidden` on fake-pb absorbers. The renderer reads it to
decide dimming; nothing else depends on it.

**Mutation hooks.** Any-lane `addNote` / `deleteNote` / `assignNote`
that touches `sample` / `ppq` / `delay` / `lane`: mark the channel
dirty, run PC reconciliation at the start of `tm:flush` for each
dirty channel. Same shape as `reconcileBoundary` for fake-pb.
Reconciliation = the same group-by + emit-all loop above, run on one
channel — including the `sampleShadowed` re-stamp, since deleting a
shadower must un-shadow the survivor.

**Toggle handler.** Listen for `cm 'configChanged'` with
`key == 'trackerMode'`. On transition ON: for each channel, walk all
notes in intent ppq order; for each with `sample == nil`, derive from
the prevailing PC at its realised onset and write back via
`assignNote`. Then trigger a normal rebuild — the synthesis step will
replace the PC column. On transition OFF: nothing — leave per-note
`sample` alone (harmless), the next rebuild simply skips synthesis
and the (now empty) PC column reveals.

### Tests

```
test_parts_note_tracker      -- {'pitch','sample','velocity'};
                                stopPos = {0,2,4,5,7,8}; width = 9
test_parts_note_tracker_delay -- {'pitch','sample','velocity','delay'};
                                stopPos = {0,2,4,5,7,8,10,11,12};
                                width = 13

test_tm_pc_synthesis_basic   -- 3 lane-1 notes with samples {1,2,1};
                                pc column has 3 events with those vals
test_tm_pc_synthesis_realised -- note with delay → PC at realised ppq
test_tm_sample_change_resyncs -- assign sample on note 2 from 2→3;
                                pc column updates accordingly
test_tm_delete_drops_pc      -- delete a winning note → its PC gone
test_tm_no_synth_when_off    -- trackerMode=false: user-authored PCs
                                untouched
test_tm_toggle_on_derives    -- pre-existing PC at ppq P, note onset
                                P → note.sample = PC.val after toggle
test_tm_lane2_alone_emits_pc -- lane-2 note alone (no simultaneous
                                lane-1) with sample 5 → PC at its
                                realised ppq with val 5
test_tm_chord_leftmost_wins  -- lane-1 sample=A, lane-2 sample=B at
                                same realised ppq → one PC val=A;
                                lane-2.sampleShadowed = true
test_tm_chord_split_realised -- lane-1 ppq P delay 0, lane-2 ppq P
                                delay -10 → two PCs at distinct
                                realised ppqs, neither shadowed
test_tm_shadow_clears_on_delete -- delete shadower → survivor's
                                sampleShadowed = nil; PC val updates
                                to survivor's sample

test_vm_pc_hidden_when_on    -- trackerMode=true: no grid col with
                                type='pc' for any chan
test_vm_edit_sample          -- type 'A','5' on sample stops →
                                note.sample == 0xA5 (any lane)
test_vm_new_note_stamps      -- with currentSample=12, place a new
                                note (any lane) → note.sample == 12
```

---

## Implementation order

Each step is a separate commit with passing tests.

1. **Parts refactor.** Pinning tests first (red against current code if
   the new shape isn't reachable, green after). No behaviour change.
2. **`trackerMode` cm key + parts wiring.** Adds `'sample'` to the parts
   list when on; hides PC col. No tm changes yet — sample stops are
   editable but write to a field tm doesn't yet act on.
3. **tm PC synthesis.** Rebuild step (group-by realised ppq, leftmost
   wins, stamp `sampleShadowed`) + any-lane mutation hooks +
   on-toggle reverse-derive. Tests for round-trip realisation and
   shadow flag stability under mutation.
4. **vm/cm commands.** `toggleTrackerMode`, `inputSampleUp/Down`,
   `currentSample` plumbing, shadowed-cell dimming in the renderer.

---

## Out of scope (named so we don't drift)

- **Phase 2** (sampler instance → sample names via gmem). Needs a gmem
  layout — the JSFX must publish names; `reaper.gmem_attach` reads
  them. JSFX gmem is float-only; encode names as one-char-per-float
  with a fixed max length per slot.
- **Phase 3** (in-tracker sample browser UI).
- **Per-channel routing.** `trackerMode` becomes a `{[chan]=true}`
  set; the per-channel synthesis loop already has the right shape.
- **PC stream deduplication.** Could emit only on sample-change
  rather than at every lane-1 note; not worth the invariant cost
  until profiling says so.
- **Sample = nil case.** Considered and rejected — always-present
  keeps the column unambiguous and removes a rendering branch.

## Documentation impact

When phase 1 lands, update:

- `docs/configManager.md` — schema entries `trackerMode`,
  `currentSample`.
- `docs/trackerManager.md` — PC synthesis step in rebuild; mutation
  hooks for lane-1 sample changes; lane-N sample reject.
- `docs/viewManager.md` — column parts list; `'sample'` part in note
  cells under tracker mode; `noteSampleAt` helper; new commands.
- `docs/renderManager.md` — per-part cell rendering decomposition.
- (New) `docs/parts.md` if the parts registry merits its own doc;
  otherwise fold into `viewManager.md` "Grid shape".
