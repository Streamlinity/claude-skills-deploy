#!/usr/bin/env bash
# seed.sh — Explicit Doppler gap-fill from .env files.
# Reads coolify.yaml for project/server info. Seeds keys missing from Doppler
# stg/dev configs from .env.local, and prd config from .env.production.
# Never overwrites existing Doppler values. Logs every key set.
#
# Usage:
#   bash scripts/seed.sh [coolify.yaml path]
#
# Prerequisites:
#   ~/.claude/coolify.json populated with server alias entry
#   Doppler CLI authenticated
#   .env.local and/or .env.production in same directory as coolify.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-coolify-api.sh"
source "$SCRIPT_DIR/lib-doppler-api.sh"

YAML_PATH="${1:-./coolify.yaml}"
[ -f "$YAML_PATH" ] || { echo "ERROR: $YAML_PATH not found" >&2; exit 1; }

eval "$(python3 "$SCRIPT_DIR/lib-config.py" emit-yaml-vars "$YAML_PATH")"
coolify_load_server "$SERVER"
doppler_load_account "$SERVER"

YAML_DIR="$(cd "$(dirname "$YAML_PATH")" && pwd)"
ENV_LOCAL="$YAML_DIR/.env.local"
ENV_PROD="$YAML_DIR/.env.production"

if [ ! -f "$ENV_LOCAL" ] && [ ! -f "$ENV_PROD" ]; then
  echo "seed: no .env.local or .env.production found in $YAML_DIR — nothing to seed"
  exit 0
fi

_parse_env_file() {
  local file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      v="${v#\"}" ; v="${v%\"}"
      v="${v#\'}" ; v="${v%\'}"
      printf '%s\t%s\n' "$k" "$v"
    fi
  done < "$file"
}

_fill_missing_from_env() {
  local env_file="$1"; shift
  local doppler_project="$1"; shift
  local configs=("$@")

  [ -f "$env_file" ] || return 0

  declare -A _env_vals
  while IFS=$'\t' read -r k v; do
    _env_vals["$k"]="$v"
  done < <(_parse_env_file "$env_file")

  [ "${#_env_vals[@]}" -eq 0 ] && return 0

  local filled=0
  for cfg in "${configs[@]}"; do
    for k in "${!_env_vals[@]}"; do
      if ! doppler_check_key "$doppler_project" "$cfg" "$k" 2>/dev/null; then
        local v="${_env_vals[$k]}"
        if python3 -c "import json,sys; sys.stdout.write(json.dumps({sys.argv[1]: sys.argv[2]}))" \
               "$k" "$v" \
             | doppler secrets upload --project "$doppler_project" --config "$cfg" - \
               >/dev/null 2>&1; then
          echo "seed: gap-filled $k → $doppler_project/$cfg (from $env_file)"
          filled=$((filled+1))
        else
          echo "seed: WARNING: could not set $k in $doppler_project/$cfg" >&2
        fi
      fi
    done
  done

  [ "$filled" -gt 0 ] && echo "seed: complete ($filled key(s) set from $env_file)"
  return 0
}

echo ""
echo "seed: filling missing Doppler keys from .env files"
[ -f "$ENV_LOCAL" ] && echo "  .env.local       → $DOPPLER_PROJECT/$STAGING_DOPPLER + dev"
[ -f "$ENV_PROD"  ] && echo "  .env.production  → $DOPPLER_PROJECT/$PROD_DOPPLER"

if [ -f "$ENV_LOCAL" ]; then
  _fill_missing_from_env "$ENV_LOCAL" "$DOPPLER_PROJECT" "$STAGING_DOPPLER" "dev"
fi
if [ -f "$ENV_PROD" ]; then
  _fill_missing_from_env "$ENV_PROD" "$DOPPLER_PROJECT" "$PROD_DOPPLER"
fi
echo ""
echo "seed: done"
