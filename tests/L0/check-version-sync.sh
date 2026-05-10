#!/usr/bin/env bash
# tests/L0/check-version-sync.sh
#
# L0 guard: obj.version in init.lua matches the latest release tag.
#
# Per dev-docs/test-strategy.md § Active Levels L0:
#   "version sync between obj.version and the latest release tag"
#
# Catches: a release that bumped the tag but forgot to bump obj.version
# (or vice versa).
#
# SKIP cases (per the strategy doc's "release commit pending" note):
#   * No git tags yet (first release)
#   * HEAD is ahead of the latest tag (current work-in-progress
#     commits would naturally diverge until the next tag)
#
# Pre-release tags (e.g. v0.3-design, v0.4-rc1) are excluded from
# "latest release tag" — they sort lexically above the actual release
# under sort -V and would produce false positives.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_LUA="$REPO_ROOT/Source/SpacesSync.spoon/init.lua"

if [[ ! -f "$INIT_LUA" ]]; then
  echo "L0 version-sync FAIL: $INIT_LUA does not exist"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "L0 version-sync SKIP: git not on PATH"
  exit 0
fi

cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "L0 version-sync SKIP: not inside a git work tree"
  exit 0
fi

# Pull obj.version from the source.
INIT_VERSION="$(grep -E '^obj\.version *= *"' "$INIT_LUA" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "$INIT_VERSION" ]]; then
  echo "L0 version-sync FAIL: could not extract obj.version from $INIT_LUA"
  exit 1
fi

# Latest release tag = vMAJOR[.MINOR[.PATCH]] only. Excludes
# pre-release suffixes (v0.3-design, v0.4-rc1, etc.) by anchoring the
# regex to the end. sort -V then orders by semver.
LATEST_TAG="$(git tag --list 'v*' \
              | grep -E '^v[0-9]+(\.[0-9]+)?(\.[0-9]+)?$' \
              | sort -V | tail -1)"
if [[ -z "$LATEST_TAG" ]]; then
  echo "L0 version-sync SKIP: no release v* tag exists yet (first release pending)"
  exit 0
fi

TAG_VERSION="${LATEST_TAG#v}"

if [[ "$INIT_VERSION" != "$TAG_VERSION" ]]; then
  # Drift is OK if HEAD is AHEAD of the tag (in-flight work between
  # releases). It's only a FAIL if HEAD == tag SHA but the strings
  # disagree.
  HEAD_SHA="$(git rev-parse HEAD)"
  TAG_SHA="$(git rev-parse "$LATEST_TAG"^{commit} 2>/dev/null || echo "")"
  if [[ "$HEAD_SHA" == "$TAG_SHA" ]]; then
    echo "L0 version-sync FAIL: obj.version=$INIT_VERSION but tag $LATEST_TAG points to this commit"
    exit 1
  fi
  echo "L0 version-sync PASS: obj.version=$INIT_VERSION; latest tag $LATEST_TAG points to a prior commit (HEAD ahead — pre-release in flight)"
  exit 0
fi

echo "L0 version-sync PASS: obj.version=$INIT_VERSION matches latest tag $LATEST_TAG"
