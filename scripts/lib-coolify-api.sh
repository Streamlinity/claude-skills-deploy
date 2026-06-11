#!/usr/bin/env bash
# lib-coolify-api.sh — Coolify REST API wrapper functions.
# Source this from other scripts. Do not execute directly.
#
# Required globals set by coolify_load_server: COOLIFY_URL, COOLIFY_API_KEY, COOLIFY_DOPPLER_ACCOUNT
# All lookups are by name — NO hardcoded UUIDs. Works across any Coolify instance.

set -euo pipefail

: "${COOLIFY_REGISTRY:=$HOME/.claude/coolify.json}"

coolify_load_server() {
  local alias="$1"
  if [ ! -f "$COOLIFY_REGISTRY" ]; then
    echo "ERROR: $COOLIFY_REGISTRY not found. Run /setup-coolify init_cicd first." >&2
    return 1
  fi
  # Warn when coolify.json is group- or world-readable — it contains API keys.
  local _perms
  _perms=$(stat -c '%a' "$COOLIFY_REGISTRY" 2>/dev/null || stat -f '%A' "$COOLIFY_REGISTRY" 2>/dev/null || echo "")
  if [ -n "$_perms" ] && [ "${_perms: -2}" != "00" ]; then
    echo "WARN: $COOLIFY_REGISTRY is readable by group/others (permissions: $_perms). Fix with: chmod 0600 $COOLIFY_REGISTRY" >&2
  fi
  local exists
  exists=$(python3 - "$COOLIFY_REGISTRY" "$alias" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print('yes' if d.get('servers', {}).get(sys.argv[2]) else 'no')
PY
)
  if [ "$exists" != "yes" ]; then
    echo "ERROR: server alias '$alias' not found in $COOLIFY_REGISTRY" >&2
    return 1
  fi
  read -r COOLIFY_URL COOLIFY_API_KEY COOLIFY_DOPPLER_ACCOUNT < <(python3 - "$COOLIFY_REGISTRY" "$alias" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d['servers'][sys.argv[2]]
print(s['url'], s['api_key'], s.get('doppler_account', ''))
PY
)
  # Export SERVER_ALIAS so dns_load_credentials subprocesses can scope credential
  # lookups to the correct entry in coolify.json (avoids first-match-wins across
  # multi-server setups).
  export SERVER_ALIAS="$1"
  export COOLIFY_URL COOLIFY_API_KEY COOLIFY_DOPPLER_ACCOUNT
}

coolify_curl() {
  local method="$1" path="$2" body="${3:-}"
  local url="${COOLIFY_URL}/api/v1${path}"
  if [ -n "$body" ]; then
    curl -sfS -X "$method" "$url" \
      -H "Authorization: Bearer ${COOLIFY_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sfS -X "$method" "$url" \
      -H "Authorization: Bearer ${COOLIFY_API_KEY}"
  fi
}

coolify_get_project_uuid() {
  local name="$1"
  coolify_curl GET "/projects" | _CSD_NAME="$name" python3 -c "
import json, sys, os
name = os.environ['_CSD_NAME']
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('data', [])
for p in items:
    if p.get('name') == name:
        print(p.get('uuid', '')); break
"
}

coolify_upsert_project() {
  local name="$1" desc="${2:-}"
  local uuid
  uuid=$(coolify_get_project_uuid "$name")
  if [ -z "$uuid" ]; then
    uuid=$(coolify_curl POST "/projects" "{\"name\":\"$name\",\"description\":\"$desc\"}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")
  fi
  echo "$uuid"
}

coolify_get_server_uuid() {
  local name="$1"
  coolify_curl GET "/servers" | _CSD_NAME="$name" python3 -c "
import json, sys, os
name = os.environ['_CSD_NAME']
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('data', [])
for s in items:
    if s.get('name') == name:
        print(s.get('uuid', '')); break
"
}

coolify_get_destination_uuid() {
  local server_uuid="$1"
  # Strategy 1 (preferred): scan existing apps for matching destination.server.uuid
  local out
  out=$(coolify_curl GET "/applications" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    local found
    found=$(echo "$out" | _CSD_SRV_UUID="$server_uuid" python3 -c "
import json, sys, os
server_uuid = os.environ['_CSD_SRV_UUID']
try: apps = json.load(sys.stdin)
except: sys.exit(0)
if not isinstance(apps, list): sys.exit(0)
for a in apps:
    d = a.get('destination', {}) or {}
    s = d.get('server') or {}
    if s.get('uuid') == server_uuid:
        print(d.get('uuid', '')); break
" 2>/dev/null || echo "")
    [ -n "$found" ] && echo "$found" && return 0
  fi
  # Strategy 2 (fallback): GET /destinations (works on some Coolify versions)
  out=$(coolify_curl GET "/destinations" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    echo "$out" | _CSD_SRV_UUID="$server_uuid" python3 -c "
import json, sys, os
server_uuid = os.environ['_CSD_SRV_UUID']
try: d = json.load(sys.stdin)
except: sys.exit(0)
if isinstance(d, list):
    for x in d:
        if x.get('server', {}).get('uuid') == server_uuid or x.get('server_uuid') == server_uuid:
            print(x.get('uuid', '')); break
" 2>/dev/null || true
  fi
  # Strategy 3 (implicit): empty stdout — Coolify auto-assigns at create time
}

coolify_get_github_app_uuid() {
  # Coolify exposes /private-github-apps in some versions; fall back to /sources.
  local out
  out=$(coolify_curl GET "/sources" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    echo "$out" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
items = d if isinstance(d,list) else d.get('data',[])
for x in items:
    if (x.get('type')=='github_app' or 'github' in str(x.get('name','')).lower()):
        print(x.get('uuid','')); break
"
  fi
}

coolify_find_app_by_name() {
  local name="$1"
  coolify_curl GET "/applications" | _CSD_NAME="$name" python3 -c "
import json, sys, os
name = os.environ['_CSD_NAME']
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('data', [])
for a in items:
    if a.get('name') == name:
        print(a.get('uuid', '')); break
"
}

coolify_set_app_envs() {
  local app_uuid="$1"
  # Stdin: JSON array of {key, value, is_preview} objects
  local body
  body=$(cat | python3 -c "import json,sys; print(json.dumps({'data': json.load(sys.stdin)}))")
  coolify_curl PATCH "/applications/${app_uuid}/envs/bulk" "$body"
}

coolify_deploy_app() {
  local app_uuid="$1"
  coolify_curl GET "/deploy?uuid=${app_uuid}&force=false" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
deps = d.get('deployments',[])
if deps: print(deps[0].get('deployment_uuid',''))
"
}
