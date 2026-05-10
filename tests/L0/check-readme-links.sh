#!/usr/bin/env bash
# tests/L0/check-readme-links.sh
#
# L0 guard: link integrity across in-repo Markdown.
#
# Per dev-docs/test-strategy.md § Active Levels L0:
#   "Repo conventions: lua syntax ..., `docs.json` shape, version sync
#    between `obj.version` and the latest release tag, README link
#    integrity. Headless. Runs on any host without Hammerspoon."
#
# WHAT THIS CHECKS
#   For every tracked .md file under the repo root (excluding worktrees
#   and .git), extract all inline `[text](path)` markdown links and
#   verify that local file paths actually resolve.
#
# SKIP CATEGORIES (counted, not failed)
#   * URL schemes: http://, https://, mailto:, ftp://, file:// — not
#     fetched (this check is offline).
#   * Pure anchors: `#section` — anchor resolution is rendering-engine
#     specific (GitHub heading-slug rules differ from MultiMarkdown);
#     not in scope here.
#   * Local-only absolute paths: `~/...`, `/Users/...`, `../../../dev/...`.
#     These show up in cross-repo references (e.g. test-strategy.md
#     pointers to ~/dev/autocoder_v3) that are valid from John's local
#     checkout but broken on GitHub. Per the briefing convention they
#     are intentionally local-only; we count and report them rather
#     than fail.
#   * Lines containing `<!-- no-link-check -->` — explicit per-line
#     opt-out marker.
#
# WHAT FAILS
#   Any other relative or repo-root-relative link whose path part
#   (after stripping `?query` and `#fragment`) does NOT exist on disk
#   when resolved relative to the .md file's directory.
#
# OUT OF SCOPE
#   * Anchor existence (whether `[X](file.md#heading)` points at a real
#     heading inside file.md) — heading slug rules vary by renderer.
#     We strip `#fragment` and check only that the file exists.
#   * Reference-style links `[X][ref]` — none in this repo today; can
#     be added later if the convention spreads.
#   * Image references in HTML tags `<img src=...>` — not used.
#   * Bare URLs without brackets — markdown autolinks; not in scope.
#
# EXIT CODES
#   0 — PASS or SKIP (no broken local links found)
#   1 — FAIL (at least one broken local link)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Collect target .md files.
# ---------------------------------------------------------------------------
#
# Scope: any .md file under the repo, EXCEPT under .claude/worktrees/
# (those are isolated experiments, not part of the published surface)
# and .git/ (obviously).
mapfile -t MD_FILES < <(
  find . \
    -type d \( -name '.git' -o -path './.claude/worktrees' \) -prune \
    -o -type f -name '*.md' -print \
  | sed 's|^\./||' \
  | sort
)

if [[ ${#MD_FILES[@]} -eq 0 ]]; then
  echo "L0 readme-links SKIP: no .md files found under $REPO_ROOT"
  exit 0
fi

# ---------------------------------------------------------------------------
# Counters.
# ---------------------------------------------------------------------------
checked=0
skipped_url=0
skipped_anchor=0
skipped_local_only=0
skipped_marker=0
broken=0
declare -a BROKEN_DETAIL=()
declare -a LOCAL_ONLY_DETAIL=()

# ---------------------------------------------------------------------------
# Per-file scan.
# ---------------------------------------------------------------------------
#
# Awk extracts `[text](target)` matches with the line number. Output
# format: "<lineno>\t<target>". We process line-by-line in bash so we
# can do per-link `<!-- no-link-check -->` filtering by re-reading the
# source line.

for md in "${MD_FILES[@]}"; do
  md_dir="$(dirname "$md")"

  # Extract `[text](path)` matches. The pattern is intentionally
  # conservative — it does NOT try to handle nested brackets in link
  # text (rare; not present in this repo). Outputs one "lineno\ttarget"
  # per match.
  while IFS=$'\t' read -r lineno target; do
    [[ -z "${target:-}" ]] && continue

    # Per-line opt-out marker.
    src_line=$(awk -v n="$lineno" 'NR==n { print; exit }' "$md")
    if [[ "$src_line" == *'<!-- no-link-check -->'* ]]; then
      skipped_marker=$((skipped_marker + 1))
      continue
    fi

    # Strip query and fragment to get path part.
    path="${target%%\#*}"
    path="${path%%\?*}"

    # URL schemes — not checked (offline).
    if [[ "$path" =~ ^(https?|mailto|ftp|file):// || "$target" =~ ^mailto: ]]; then
      skipped_url=$((skipped_url + 1))
      continue
    fi

    # Pure anchor link (no path part after stripping `#fragment`).
    if [[ -z "$path" ]]; then
      skipped_anchor=$((skipped_anchor + 1))
      continue
    fi

    # Local-only absolute paths.
    if [[ "$path" =~ ^~/ || "$path" =~ ^/Users/ || "$path" =~ ^\.\./\.\./\.\./ ]]; then
      skipped_local_only=$((skipped_local_only + 1))
      LOCAL_ONLY_DETAIL+=("$md:$lineno -> $target")
      continue
    fi

    # Resolve relative to the .md file's directory.
    if [[ "$path" == /* ]]; then
      # Repo-absolute path (rare but supported): treat leading / as repo root.
      resolved="$REPO_ROOT${path}"
    else
      resolved="$REPO_ROOT/$md_dir/$path"
    fi

    checked=$((checked + 1))
    if [[ ! -e "$resolved" ]]; then
      broken=$((broken + 1))
      BROKEN_DETAIL+=("$md:$lineno -> $target  (resolved: $resolved)")
    fi
  done < <(
    awk '
      {
        line = $0
        # Match every occurrence of ](TARGET) on this line.
        while (match(line, /\]\([^)]+\)/)) {
          target = substr(line, RSTART + 2, RLENGTH - 3)
          print NR "\t" target
          line = substr(line, RSTART + RLENGTH)
        }
      }
    ' "$md"
  )
done

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------

if [[ $broken -eq 0 ]]; then
  echo "L0 readme-links PASS: $checked local link(s) checked across ${#MD_FILES[@]} .md file(s), 0 broken"
  echo "  skipped: $skipped_url URL(s), $skipped_anchor anchor-only, $skipped_local_only local-only path(s), $skipped_marker opt-out marker(s)"
  if [[ $skipped_local_only -gt 0 ]]; then
    echo "  local-only paths (intentionally not verified — valid from local checkout, broken on GitHub):"
    for line in "${LOCAL_ONLY_DETAIL[@]}"; do
      echo "    $line"
    done
  fi
  exit 0
fi

echo "L0 readme-links FAIL: $broken broken local link(s) across ${#MD_FILES[@]} .md file(s)"
echo "  ($checked local link(s) checked; $skipped_url URL skip, $skipped_anchor anchor-only skip, $skipped_local_only local-only skip, $skipped_marker opt-out marker skip)"
for line in "${BROKEN_DETAIL[@]}"; do
  echo "  $line"
done
exit 1
