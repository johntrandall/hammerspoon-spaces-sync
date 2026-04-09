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
- [ ] Create a GitHub release with `SpacesSync.spoon.zip` (see procedure below)
- [ ] Update the Hammerspoon/Spoons PR (see procedure below)
- [ ] Update README note if PR status changes (merged, closed, etc.)

## Creating a GitHub release

```bash
# Build the zip
cd /tmp
mkdir -p SpacesSync.spoon
cp ~/dev/macos-spaces-multimonitor-sync-hammerspoon/Source/SpacesSync.spoon/init.lua SpacesSync.spoon/
cp ~/dev/macos-spaces-multimonitor-sync-hammerspoon/Source/SpacesSync.spoon/docs.json SpacesSync.spoon/
zip -r SpacesSync.spoon.zip SpacesSync.spoon/

# Create the release (bump version tag as needed)
gh release create v1.x /tmp/SpacesSync.spoon.zip \
  --repo johntrandall/hammerspoon-spaces-sync \
  --title "SpacesSync v1.x" \
  --notes "Release notes here"

# Clean up
rm -rf /tmp/SpacesSync.spoon /tmp/SpacesSync.spoon.zip
```

## Updating the Hammerspoon/Spoons PR

The Spoon lives in two places: this repo (source of truth) and the
`johntrandall/Spoons` fork (delivery vehicle for the upstream PR).
The fork lives at `~/dev/Spoons` per the fix-upstream convention
(contribution forks go in `~/dev/`, no Forgejo remote per ADR-022).

After pushing changes here, sync them to the fork:

```bash
cd ~/dev/Spoons
git checkout add-spaces-sync-spoon

# Copy updated Spoon from this repo
cp ~/dev/macos-spaces-multimonitor-sync-hammerspoon/Source/SpacesSync.spoon/init.lua Source/SpacesSync.spoon/
cp ~/dev/macos-spaces-multimonitor-sync-hammerspoon/Source/SpacesSync.spoon/docs.json Source/SpacesSync.spoon/

# Commit and push
git add Source/SpacesSync.spoon/
git commit -m "Update SpacesSync Spoon — <summary of changes>"
git push origin add-spaces-sync-spoon
```

The PR at Hammerspoon/Spoons#361 updates automatically when the branch is pushed.
