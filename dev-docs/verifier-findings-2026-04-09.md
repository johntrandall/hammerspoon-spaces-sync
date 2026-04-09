# Verifier Findings — 2026-04-09

Three parallel verifiers audited the SpacesSync Spoon. Findings are listed with status.

## Already Fixed (committed)

| ID | Fix | Commit |
|---|---|---|
| L1 | `obj.logger.level` checks removed — let logger filter | `641d442` |
| L4 | Chained doAfter timers now tracked in `state.pendingSyncTimer` | `5268442` |
| L5 | `stop()` resets `syncInProgress` and cancels pending sync timer | `5268442` |

## Remaining — Bugs

### D3: README documents nonexistent `debug` property
**Files:** README.md lines 44, 57, 171-172
**Problem:** README shows `spoon.SpacesSync.debug = true` and lists `debug` in the Options table. The Spoon has no `debug` property — it uses `obj.logger` (an `hs.logger` instance). The correct API is `spoon.SpacesSync.logger.setLogLevel('debug')`.
**Fix:** Replace all `debug` references in README with the logger API. Update the Options table to show `logger` instead of `debug`. Update the Logging section similarly.

### D1: CLAUDE.md references deleted files (pre-Spoon layout)
**Files:** CLAUDE.md lines 11-14
**Problem:** Lists `spaces-sync.lua`, `.spaces-sync-config.lua`, `spaces-sync-config.example.lua` — all deleted in the Spoon restructure. Doesn't mention `Source/SpacesSync.spoon/`.
**Fix:** Rewrite the Project Structure section to match reality.

### D4: Homepage URL in Spoon metadata
**File:** Source/SpacesSync.spoon/init.lua line 27
**Problem:** `obj.homepage` was `"https://github.com/johntrandall/hammerspoon-spaces-sync"` — wrong username and repo name.
**Status:** Already fixed in commit `ba2a48c`. Verify the current value is correct.

## Remaining — Medium

### L3: No hs.screen.watcher — monitor hotplug doesn't rebuild position map
**File:** Source/SpacesSync.spoon/init.lua
**Problem:** `rebuildPositionMap()` runs once in `start()`. If a monitor is disconnected/reconnected, positions go stale. `syncTarget` handles nil screens gracefully (no crash), but new monitors won't be synced.
**Fix:** Add `hs.screen.watcher.new(rebuildPositionMap)` in `start()`, stop it in `stop()`.

### L6: hs.screen.find() used without nil check in startup logging
**File:** Source/SpacesSync.spoon/init.lua lines 505-507, 517, 529
**Problem:** `hs.screen.find(uuid)` can return nil if screen disappeared between `rebuildPositionMap()` and logging. `screen:frame()` and `screen:name()` would crash.
**Fix:** Add nil guards, or use `getDisplayLabel(uuid)` which already handles nil.

### D2: README claims "checks all four settings" — only checks 2
**File:** README.md line 143
**Problem:** Says "The Spoon checks all four on start" but `checkEnvironment()` only checks `spans-displays` and `mru-spaces`. Does not check `workspaces-auto-swoosh` or `GloballyEnabled`.
**Fix:** Either add the missing checks to `checkEnvironment()`, or change the README to say "checks the two required settings."

### U1: Manual install references nonexistent SpacesSync.spoon.zip
**File:** README.md line 23
**Problem:** "Download `SpacesSync.spoon.zip`" — file doesn't exist, no release artifact.
**Fix:** Remove the Manual install section until a release is published, or add a build step that creates the zip.

### U3: Install path not sequential
**File:** README.md
**Problem:** `configure-macos.sh` appears after the Configuration section. A user following top-to-bottom would: clone, install, edit init.lua, reload, see warnings, then scroll back to find the configure script.
**Fix:** Mention `configure-macos.sh` right after `install.sh` in the install steps, before the init.lua section.

### U6: No multi-group syncGroups example in README
**File:** README.md config section
**Problem:** Only shows `{ {1, 2} }` and `{ {2, 3, 4} }`. Never shows two independent groups like `{ {1, 2}, {3, 4} }`.
**Fix:** Add a multi-group example to the Configuration section.

### D6: configure-macos.sh final status check uses wrong variable
**File:** configure-macos.sh line 60
**Problem:** `$current` at line 60 holds the Stage Manager value, not `spans-displays`. The logout warning condition is checking the wrong thing.
**Fix:** Capture the spans-displays check result in a dedicated variable.

## Remaining — Low/Polish

### L9: Local `os` shadows Lua stdlib
**File:** Source/SpacesSync.spoon/init.lua line 428
**Problem:** `local os = getOSVersion()` shadows Lua's `os` library. No impact in current code but a naming hazard.
**Fix:** Rename to `osVer` or `macosVer`.

### L2: `uuid` variable shadowed in inner loop
**File:** Source/SpacesSync.spoon/init.lua line 370
**Problem:** `for _, uuid in ipairs(targets)` shadows the outer `uuid`. Not a bug (outer value captured in `changedUUID`), but reduces readability.
**Fix:** Rename to `targetUUID`.

### U4: Accessibility permission steps not explained
**File:** README.md line 122
**Problem:** Says "Accessibility permissions for Hammerspoon" without explaining how to grant them.
**Fix:** Add: "System Settings > Privacy & Security > Accessibility > add Hammerspoon"

### U7: No Hammerspoon install command
**File:** README.md
**Problem:** Links to hammerspoon.org but doesn't say `brew install --cask hammerspoon`.
**Fix:** Add one-liner.

### U8: "For AI agents" section buries useful debugging info
**File:** README.md lines 184-194
**Problem:** `hs -c` examples are useful for all users but hidden under an AI-agent heading.
**Fix:** Rename to "Debugging from the terminal" or similar. Move the CLAUDE.md pointer into CLAUDE.md itself.

### D5: Download URL placeholder in init.lua
**File:** Source/SpacesSync.spoon/init.lua line 18
**Problem:** Points to Hammerspoon Spoons repo where it hasn't been submitted yet.
**Fix:** Leave as-is until published, or replace with GitHub repo URL.
