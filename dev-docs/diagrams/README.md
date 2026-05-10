# Diagrams

Visual reference for the SpacesSync system. Edit the `.mermaid` source — the sibling `.svg` regenerates on stage via the global pre-commit hook.

Workflow diagrams follow the **current vs roadmap** convention: one diagram describes what the code does today, the other describes the intended design. Architecture diagrams describe the present static structure (separate roadmap versions can be added if/when the structure itself changes).

| File | Level | What it shows |
|------|-------|--------------|
| [`workflow-current.mermaid`](workflow-current.mermaid) | Runtime flow — **as built (v0.2)** | What happens from the moment the user switches a Space until SpacesSync re-arms its watcher. Calls out a known gap: events arriving while `syncInProgress=true` are silently dropped, including real user switches that race the ignore window. |
| [`workflow-roadmap.mermaid`](workflow-roadmap.mermaid) | Runtime flow — **intended** | **Functionally identical to current.** Documents the deliberate design decision: a single global `is_running` boolean drops every watcher fire during the sync chain plus debounce window, accepting that real user swipes inside that ~1.4s window are also dropped. Includes a "Design intent" panel listing what we explicitly chose NOT to build (pending triggers, retry loops, echo classifiers) and why. |
| [`architecture-context.mermaid`](architecture-context.mermaid) | C4 L1 — System Context | SpacesSync as a black box with its actors and external systems: the user, `init.lua` config, Hammerspoon runtime, macOS Window Server / Mission Control, and the `hs.settings` plist. |
| [`architecture-components.mermaid`](architecture-components.mermaid) | C4 L3 — Component | The internals of `SpacesSync.spoon`: Public API, Watcher, Sync Engine, Position Map, Sync Group Lookup, Name Store, Popup, Picker, and the Hammerspoon APIs they depend on. |

## How they relate

- **Context** answers *who talks to SpacesSync and what does it talk to.*
- **Component** answers *what's inside SpacesSync and how do the pieces collaborate.*
- **Workflow (current)** is a dynamic view of today's behavior — it sequences the components from the architecture diagrams around the most important user action.
- **Workflow (roadmap)** is the same dynamic view, redesigned to close the silent-drop gap.

## Reading workflow-roadmap

The roadmap is **near-identical to current** by design. After examining the alternatives (pending triggers, drain loops, echo classifiers, eager baseline writes), we concluded the simple `syncInProgress`/`is_running` toggle the code already has IS the right design for this use case.

The roadmap diagram exists to document that decision — the "Design intent" panel lists what we deliberately chose NOT to build, and why. The accepted tradeoff is that real user swipes arriving inside the ~1.4s ignore window are silently dropped; the user can simply re-swipe.

## Vocabulary

The diagrams use the canonical terms from [`../vocabulary.md`](../vocabulary.md): *display*, *position number*, *sync group*, *trigger*, *target*, *Space index*, *workspace*, *switch delay*, *debounce period*. If you find a diagram using "monitor" or "source/partner", fix it — those are deprecated.
