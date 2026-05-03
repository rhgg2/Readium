# Multi-page architecture

Status: design, pre-implementation.

## Motivation

Today there is one chain — `midiManager → trackerManager → viewManager → renderManager` — bound to a take, wired in `continuum.lua`. The tracker view is the only thing the user sees.

Three more views are coming: a sampler view (WIP, bound to a sampler instance), an arrange view (bound to the project), a mixer view (bound to the project). Each renders into the same ImGui window but has its own model, its own input shape, and its own binding scope. None of them are take-bound, so they cannot sit on the existing chain.

The structure must let each page evolve independently while sharing chrome, command dispatch, persistence, and keyboard handling.

## Page = stack

A *page* is a layered stack of any depth that terminates in a renderable surface. The current tracker page is a four-layer stack; the sampler page will be a different stack rooted in gmem rather than a take; arrange and mixer will be different again.

There is deliberately no shared base class for the stack itself. Forcing the sampler's gmem-rooted shape into a tracker-shaped mould before arrange and mixer have been built is premature. Each page owns whatever depth its domain wants.

What *is* shared is the surface the coordinator sees. Every page exposes a small uniform interface:

- `bind(scope)` — attach to the page's binding scope (see below).
- `unbind()` — detach, releasing listeners and any cm transient state.
- `render()` — called once per frame inside the coordinator's ImGui frame.
- `handleInput(event)` — input not consumed by ImGui (gestures the coordinator routes here).
- `focusState()` — per-frame report of what should suppress global shortcuts (e.g. an InputText is focused, a modal popup is open). See *Keyboard router* below.
- `save()` / `load()` — persistence via cm; usually a thin wrapper since most state is already cm-tier.

The page *is* the top of its stack — there is no separate façade. The existing `renderManager` already does render + input handling, and adding the Page-interface methods to it is a smaller change than wrapping it. So the tracker page is the renamed renderer, owning the view-model layer below it directly. Likewise for sampler: the sampler page is its renderer, owning a gmem-reader / slot-model / view stack beneath.

## Binding scopes

Each page binds to one of: project, track, take, sampler instance.

These map onto cm's existing tier system, which is the right place to handle persistence and lifecycle:

| Page     | Binding scope    | cm tier                                          |
|----------|------------------|--------------------------------------------------|
| tracker  | take             | take tier (existing)                             |
| sampler  | sampler instance | track tier, keyed by FX GUID inside the track    |
| arrange  | project          | project tier                                     |
| mixer    | project          | project tier                                     |

Sampler-instance binding does not need a new tier. A sampler lives on a track and is identified by its FX GUID; its config is a sub-key inside the track tier. This keeps cm's tier set small and avoids a tier whose lifetime is awkward to define.

Transient state stays per-page and uses the existing transient tier.

## Coordinator

A single coordinator object replaces the wiring currently in `continuum.lua`. It owns three things and no more:

1. The cm instance and the ImGui context.
2. The chrome — menus, transport, status bar, page switcher.
3. Input routing — which page is focused, which receives keyboard.

It does not own page internals. It does not know about MIDI, gmem, sampler slots, or arrange clips. It sees only the Page interface.

Cross-page navigation (clicking a sampler in arrange view should open the sampler page bound to that instance) is the coordinator's responsibility, but the *entry point* belongs to the destination page: `samplerPage.openBoundTo(track, fxIndex)`. The coordinator calls that and switches focus. Pages do not call each other directly.

## Command manager — scoped registries

cmgr today holds a single registry. Multi-page needs scoping, but a flat set of per-page registries is the wrong shape: many commands are genuinely global (save, transport, switch-page) and should not be duplicated.

The right shape is a scope chain:

- One global registry on cmgr.
- One per-page registry on each page.
- Lookup walks active-page → global. A page can shadow a global key when the local meaning is stronger.

Commands close over their page's state, so no context argument is threaded through the dispatcher. A tracker-page command captures the trackerPage instance directly; the dispatcher only knows about the registries.

When a page is bound, it registers its commands with cmgr; when unbound, it unregisters. The coordinator never touches the page's registry.

