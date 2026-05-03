# samplerProbe

Detects whether the take's track has the Continuum Sampler JSFX in its
FX list, and writes the answer to `cm:get('trackerMode')`.

## Why a probe

`trackerMode` was originally a user-toggleable config flag. It is now
*derived* from the runtime FX list: tracker mode is on iff a Continuum
Sampler instance is present on the track that owns the take. There is
no toggle command — adding/removing the FX is the toggle.

Writes happen at the **transient** tier (in-memory, not persisted),
since the value is recomputed on every tick anyway. Persisting it would
be a lie.

## Lifecycle

`continuum.lua` calls `probeTrackerMode(mm, cm)` once at startup
(before the first rebuild) and once per defer tick (so a user adding
or removing the FX during a session is picked up).

The write is gated on change: `cm:set` only fires if the detected
value differs from what cm currently reports. This keeps `configChanged`
from broadcasting on every tick, which would force a rebuild storm.

The downstream effect of a transition is: `cm:set` fires
`configChanged` → `vm:rebuild` → `tm` rebuild seeds note `sample` from
prevailing PCs (on transition ON) and synthesises the PC stream from
note metadata. See `docs/trackerManager.md` for the synthesis details.

## API

```
probeTrackerMode(mm, cm)
```

Side-effect-only. Reads `mm:take()`, walks
`reaper.TrackFX_GetCount` / `reaper.TrackFX_GetFXName`, matches the
FX name substring `'Continuum Sampler'`, and writes
`cm:set('transient', 'trackerMode', detected)` only when the value
changes.
