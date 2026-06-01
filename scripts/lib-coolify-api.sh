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
    echo "ERROR: $COOLIFY_REGISTRY not found. Run /setup-coolify init first." >&2
    return 1
  fi
  local exists
  exists=$(python3 -c "
import json,sys
d=json.load(open('$COOLIFY_REGISTRY'))
print('yes' if d.get('servers',{}).get('$alias') else 'no')
")
  if [ "$exists" != "yes" ]; then
    echo "ERROR: server alias '$alias' not found in $COOLIFY_REGISTRY" >&2
    return 1
  fi
  COOLIFY_URL=$(python3 -c "import json; print(json.load(open('$COOLIFY_REGISTRY'))['servers']['$alias']['url'])")
  COOLIFY_API_KEY=$(python3 -c "import json; print(json.load(open('$COOLIFY_REGISTRY'))['servers']['$alias']['api_key'])")
  COOLIFY_DOPPLER_ACCOUNT=$(python3 -c "import json; print(json.load(open('$COOLIFY_REGISTRY'))['servers']['$alias'].get('doppler_account',''))")
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
  coolify_curl GET "/projects" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('name')=='$name': print(p.get('uuid','')); break
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
  coolify_curl GET "/servers" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s.get('name')=='$name': print(s.get('uuid','')); break
"
}

coolify_get_destination_uuid() {
  local server_uuid="$1"
  # GET /servers does not currently expose destinations directly; some Coolify versions
  # require GET /destinations or GET /servers/{uuid}. Try /destinations first, fall back.
  local out
  out=$(coolify_curl GET "/destinations" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    echo "$out" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
if isinstance(d,list):
    for x in d:
        if x.get('server',{}).get('uuid')=='$server_uuid' or x.get('server_uuid')=='$server_uuid':
            print(x.get('uuid','')); break
    else:
        if d: print(d[0].get('uuid',''))
"
  fi
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
  coolify_curl GET "/applications" | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    if a.get('name')=='$name': print(a.get('uuid','')); break
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