## Keyboard router

Keyboard dispatch is mechanical and identical across renderers. The non-uniform part is *suppression* — when an `InputText` has focus, key shortcuts must be swallowed (a known reaimgui gotcha); when a modal popup is open, only popup nav should fire; etc. That is the one part worth getting right in one place.

Place the dispatcher in cmgr (or a thin `kbdRouter` it owns). Per frame:

1. The active page reports its `focusState()` — which suppression conditions are active.
2. cmgr maps key + modifiers to a command via the scope chain, applying suppression first.
3. The command runs, closing over its page state.

Mouse and drag stay in each renderer. Only the keyboard-to-command path is centralised.

A separate `kbdRouter` module is only worth extracting if the suppression logic grows past a few lines. Until then, it is a method on cmgr.

## Naming

`viewManager` and `renderManager` are misleading names once the tracker is one of several pages. The "Manager" suffix also no longer earns its keep on layers that do not manage external state — `viewManager` is a model of the view (cursor, selection, grid), not a manager of anything outside the process.

Proposed renames:

| Current         | New              | Rationale                                       |
|-----------------|------------------|-------------------------------------------------|
| `viewManager`   | `trackerView`    | Page-specific; drops misleading "Manager".     |
| `renderManager` | `trackerPage`    | Becomes the page (render + input + Page interface). |

Kept as-is:

| Module          | Why                                              |
|-----------------|--------------------------------------------------|
| `midiManager`   | Manages REAPER MIDI state. Not page-specific.    |
| `trackerManager`| Manages tracker model derived from MIDI.        |
| `configManager` | Cross-cutting; the "Manager" suffix is honest.   |
| `commandManager`| Cross-cutting; gains scoped registries.          |

New modules:

| Module          | Role                                             |
|-----------------|--------------------------------------------------|
| `coordinator`   | Owns cm + ImGui + chrome + input routing.        |
| `samplerView`   | Sampler page's view-model layer.                 |
| `samplerPage`   | Sampler page (render + input + Page interface).  |
| `arrangeView`, `arrangePage` | Per arrange.                        |
| `mixerView`, `mixerPage`     | Per mixer.                          |

`coordinator` deliberately drops the "Manager" suffix. It is not managing external state; it is composing the application.

## Migration order

Each step lands as its own commit and leaves the suite green.

1. **Rename** `viewManager → trackerView`, `renderManager → trackerPage`. No structural change; tracker stays wired as today.
2. **Add Page interface to `trackerPage`.** Surface the methods the coordinator will call (`bind`, `unbind`, `render`, `handleInput`, `focusState`, `save`/`load`). Existing render/input behaviour stays as-is.
3. **Introduce coordinator.** `continuum.lua` becomes coordinator instantiation + page registration. The coordinator's chrome is initially the same chrome `trackerPage` drew; only the ownership has moved.
4. **Scoped registries in cmgr.** Add per-page registry support; move tracker-specific commands into `trackerPage`'s registry. Global commands stay on cmgr.
5. **Keyboard router.** Move kbd dispatch into cmgr; have `trackerPage` report `focusState()`; verify InputText suppression still works.
6. **Sampler page.** Stand up `samplerPage` as the second page wired into the coordinator. Whatever shape pinches in *two* places gets factored — not before.
7. **Arrange, mixer.** Follow.

The reason for steps 1–5 before any new page: the structural moves should land against a working, tested system, not be entangled with new functionality.

## Open questions

- **Page switcher UI.** Tabs at the top? A dropdown? A keybinding-only switcher? Likely tabs, but the chrome design has not been done.
- **Multiple instances of the same page.** Two tracker views side by side, each bound to a different take? Possible later; not in this design.
- **Split view.** Single active page is the default. Splits add input-routing complexity (which pane has focus) and chrome complexity (per-pane toolbars). Defer.
- **Page-to-page references.** When arrange shows a sampler instance and the user clicks it, the entry-point pattern (`samplerPage.openBoundTo`) covers the navigation. But what if the user wants the sampler page to update *live* in response to arrange-side selection? That is a notification problem, not a binding problem, and is out of scope here.
