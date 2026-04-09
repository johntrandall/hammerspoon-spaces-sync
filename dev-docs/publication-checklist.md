# Publication Checklist

Run through this before publishing a new version of SpacesSync.

## Code Quality

- [ ] All `hs.logger` calls use correct levels (`.e` for errors, `.w` for warnings, `.i` for info, `.d` for debug)
- [ ] No raw `print()` calls — use `obj.logger` exclusively
- [ ] No hardcoded personal config (syncGroups, monitor positions, etc.)
- [ ] `obj.version` bumped
- [ ] Extensions preloaded at top of file (touch a function to force load)

## Security

- [ ] No user-controlled strings passed to `hs.execute()` — all shell commands hardcoded
- [ ] No dynamic `require()`, `load()`, `dofile()` with user input
- [ ] No network access, no file I/O beyond `defaults read`
- [ ] No secrets or credentials in source
- [ ] Author email is the public one (`john@johnrandall.com`), not a private address

## Spoon Conventions

- [ ] Metadata fields present: `name`, `version`, `author`, `homepage`, `license`
- [ ] `homepage` URL matches actual GitHub repo (`johntrandall/hammerspoon-spaces-sync`)
- [ ] Download URL in docstring header points to Spoons repo zip
- [ ] `init()` is a no-op (no side effects)
- [ ] `start()` activates, `stop()` deactivates, both return `self`
- [ ] `bindHotkeys()` uses `hs.spoons.bindHotkeysToSpec`
- [ ] `defaultHotkeys` variable exposed
- [ ] `logger` variable exposed with docstring
- [ ] All public methods and variables have `---` docstrings (Signature, Type, Description, Parameters, Returns)
- [ ] `docs.json` regenerated: `hs -c 'hs.doc.builder.genJSON("Source/SpacesSync.spoon")' | grep -v '^--' > Source/SpacesSync.spoon/docs.json`
- [ ] Verify docs.json entry count matches expectations

## Compatibility

- [ ] `TESTED_OS` matches the macOS version you actually tested on
- [ ] `TESTED_HS` matches the Hammerspoon version you actually tested on
- [ ] `MIN_OS_MAJOR` is correct (currently 15)
- [ ] Mission Control checks (`spans-displays`, `mru-spaces`) still use correct defaults keys

## Testing

- [ ] `hs.loadSpoon("SpacesSync")` loads without errors
- [ ] `spoon.SpacesSync:start()` logs position map and enables watcher
- [ ] `spoon.SpacesSync:stop()` disables cleanly
- [ ] `spoon.SpacesSync:toggle()` cycles on/off
- [ ] `spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)` binds without error
- [ ] Switching a space on a grouped monitor syncs targets
- [ ] Switching a space on an independent monitor does nothing
- [ ] Space count mismatch (target has fewer spaces) logs skip, doesn't crash
- [ ] No lazy extension loads during sync (check console for `Loading extension:` after start)

## Publishing

- [ ] Commit all changes to this repo
- [ ] Push to GitHub (`origin`) and Forgejo (`umbridge`)
- [ ] Copy updated `Source/SpacesSync.spoon/` into Hammerspoon/Spoons fork
- [ ] Open or update PR to `Hammerspoon/Spoons`
- [ ] Update README note if PR status changes (merged, closed, etc.)
