#!/bin/bash
# Read-side config helpers used by reminder scripts.
# Falls back to per-call defaults when jq or the config file is unavailable —
# absence of jq must never break the hook pipeline.
#
# MIRRORED FILE — must stay byte-identical with plugins/vdm-git/lib/config-read.sh.
# An automated dev-time guard against drift is tracked as a separate task; until
# then any change here MUST be applied to the vdm-git copy in the same commit.

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-path.sh"

vdm_config_read() {
  local section="$1" key="$2" default="$3"

  command -v jq >/dev/null 2>&1 || { printf '%s\n' "$default"; return; }

  local cfg
  cfg=$(resolve_config_path)
  [ -f "$cfg" ] || { printf '%s\n' "$default"; return; }

  # `// empty` would treat boolean false as missing, so we use an explicit
  # sentinel and check for object/key presence before reading the value.
  local value
  value=$(jq -r --arg s "$section" --arg k "$key" '
    if has($s) and ((.[$s] | type) == "object") and (.[$s] | has($k)) and (.[$s][$k] != null)
    then .[$s][$k] | tostring
    else "__VDM_MISSING__"
    end
  ' "$cfg" 2>/dev/null)
  if [ -z "$value" ] || [ "$value" = "__VDM_MISSING__" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$value"
  fi
}

vdm_is_enabled() {
  local section="$1"
  [ "$(vdm_config_read "$section" "enabled" "true")" = "true" ]
}

vdm_get_mode() {
  vdm_config_read "$1" "mode" "$2"
}
