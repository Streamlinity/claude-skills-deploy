#!/usr/bin/env bash
# lib-doppler-api.sh — Doppler CLI wrapper.
# Source this from other scripts. Do not execute directly.
#
# Workspace selection: The Doppler CLI uses the DOPPLER_TOKEN env var to scope
# all commands to a specific workspace. doppler_load_account reads this token
# from ~/.claude/coolify.json (servers.<alias>.doppler_token) and exports it so
# every subsequent doppler_cmd call targets the correct Doppler workspace for the
# given server alias. Without this, the CLI falls back to the ambient interactive
# login, which may be a different workspace than intended.

set -euo pipefail

: "${COOLIFY_REGISTRY:=$HOME/.claude/coolify.json}"

doppler_load_account() {
  local server_alias="$1"
  if [ ! -f "$COOLIFY_REGISTRY" ]; then
    echo "ERROR: $COOLIFY_REGISTRY not found." >&2; return 1
  fi

  local _acct _tok
  read -r _acct _tok < <(python3 - "$COOLIFY_REGISTRY" "$server_alias" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get('servers', {}).get(sys.argv[2], {})
print(s.get('doppler_account', ''), s.get('doppler_token', ''))
PY
)

  if [ -z "$_acct" ]; then
    echo "ERROR: server '$server_alias' has no doppler_account field in $COOLIFY_REGISTRY" >&2
    return 1
  fi

  DOPPLER_ACCOUNT="$_acct"
  export DOPPLER_ACCOUNT

  # If a per-server Doppler token is stored, export it so the CLI uses the
  # correct workspace for this server alias (overrides ambient interactive auth).
  if [ -n "$_tok" ]; then
    export DOPPLER_TOKEN="$_tok"
  fi
}

doppler_cmd() {
  doppler "$@"
}

doppler_check_key() {
  local project="$1" config="$2" key="$3"
  local value
  value=$(doppler_cmd secrets get --project "$project" --config "$config" "$key" --plain 2>/dev/null || echo "")
  if [ -z "$value" ]; then
    return 1
  fi
  if [ "$value" = "TODO_REPLACE_BEFORE_DEPLOY" ]; then
    return 2  # placeholder — present but not real
  fi
  return 0
}

doppler_create_service_token() {
  local project="$1" config="$2" name="$3"
  doppler_cmd configs tokens create "$name" -p "$project" -c "$config" --plain 2>/dev/null
}

doppler_download_secrets() {
  local project="$1" config="$2"
  doppler_cmd secrets download --project "$project" --config "$config" --no-file --format docker 2>/dev/null
}
