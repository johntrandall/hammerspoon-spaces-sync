# hammerspoon-macos-spaces-sync

Hammerspoon module that synchronizes macOS Spaces across monitors in configurable sync groups.

## Project Structure

- `spaces-sync.lua` — the module (symlinked into `~/.hammerspoon/`)
- `.spaces-sync-config.lua` — personal config (gitignored, loaded at runtime)
- `spaces-sync-config.example.lua` — config template for new users

## Hammerspoon Development Notes

### API conventions
- All Hammerspoon extension APIs use camelCase naming.
- Pure Lua extensions return a table with functions/methods/constants.
- Third-party modules (like this one) install to `~/.hammerspoon/` and load via `require()`.

### hs.spaces quirks
- `hs.spaces` uses **private macOS APIs** — behavior can change between point releases. Tested on macOS 15.5 (Sequoia).
- `hs.spaces.gotoSpace(spaceID)` is **asynchronous** — the space switch happens after the call returns. Immediate verification via `activeSpaceOnScreen()` is unreliable.
- Rapid back-to-back `gotoSpace()` calls get **silently dropped** by macOS. Must chain with a delay (~300ms between calls).
- `hs.spaces.watcher` fires for both user-initiated and programmatic space changes — the module uses a `syncInProgress` flag + debounce to prevent loops.
- `hs.spaces.moveWindowToSpace()` is broken on Sequoia — not used here but relevant for related work.

### Lazy extension loading
- Hammerspoon lazy-loads extensions on first use. Extensions like `hs.screen`, `hs.spaces`, `hs.application` should be `require()`d upfront in modules where timing matters (e.g., during sync callbacks). A lazy load mid-callback adds unpredictable latency.

### Documentation format
- Hammerspoon docstrings use `---` prefix for Lua, `///` for Objective-C.
- Functions: signature with return type, one-line description, Parameters, Returns, optional Notes.
- Methods: same format but colon notation (`hs.foo:method()`).

## Available Documentation MCPs

- **Context7** and **Dash** MCP servers have Lua and Hammerspoon docs available. Use these for API reference lookups rather than web searches.

## Testing

No automated tests yet. Testing requires a multi-monitor Mac — `hs.spaces.gotoSpace()` needs real displays. See README for manual test procedure.
