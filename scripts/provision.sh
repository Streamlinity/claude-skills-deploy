#!/usr/bin/env bash
# provision.sh — Idempotent Coolify + Doppler app provisioning.
# Reads ./coolify.yaml. Uses lookup-by-name (no hardcoded UUIDs).
# Routes Doppler CLI calls via doppler_account from ~/.claude/coolify.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-coolify-api.sh"
source "$SCRIPT_DIR/lib-doppler-api.sh"
source "$SCRIPT_DIR/lib-dns-api.sh"

YAML_PATH="${1:-./coolify.yaml}"
[ -f "$YAML_PATH" ] || { echo "ERROR: $YAML_PATH not found" >&2; exit 1; }

# Run validate.sh first — bail on any error
if ! bash "$SCRIPT_DIR/validate.sh" "$YAML_PATH"; then
  echo "ERROR: validate.sh failed; aborting before any Coolify mutation." >&2
  exit 1
fi

# Parse coolify.yaml
eval "$(python3 -c "
import yaml
d=yaml.safe_load(open('$YAML_PATH'))
print(f\"PROJECT='{d.get('project','')}'\")
print(f\"DEPLOY_SERVER='{d.get('deploy_server','')}'\")
print(f\"SERVER_ALIAS='{d.get('server','')}'\")
print(f\"DOPPLER_PROJECT='{d.get('doppler_project','')}'\")
img=d.get('registry',{}).get('image','')
last=img.rsplit('/',1)[-1]
name,tag=(img.rsplit(':',1) if ':' in last else (img,'latest'))
print(f\"REGISTRY_IMAGE='{img}'\")
print(f\"REGISTRY_IMAGE_NAME='{name}'\")
print(f\"REGISTRY_IMAGE_TAG='{tag}'\")
print(f\"STAGING_DOMAIN='{d.get('environments',{}).get('staging',{}).get('domain','')}'\")
print(f\"STAGING_DOPPLER='{d.get('environments',{}).get('staging',{}).get('doppler_environment','')}'\")
print(f\"PROD_DOMAIN='{d.get('environments',{}).get('production',{}).get('domain','')}'\")
print(f\"PROD_DOPPLER='{d.get('environments',{}).get('production',{}).get('doppler_environment','')}'\")
print(f\"ENV_VARS='{' '.join(d.get('env_vars',[]))}'\")
print(f\"APP_PORT='{d.get('port',3000)}'\")
print(f\"HEALTH_CHECK_PATH='{d.get('health_check_path','/api/health')}'\")
")"

coolify_load_server "$SERVER_ALIAS"
doppler_load_account "$SERVER_ALIAS"

echo "provision: project=$PROJECT server=$SERVER_ALIAS ($COOLIFY_URL) doppler_account=$DOPPLER_ACCOUNT"

# 1. Discover Coolify topology by name — no hardcoded UUIDs.
PROJECT_UUID=$(coolify_upsert_project "$PROJECT" "Provisioned by /setup-coolify from $YAML_PATH")
[ -n "$PROJECT_UUID" ] || { echo "ERROR: failed to resolve project UUID for '$PROJECT'" >&2; exit 1; }
echo "  project_uuid=$PROJECT_UUID"

# Server name on a single-node Coolify install is conventionally "localhost", but
# is user-configurable in the Coolify UI. Read the configured name from coolify.json
# (optional field; defaults to "localhost" for backward compatibility).
SERVER_NAME=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
print(e.get('server_name','localhost'))
")
# MSRV-01/02: deploy_server in coolify.yaml overrides server_name from coolify.json.
# Fallback chain: deploy_server -> server_name -> "localhost".
if [ -n "${DEPLOY_SERVER:-}" ]; then
  DEPLOY_SERVER_NAME="$DEPLOY_SERVER"
  DEPLOY_SERVER_SOURCE="coolify.yaml deploy_server"
else
  DEPLOY_SERVER_NAME="$SERVER_NAME"
  DEPLOY_SERVER_SOURCE="coolify.json servers.$SERVER_ALIAS.server_name (default 'localhost')"
fi
DEPLOY_SERVER_UUID=$(coolify_get_server_uuid "$DEPLOY_SERVER_NAME")
[ -n "$DEPLOY_SERVER_UUID" ] || { echo "ERROR: server '$DEPLOY_SERVER_NAME' not found in Coolify (source: $DEPLOY_SERVER_SOURCE)" >&2; exit 1; }
DEST_UUID=$(coolify_get_destination_uuid "$DEPLOY_SERVER_UUID")
echo "  deploy_server=$DEPLOY_SERVER_NAME deploy_server_uuid=$DEPLOY_SERVER_UUID dest_uuid=${DEST_UUID:-<auto>} (source: $DEPLOY_SERVER_SOURCE)"

# SSH host: read from ~/.claude/coolify.json server entry. REQUIRED — no fallback.
# provision.sh creates a Docker volume on the Coolify server via SSH, so this must be set.
SSH_HOST=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
print(e.get('ssh_host',''))
")
if [ -z "$SSH_HOST" ]; then
  echo "ERROR: 'ssh_host' field is missing from servers.$SERVER_ALIAS in ~/.claude/coolify.json." >&2
  echo "Add it manually or re-run /setup-coolify init. Example:" >&2
  echo "  \"$SERVER_ALIAS\": { ..., \"ssh_host\": \"v_cicd_stream\" }" >&2
  exit 1
fi
echo "  ssh_host=$SSH_HOST"

# MSRV-04: deploy_ssh_host overrides ssh_host for SSH ops on the deployment VPS.
DEPLOY_SSH_HOST=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
print(e.get('deploy_ssh_host','') or e.get('ssh_host',''))
")
if [ -z "$DEPLOY_SSH_HOST" ]; then
  echo "ERROR: could not resolve deploy_ssh_host or ssh_host for $SERVER_ALIAS" >&2; exit 1
fi
echo "  deploy_ssh_host=$DEPLOY_SSH_HOST"

# MSRV-05: DNS A records target the deploy server's public IP.
# Resolution order:
#   1. coolify.json servers.$SERVER_ALIAS.deploy_vps_ip (explicit for deploy server)
#   2. GET /servers/$DEPLOY_SERVER_UUID .ip (skip if private/loopback or "host.docker.internal")
#   3. coolify.json servers.$SERVER_ALIAS.vps_ip (only meaningful when deploy_server unset — localhost case)
#   4. ssh $DEPLOY_SSH_HOST + ifconfig.me
DEPLOY_VPS_IP=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER_ALIAS',{}).get('deploy_vps_ip',''))
")
DEPLOY_VPS_IP_SOURCE="coolify.json deploy_vps_ip"
if [ -z "$DEPLOY_VPS_IP" ]; then
  DEPLOY_VPS_IP=$(coolify_curl GET "/servers/$DEPLOY_SERVER_UUID" 2>/dev/null | python3 -c "
import json,sys,ipaddress
try: ip=json.load(sys.stdin).get('ip','')
except: ip=''
# Skip 'host.docker.internal' and private IPs — they are not public DNS targets.
if ip and ip != 'host.docker.internal':
    try:
        addr = ipaddress.ip_address(ip)
        if addr.is_global:
            print(ip)
    except ValueError:
        pass
" 2>/dev/null || echo "")
  [ -n "$DEPLOY_VPS_IP" ] && DEPLOY_VPS_IP_SOURCE="Coolify API GET /servers/$DEPLOY_SERVER_UUID.ip"
fi
if [ -z "$DEPLOY_VPS_IP" ] && [ -z "${DEPLOY_SERVER:-}" ]; then
  # localhost case only: fall back to vps_ip (which describes the Coolify host)
  DEPLOY_VPS_IP=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER_ALIAS',{}).get('vps_ip',''))
")
  [ -n "$DEPLOY_VPS_IP" ] && DEPLOY_VPS_IP_SOURCE="coolify.json vps_ip (localhost fallback)"
fi
if [ -z "$DEPLOY_VPS_IP" ]; then
  DEPLOY_VPS_IP=$(ssh "$DEPLOY_SSH_HOST" "curl -s -4 ifconfig.me" 2>/dev/null | tr -d '[:space:]' || echo "")
  [ -n "$DEPLOY_VPS_IP" ] && DEPLOY_VPS_IP_SOURCE="ssh $DEPLOY_SSH_HOST ifconfig.me"
fi
if [ -z "$DEPLOY_VPS_IP" ]; then
  echo "ERROR: could not determine deploy VPS public IP. Add 'deploy_vps_ip' to coolify.json servers.$SERVER_ALIAS or check SSH connectivity to $DEPLOY_SSH_HOST." >&2
  exit 1
fi
if ! echo "$DEPLOY_VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
  echo "ERROR: deploy VPS IP resolved to '$DEPLOY_VPS_IP' which is not a valid IPv4 address" >&2
  exit 1
fi
echo "  deploy_vps_ip=$DEPLOY_VPS_IP (source: $DEPLOY_VPS_IP_SOURCE)"

# Parse dns: block and load credentials if provider is not none
DNS_ENABLED=false
DNS_ZONE_ID=""
declare -A DNS_RECORD_IDS

eval "$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$YAML_PATH'))
dns = d.get('dns', {})
provider = dns.get('provider', 'none')
if not provider or provider == 'none':
    print('dns_provider=none')
    sys.exit(0)
zone_name   = dns.get('zone_name', '')
cred_source = dns.get('credential_source', 'doppler')
cred_key    = dns.get('credential_key', '')
print(f'dns_provider={provider}')
print(f'dns_zone_name_raw={zone_name}')
print(f'dns_cred_source={cred_source}')
print(f'dns_cred_key={cred_key}')
")"

if [ "${dns_provider:-none}" != "none" ]; then
  DNS_ENABLED=true
  export DNS_PROVIDER="$dns_provider" DNS_ZONE_NAME="$dns_zone_name_raw"
  export DOPPLER_PROJECT DOPPLER_ENV="$STAGING_DOPPLER"
  dns_load_credentials "$YAML_PATH"
  DNS_ZONE_ID=$(dns_cf_get_zone_id "$DNS_ZONE_NAME")
  if [ -z "$DNS_ZONE_ID" ]; then
    echo "ERROR: DNS zone '$DNS_ZONE_NAME' not found in Cloudflare. Verify DNS_API_TOKEN has Zone:DNS:Edit scope." >&2
    exit 1
  fi
  echo "  dns_provider=$DNS_PROVIDER zone=$DNS_ZONE_NAME zone_id=$DNS_ZONE_ID"
else
  echo "provision: dns: skipped (provider: none or block absent)"
fi

# 2. Per-environment provisioning
declare -A APP_UUIDS

for ENV_NAME in staging production; do
  case "$ENV_NAME" in
    staging)    DOMAIN="$STAGING_DOMAIN"; DOPPLER_ENV="$STAGING_DOPPLER" ;;
    production) DOMAIN="$PROD_DOMAIN";    DOPPLER_ENV="$PROD_DOPPLER" ;;
  esac
  APP_NAME="${PROJECT}-${ENV_NAME}"

  # 2a. Upsert app — lookup by name first (idempotent)
  APP_UUID=$(coolify_find_app_by_name "$APP_NAME")
  if [ -z "$APP_UUID" ]; then
    BODY=$(python3 -c "
import json
d = {
  'project_uuid': '$PROJECT_UUID',
  'server_uuid': '$DEPLOY_SERVER_UUID',
  'environment_name': 'production',
  'name': '$APP_NAME',
  'docker_registry_image_name': '$REGISTRY_IMAGE_NAME',
  'docker_registry_image_tag': 'main',
  'ports_exposes': '$APP_PORT',
  'domains': 'https://$DOMAIN',
  'is_auto_deploy_enabled': False,
  'instant_deploy': False
}
if '$DEST_UUID': d['destination_uuid'] = '$DEST_UUID'
print(json.dumps(d))
")
    # Try registry-image endpoint first; fall back to dockerimage
    CREATE_RESP=$(coolify_curl POST "/applications/dockerimage" "$BODY" 2>/dev/null \
      || coolify_curl POST "/applications/private-github-app" "$BODY")
    APP_UUID=$(echo "$CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")
    [ -n "$APP_UUID" ] || { echo "ERROR: failed to create app $APP_NAME. Response: $CREATE_RESP" >&2; exit 1; }
    
    # MSRV-02 verification: confirm app landed on the intended server.
    ACTUAL_SRV=$(coolify_curl GET "/applications/$APP_UUID" 2>/dev/null | python3 -c "
    import json,sys
    try: a=json.load(sys.stdin)
    except: sys.exit(0)
    d=(a.get('destination') or {}); s=(d.get('server') or {})
    print(s.get('name','') + '|' + s.get('uuid',''))
    " 2>/dev/null || echo "|")
    ACTUAL_SRV_NAME="${ACTUAL_SRV%%|*}"
    ACTUAL_SRV_UUID="${ACTUAL_SRV##*|}"
    if [ -n "$ACTUAL_SRV_UUID" ] && [ "$ACTUAL_SRV_UUID" != "$DEPLOY_SERVER_UUID" ]; then
      echo "ERROR: app $APP_NAME landed on Coolify server '$ACTUAL_SRV_NAME' ($ACTUAL_SRV_UUID); expected '$DEPLOY_SERVER_NAME' ($DEPLOY_SERVER_UUID)." >&2
      echo "Verify Coolify destination model for server '$DEPLOY_SERVER_NAME' or set deploy_vps_ip in coolify.json." >&2
      exit 1
    fi
    echo "  CREATED $APP_NAME $APP_UUID"
  else
    echo "  EXISTS  $APP_NAME $APP_UUID"
  fi
  APP_UUIDS[$ENV_NAME]="$APP_UUID"

  # 2b. PATCH fixed app settings
  VOLUME_NAME="${APP_UUID}-doppler-cache"
  EXPECTED_MOUNT="--mount source=${VOLUME_NAME},target=/etc/doppler-cache"
  PATCH_BODY=$(python3 -c "
import json
print(json.dumps({
  'domains': 'https://$DOMAIN',
  'is_auto_deploy_enabled': False,
  'custom_docker_run_options': '$EXPECTED_MOUNT',
  'docker_registry_image_name': '$REGISTRY_IMAGE_NAME',
  'health_check_enabled': True,
  'health_check_path': '$HEALTH_CHECK_PATH',
  'health_check_port': int('$APP_PORT'),
  'health_check_interval': 30,
  'health_check_timeout': 5,
  'health_check_retries': 3
}))")
  coolify_curl PATCH "/applications/$APP_UUID" "$PATCH_BODY" >/dev/null
  echo "    PATCHED settings (fqdn=$DOMAIN, auto_deploy=off, volume_mount=$VOLUME_NAME, health_check=$HEALTH_CHECK_PATH:$APP_PORT)"

  # 2c. Create Docker volume on the server (idempotent — exits 0 if exists)
  ssh "$DEPLOY_SSH_HOST" "docker volume create $VOLUME_NAME >/dev/null" || {
    echo "ERROR: ssh $DEPLOY_SSH_HOST docker volume create failed. Verify ~/.ssh/config has alias '$DEPLOY_SSH_HOST'." >&2
    exit 1
  }
  echo "    VOLUME ready: $VOLUME_NAME on $DEPLOY_SSH_HOST"

  # 2d. Create or rotate Doppler service token for this environment
  TOKEN_NAME="coolify-${PROJECT}-${ENV_NAME}"
  # Best-effort revoke existing token of same name; ignore failures
  doppler_cmd configs tokens revoke "$TOKEN_NAME" -p "$DOPPLER_PROJECT" -c "$DOPPLER_ENV" --yes >/dev/null 2>&1 || true
  DOPPLER_SVC_TOKEN=$(doppler_create_service_token "$DOPPLER_PROJECT" "$DOPPLER_ENV" "$TOKEN_NAME")
  [ -n "$DOPPLER_SVC_TOKEN" ] || { echo "ERROR: failed to create Doppler service token for $DOPPLER_PROJECT/$DOPPLER_ENV" >&2; exit 1; }
  echo "    TOKEN created: $TOKEN_NAME (scope: $DOPPLER_PROJECT/$DOPPLER_ENV)"

  # 2e. Build env var payload: DOPPLER_TOKEN + every env_vars key from coolify.yaml
  # All values are RUNTIME — fetched from Doppler at container start via ENTRYPOINT.
  ENVS_JSON=$(python3 - "$DOPPLER_PROJECT" "$DOPPLER_ENV" "$DOPPLER_SVC_TOKEN" "$ENV_VARS" <<'PY'
import json, subprocess, sys
project, config, token, env_vars_str = sys.argv[1:5]
env_vars = env_vars_str.split() if env_vars_str else []
data = [{"key": "DOPPLER_TOKEN", "value": token, "is_preview": False}]
failures = []
for k in env_vars:
    result = subprocess.run(
        ["doppler", "secrets", "get", "--project", project, "--config", config, k, "--plain"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        failures.append((k, result.stderr.strip()))
        continue
    v = result.stdout.strip()
    data.append({"key": k, "value": v, "is_preview": False})
if failures:
    sys.stderr.write(f"ERROR: doppler secrets get failed for {len(failures)} key(s) in {project}/{config}:\n")
    for k, err in failures:
        sys.stderr.write(f"ERROR: doppler secrets get {k} failed: {err}\n")
    raise SystemExit(1)
print(json.dumps(data))
PY
)
  echo "$ENVS_JSON" | coolify_set_app_envs "$APP_UUID" >/dev/null
  KEY_COUNT=$(echo "$ENVS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  echo "    ENVS synced ($KEY_COUNT keys including DOPPLER_TOKEN)"

  # 2f. Verify volume mount round-trip — HARD FAIL if PATCH did not persist
  ACTUAL_OPTS=$(coolify_curl GET "/applications/$APP_UUID" | python3 -c "import json,sys; print(json.load(sys.stdin).get('custom_docker_run_options','') or '')")
  if ! echo "$ACTUAL_OPTS" | grep -q "$VOLUME_NAME"; then
    echo "    FAIL: custom_docker_run_options did not round-trip the volume mount." >&2
    echo "    Expected: $EXPECTED_MOUNT" >&2
    echo "    Got:      '$ACTUAL_OPTS'" >&2
    echo "    Aborting — the deploy would fail without the persistent Doppler cache volume." >&2
    exit 1
  fi
  echo "    VERIFY mount round-trip OK"

  # 2g. Upsert DNS A record for this domain (only when dns: block is configured)
  if [ "$DNS_ENABLED" = true ]; then
    ZR=$(dns_upsert_a_record "$DOMAIN" "$DEPLOY_VPS_IP")   # echoes zone_id|record_id
    DNS_RECORD_IDS[$ENV_NAME]="${ZR##*|}"
    dns_verify_a_record "$DOMAIN" "$DEPLOY_VPS_IP"           # round-trip check — hard-fail on mismatch
    echo "    DNS A $DOMAIN -> $DEPLOY_VPS_IP (record_id=${ZR##*|})"
  fi
done

# 3. Write back coolify_app_ids to coolify.yaml
python3 - "$YAML_PATH" "${APP_UUIDS[staging]}" "${APP_UUIDS[production]}" <<'PY'
import sys, yaml
path, staging_uuid, prod_uuid = sys.argv[1:4]
with open(path) as f: d = yaml.safe_load(f)
d.setdefault('coolify_app_ids', {})
d['coolify_app_ids']['staging'] = staging_uuid
d['coolify_app_ids']['production'] = prod_uuid
with open(path, 'w') as f:
    yaml.safe_dump(d, f, sort_keys=False, default_flow_style=False)
PY
echo "  WROTE back coolify_app_ids to $YAML_PATH"

echo ""
echo "DONE: ${PROJECT}-staging=${APP_UUIDS[staging]} ${PROJECT}-production=${APP_UUIDS[production]}"
