#!/bin/bash
# check-version-bump.sh — pre-commit guard against shipping plugin changes
# without a corresponding version bump.
#
# Two checks, both fail with drift=1:
#
#   1. Bump check (conditional). For each plugins/X/ with any staged file,
#      require the staged version of plugins/X/.claude-plugin/plugin.json to
#      differ from HEAD. Comparison reads from git's index (`git show :path`)
#      so it works whether or not the manifest itself is staged — unmodified
#      manifests appear identical to HEAD and trigger the gate.
#
#   2. Marketplace parity (unconditional). For each plugin in the staged
#      .claude-plugin/marketplace.json, require its version to equal the
#      corresponding plugins/X/.claude-plugin/plugin.json version. This
#      catches the mistake where one is bumped without the other — the
#      marketplace catalog must always advertise what plugin.json actually
#      ships.
#
# Used by .githooks/pre-commit alongside check-lib-sync.sh.

set -eu

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

extract_version() {
  # Reads JSON on stdin, prints the value of the top-level "version" field, or
  # nothing if absent. Tolerates whitespace; assumes a flat manifest.
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/'
}

extract_marketplace_version() {
  # Args: $1 = plugin name to look up in marketplace.json plugins[].
  # Reads JSON on stdin. Falls back to a (best-effort) shell parser when
  # python3 is missing — pre-commit hosts almost always have python3.
  local target="$1"
  if command -v python3 >/dev/null 2>&1; then
    PLUGIN_NAME="$target" python3 -c '
import json, os, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
target = os.environ.get("PLUGIN_NAME", "")
for p in data.get("plugins", []) or []:
    if p.get("name") == target:
        v = p.get("version")
        if v:
            print(v)
        break
' 2>/dev/null
  else
    awk -v target="$target" '
      /"name"[[:space:]]*:[[:space:]]*"/ {
        match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]+"/)
        seg = substr($0, RSTART, RLENGTH)
        sub(/.*:[[:space:]]*"/, "", seg)
        sub(/".*/, "", seg)
        current = seg
      }
      current == target && /"version"[[:space:]]*:[[:space:]]*"/ {
        match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]+"/)
        seg = substr($0, RSTART, RLENGTH)
        sub(/.*:[[:space:]]*"/, "", seg)
        sub(/".*/, "", seg)
        print seg
        exit
      }
    '
  fi
}

drift=0

# Iterate over each plugin directory.
for plugin_dir in plugins/*/; do
  plugin_name=$(basename "$plugin_dir")
  manifest="${plugin_dir}.claude-plugin/plugin.json"

  # Any staged files under this plugin?
  staged=$(git diff --cached --name-only -- "$plugin_dir" 2>/dev/null || true)
  [ -z "$staged" ] && continue

  if [ ! -f "$manifest" ]; then
    echo "version-bump: $plugin_name has staged changes but no manifest at $manifest" >&2
    drift=1
    continue
  fi

  staged_version=$(git show ":$manifest" 2>/dev/null | extract_version || true)
  head_version=$(git show "HEAD:$manifest" 2>/dev/null | extract_version || true)

  if [ -z "$staged_version" ]; then
    echo "version-bump: $manifest has no parseable \"version\" field in the staged tree" >&2
    drift=1
    continue
  fi

  if [ -z "$head_version" ]; then
    # New plugin — manifest absent in HEAD. Nothing to compare against; pass.
    continue
  fi

  if [ "$staged_version" = "$head_version" ]; then
    drift=1
    {
      printf '\n'
      printf 'version-bump: 🚨 %s has staged changes without a version bump.\n' "$plugin_name"
      printf '\n'
      printf '  Staged files in this plugin:\n'
      printf '%s\n' "$staged" | sed 's/^/    /'
      printf '\n'
      printf '  Current version (HEAD and index): %s\n' "$staged_version"
      printf '\n'
      printf '  → Bump %s to a new version (semver: PATCH for fixes,\n' "$manifest"
      printf '    MINOR for new behavior, MAJOR for breaking changes), then:\n'
      printf '        git add %s\n' "$manifest"
      printf '  → Add a PROJECT_CHANGELOG.md entry describing the change.\n'
      printf '\n'
    } >&2
  fi
done

# --- Marketplace parity check (unconditional) -------------------------------
# Compares plugins[X].version in .claude-plugin/marketplace.json against the
# version in plugins/X/.claude-plugin/plugin.json. Runs whether or not those
# files are staged: marketplace ↔ plugin.json must always agree.
marketplace="${marketplace:-.claude-plugin/marketplace.json}"
if [ -f "$marketplace" ]; then
  for plugin_dir in plugins/*/; do
    plugin_name=$(basename "$plugin_dir")
    manifest="${plugin_dir}.claude-plugin/plugin.json"
    [ -f "$manifest" ] || continue

    # Read versions from the index so the check sees what's about to commit.
    # Fall back to disk if the file isn't tracked.
    pj_version=$(git show ":$manifest" 2>/dev/null | extract_version || true)
    [ -z "$pj_version" ] && pj_version=$(extract_version <"$manifest" || true)

    mp_version=$(git show ":$marketplace" 2>/dev/null | extract_marketplace_version "$plugin_name" || true)
    [ -z "$mp_version" ] && mp_version=$(extract_marketplace_version "$plugin_name" <"$marketplace" || true)

    if [ -z "$pj_version" ] || [ -z "$mp_version" ]; then
      # Can't compare — flag as drift only if marketplace lists this plugin.
      if grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$plugin_name\"" "$marketplace" 2>/dev/null; then
        echo "version-bump: marketplace parity for $plugin_name unreadable (plugin.json=${pj_version:-?}, marketplace=${mp_version:-?})" >&2
        drift=1
      fi
      continue
    fi

    if [ "$pj_version" != "$mp_version" ]; then
      drift=1
      {
        printf '\n'
        printf 'version-bump: 🚨 marketplace ↔ plugin.json drift for %s.\n' "$plugin_name"
        printf '\n'
        printf '  %s\n' "$manifest"
        printf '    version: %s\n' "$pj_version"
        printf '  %s\n' "$marketplace"
        printf '    version: %s   (entry %s)\n' "$mp_version" "$plugin_name"
        printf '\n'
        printf '  → The marketplace advertises a different version than the plugin manifest.\n'
        printf '    Update %s so its plugins[].version for %s matches %s.\n' "$marketplace" "$plugin_name" "$pj_version"
        printf '\n'
      } >&2
    fi
  done
fi

if [ "$drift" -eq 0 ]; then
  echo "version-bump: ✓ all plugin changes carry a version bump (marketplace ↔ plugin.json in parity)"
fi

exit "$drift"
