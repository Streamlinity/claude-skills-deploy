#!/usr/bin/env bash
# provision.sh — Idempotent Coolify + Doppler app provisioning.
# Reads ./coolify.yaml. Uses lookup-by-name (no hardcoded UUIDs).
# Routes Doppler CLI calls via doppler_account from ~/.claude/coolify.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-coolify-api.sh"
source "$SCRIPT_DIR/lib-doppler-api.sh"
source "$SCRIPT_DIR/lib-dns-api.sh"

# Args: [coolify.yaml path] [--plan] [--rotate-tokens]
#   --plan           read-only diff: report CREATE / EXISTS / PATCH-would-change
#                    per resource, then exit without mutating anything
#   --rotate-tokens  force Doppler service token rotation even when one is wired
PLAN_MODE="${PLAN_MODE:-false}"
ROTATE_TOKENS="${ROTATE_TOKENS:-false}"
YAML_PATH=""
for _arg in "$@"; do
  case "$_arg" in
    --plan)          PLAN_MODE=true ;;
    --rotate-tokens) ROTATE_TOKENS=true ;;
    --*)             echo "ERROR: unknown flag '$_arg' (expected: --plan | --rotate-tokens)" >&2; exit 1 ;;
    *)               YAML_PATH="$_arg" ;;
  esac
done
YAML_PATH="${YAML_PATH:-./coolify.yaml}"
[ -f "$YAML_PATH" ] || { echo "ERROR: $YAML_PATH not found" >&2; exit 1; }

# Run validate.sh first — bail on any error
if ! bash "$SCRIPT_DIR/validate.sh" "$YAML_PATH"; then
  echo "ERROR: validate.sh failed; aborting before any Coolify mutation." >&2
  exit 1
fi

# A mid-run abort (e.g. transient API failure after retries are exhausted) can
# leave Coolify partially provisioned. Every operation is lookup-then-create,
# so re-running resumes safely from wherever the previous run stopped.
_abort_notice() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "ERROR: provisioning aborted (exit $rc). Coolify may be partially provisioned." >&2
    echo "Re-run /setup-coolify — provisioning is idempotent and resumes safely." >&2
  fi
}
trap _abort_notice EXIT

# Parse coolify.yaml — safe extraction via lib-config.py (shlex.quote'd output, no injection)
eval "$(python3 "$SCRIPT_DIR/lib-config.py" emit-yaml-vars "$YAML_PATH")"

coolify_load_server "$SERVER_ALIAS"
doppler_load_account "$SERVER_ALIAS"

# Environments come from the environments: map in coolify.yaml — staging and
# production are required (CI promotes staging -> production); any additional
# environments (qa, preview, ...) are provisioned identically.
mapfile -t ENV_LINES < <(python3 "$SCRIPT_DIR/lib-config.py" list-environments "$YAML_PATH")
[ "${#ENV_LINES[@]}" -ge 2 ] || { echo "ERROR: could not parse environments from $YAML_PATH" >&2; exit 1; }

echo "provision: project=$PROJECT server=$SERVER_ALIAS ($COOLIFY_URL) doppler_account=$DOPPLER_ACCOUNT"

# ── Pre-run deployment summary ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo " Provisioning plan"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Target"
echo "  ────────────────────────────────────────────────────────────────────────────"
echo "  Coolify server   : $SERVER_ALIAS → $COOLIFY_URL"
echo "  Doppler account  : $DOPPLER_ACCOUNT"
echo ""
echo "  Apps to provision"
echo "  ────────────────────────────────────────────────────────────────────────────"
for _line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r _env _domain _dopp <<< "$_line"
  printf '  %-17s: %s  →  https://%s  (Doppler: %s)\n' "$_env" "${PROJECT}-${_env}" "$_domain" "$_dopp"
done
echo "  Image            : $REGISTRY_IMAGE"
echo "  Env vars         : $ENV_VARS"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# 1. Discover Coolify topology by name — no hardcoded UUIDs.
# Plan mode is lookup-only: a missing project is reported as CREATE, never created.
PROJECT_UUID=$(coolify_get_project_uuid "$PROJECT")
if [ -z "$PROJECT_UUID" ] && [ "$PLAN_MODE" != "true" ]; then
  PROJECT_UUID=$(coolify_upsert_project "$PROJECT" "Provisioned by /setup-coolify from $YAML_PATH")
  [ -n "$PROJECT_UUID" ] || { echo "ERROR: failed to resolve project UUID for '$PROJECT'" >&2; exit 1; }
fi
echo "  project_uuid=${PROJECT_UUID:-<would create>}"

# Server name on a single-node Coolify install is conventionally "localhost", but
# is user-configurable in the Coolify UI. Read the configured name from coolify.json
# (optional field; defaults to "localhost" for backward compatibility).
SERVER_NAME=$(python3 "$SCRIPT_DIR/lib-config.py" get-json-field "$HOME/.claude/coolify.json" "$SERVER_ALIAS" server_name)
SERVER_NAME="${SERVER_NAME:-localhost}"
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
SSH_HOST=$(python3 "$SCRIPT_DIR/lib-config.py" get-json-field "$HOME/.claude/coolify.json" "$SERVER_ALIAS" ssh_host)
if [ -z "$SSH_HOST" ]; then
  echo "ERROR: 'ssh_host' field is missing from servers.$SERVER_ALIAS in ~/.claude/coolify.json." >&2
  echo "Add it manually or re-run /setup-coolify init. Example:" >&2
  echo "  \"$SERVER_ALIAS\": { ..., \"ssh_host\": \"v_cicd_stream\" }" >&2
  exit 1
fi
echo "  ssh_host=$SSH_HOST"

# MSRV-04: deploy_ssh_host overrides ssh_host for SSH ops on the deployment VPS.
DEPLOY_SSH_HOST=$(python3 "$SCRIPT_DIR/lib-config.py" get-json-field "$HOME/.claude/coolify.json" "$SERVER_ALIAS" deploy_ssh_host)
DEPLOY_SSH_HOST="${DEPLOY_SSH_HOST:-$SSH_HOST}"
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
DEPLOY_VPS_IP=$(python3 "$SCRIPT_DIR/lib-config.py" get-json-field "$HOME/.claude/coolify.json" "$SERVER_ALIAS" deploy_vps_ip)
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
  DEPLOY_VPS_IP=$(python3 "$SCRIPT_DIR/lib-config.py" get-json-field "$HOME/.claude/coolify.json" "$SERVER_ALIAS" vps_ip)
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

eval "$(python3 "$SCRIPT_DIR/lib-config.py" emit-dns-vars "$YAML_PATH")"

if [ "${dns_provider:-none}" != "none" ]; then
  DNS_ENABLED=true
  # shellcheck disable=SC2154  # dns_provider/dns_zone_name_raw assigned via eval of emit-dns-vars
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

# ── Plan mode: read-only diff against live state, then exit ─────────────────────
# Terraform-style report: CREATE / EXISTS / PATCH-would-change per resource.
# Makes re-runs on production servers reviewable before any mutation.
if [ "$PLAN_MODE" = "true" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo " Plan (read-only — nothing will be changed)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  _CREATES=0; _CHANGES=0; _UNCHANGED=0

  if [ -z "$PROJECT_UUID" ]; then
    echo "  + CREATE  project $PROJECT"
    _CREATES=$((_CREATES+1))
  else
    echo "  = EXISTS  project $PROJECT ($PROJECT_UUID)"
    _UNCHANGED=$((_UNCHANGED+1))
  fi

  for _env_line in "${ENV_LINES[@]}"; do
    IFS=$'\t' read -r ENV_NAME DOMAIN DOPPLER_ENV <<< "$_env_line"
    APP_NAME="${PROJECT}-${ENV_NAME}"
    APP_UUID=$(coolify_find_app_by_name "$APP_NAME")

    if [ -z "$APP_UUID" ]; then
      echo "  + CREATE  app $APP_NAME (image=$REGISTRY_IMAGE_NAME domain=https://$DOMAIN)"
      echo "  + CREATE    volume <uuid>-doppler-cache on $DEPLOY_SSH_HOST"
      echo "  + CREATE    Doppler service token coolify-${PROJECT}-${ENV_NAME} ($DOPPLER_PROJECT/$DOPPLER_ENV)"
      [ "$DNS_ENABLED" = true ] && echo "  + CREATE    DNS A $DOMAIN -> $DEPLOY_VPS_IP"
      _CREATES=$((_CREATES+1))
      continue
    fi

    # App exists — diff desired settings against live state (single GET)
    VOLUME_NAME="${APP_UUID}-doppler-cache"
    _drift=$(coolify_curl GET "/applications/$APP_UUID" \
      | _CSD_DOMAIN="https://$DOMAIN" _CSD_MOUNT="$VOLUME_NAME" \
        _CSD_IMG="$REGISTRY_IMAGE_NAME" _CSD_HC="$HEALTH_CHECK_PATH" python3 -c "
import json, sys, os
a = json.load(sys.stdin)
drift = []
# Coolify returns the configured domain as 'fqdn' on GET; 'domains' is the PATCH field.
live_domain = a.get('fqdn') or a.get('domains') or ''
if live_domain != os.environ['_CSD_DOMAIN']:
    drift.append(f\"domains: {live_domain!r} -> {os.environ['_CSD_DOMAIN']!r}\")
if os.environ['_CSD_MOUNT'] not in (a.get('custom_docker_run_options') or ''):
    drift.append('custom_docker_run_options: doppler-cache volume mount missing')
if a.get('docker_registry_image_name', '') != os.environ['_CSD_IMG']:
    drift.append(f\"image: {a.get('docker_registry_image_name','')!r} -> {os.environ['_CSD_IMG']!r}\")
if a.get('health_check_path', '') != os.environ['_CSD_HC']:
    drift.append(f\"health_check_path: {a.get('health_check_path','')!r} -> {os.environ['_CSD_HC']!r}\")
print('\n'.join(drift))
")
    if [ -n "$_drift" ]; then
      echo "  ~ PATCH   app $APP_NAME ($APP_UUID):"
      while IFS= read -r _d; do echo "              $_d"; done <<< "$_drift"
      _CHANGES=$((_CHANGES+1))
    else
      echo "  = EXISTS  app $APP_NAME ($APP_UUID) — settings match"
      _UNCHANGED=$((_UNCHANGED+1))
    fi

    # Volume (read-only inspect; ssh -n prevents stdin slurp inside loops)
    if ssh -n "$DEPLOY_SSH_HOST" "docker volume inspect $VOLUME_NAME >/dev/null 2>&1"; then
      echo "  = EXISTS    volume $VOLUME_NAME"
      _UNCHANGED=$((_UNCHANGED+1))
    else
      echo "  + CREATE    volume $VOLUME_NAME on $DEPLOY_SSH_HOST"
      _CREATES=$((_CREATES+1))
    fi

    # DOPPLER_TOKEN wiring
    # Key presence only — Coolify redacts env values (value: null) in GET responses.
    _token_wired=$(coolify_curl GET "/applications/$APP_UUID/envs" 2>/dev/null | python3 -c "
import json, sys
try:
    envs = json.load(sys.stdin)
    items = envs if isinstance(envs, list) else envs.get('data', [])
    print('yes' if any(e.get('key') == 'DOPPLER_TOKEN' for e in items) else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
    if [ "$_token_wired" = "yes" ]; then
      if [ "$ROTATE_TOKENS" = "true" ]; then
        echo "  ~ ROTATE    Doppler token coolify-${PROJECT}-${ENV_NAME} (--rotate-tokens)"
        _CHANGES=$((_CHANGES+1))
      else
        echo "  = EXISTS    DOPPLER_TOKEN wired (kept — pass --rotate-tokens to rotate)"
        _UNCHANGED=$((_UNCHANGED+1))
      fi
    else
      echo "  + CREATE    Doppler service token coolify-${PROJECT}-${ENV_NAME} ($DOPPLER_PROJECT/$DOPPLER_ENV)"
      _CREATES=$((_CREATES+1))
    fi

    # DNS record
    if [ "$DNS_ENABLED" = true ]; then
      _rid=$(dns_cf_find_record "$DNS_ZONE_ID" "$DOMAIN" "A" || echo "")
      if [ -z "$_rid" ]; then
        echo "  + CREATE    DNS A $DOMAIN -> $DEPLOY_VPS_IP"
        _CREATES=$((_CREATES+1))
      else
        _cur_ip=$(dns_cf_curl GET "/zones/${DNS_ZONE_ID}/dns_records/${_rid}" 2>/dev/null | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('result', {}).get('content', ''))
except Exception: print('')
" 2>/dev/null || echo "")
        if [ "$_cur_ip" = "$DEPLOY_VPS_IP" ]; then
          echo "  = EXISTS    DNS A $DOMAIN -> $DEPLOY_VPS_IP"
          _UNCHANGED=$((_UNCHANGED+1))
        else
          echo "  ~ UPDATE    DNS A $DOMAIN: $_cur_ip -> $DEPLOY_VPS_IP"
          _CHANGES=$((_CHANGES+1))
        fi
      fi
    fi
  done

  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo " Plan summary: $_CREATES to create, $_CHANGES to change, $_UNCHANGED unchanged"
  echo " No changes were made. Run /setup-coolify (without --plan) to apply."
  echo "═══════════════════════════════════════════════════════════════════════════════"
  exit 0
fi

# 2. Per-environment provisioning — iterates the environments: map from
# coolify.yaml (staging + production required; extra envs provisioned identically)
declare -A APP_UUIDS

for _env_line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r ENV_NAME DOMAIN DOPPLER_ENV <<< "$_env_line"
  APP_NAME="${PROJECT}-${ENV_NAME}"

  # 2a. Upsert app — lookup by name first (idempotent)
  APP_UUID=$(coolify_find_app_by_name "$APP_NAME")
  if [ -z "$APP_UUID" ]; then
    BODY=$(python3 - "$PROJECT_UUID" "$DEPLOY_SERVER_UUID" "$APP_NAME" \
        "$REGISTRY_IMAGE_NAME" "$REGISTRY_IMAGE_TAG" "$APP_PORT" "https://$DOMAIN" "${DEST_UUID:-}" <<'PY'
import json, sys
project_uuid, server_uuid, name, img, tag, port, domain, dest_uuid = sys.argv[1:9]
d = {
  'project_uuid': project_uuid,
  'server_uuid': server_uuid,
  'environment_name': 'production',
  'name': name,
  'docker_registry_image_name': img,
  # Initial tag — CI will PATCH this to the SHA tag before the first deploy.
  # 'latest' is used as a safe placeholder; provision does NOT trigger a deploy.
  'docker_registry_image_tag': tag or 'latest',
  'ports_exposes': port,
  'domains': domain,
  'is_auto_deploy_enabled': False,
  'instant_deploy': False
}
if dest_uuid:
  d['destination_uuid'] = dest_uuid
print(json.dumps(d))
PY
)
    CREATE_RESP=$(coolify_curl POST "/applications/dockerimage" "$BODY")
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
  PATCH_BODY=$(python3 - "https://$DOMAIN" "$EXPECTED_MOUNT" "$REGISTRY_IMAGE_NAME" \
      "$HEALTH_CHECK_PATH" "$APP_PORT" <<'PY'
import json, sys
domain, mount, img, hc_path, hc_port = sys.argv[1:6]
print(json.dumps({
  'domains': domain,
  'is_auto_deploy_enabled': False,
  'custom_docker_run_options': mount,
  'docker_registry_image_name': img,
  'health_check_enabled': True,
  'health_check_path': hc_path,
  'health_check_port': int(hc_port),
  'health_check_interval': 30,
  'health_check_timeout': 5,
  'health_check_retries': 3
}))
PY
)
  coolify_curl PATCH "/applications/$APP_UUID" "$PATCH_BODY" >/dev/null
  echo "    PATCHED settings (fqdn=$DOMAIN, auto_deploy=off, volume_mount=$VOLUME_NAME, health_check=$HEALTH_CHECK_PATH:$APP_PORT)"

  # 2c. Create Docker volume on the server (idempotent — exits 0 if exists)
  ssh "$DEPLOY_SSH_HOST" "docker volume create $VOLUME_NAME >/dev/null" || {
    echo "ERROR: ssh $DEPLOY_SSH_HOST docker volume create failed. Verify ~/.ssh/config has alias '$DEPLOY_SSH_HOST'." >&2
    exit 1
  }
  echo "    VOLUME ready: $VOLUME_NAME on $DEPLOY_SSH_HOST"

  # 2d. Create Doppler service token — skip rotation when token already wired on a
  # running app (rotation would revoke the token the live container uses until its
  # next redeploy, causing secret-fetch failures on restart). Pass --rotate-tokens
  # to force rotation (e.g. after a credential compromise).
  TOKEN_NAME="coolify-${PROJECT}-${ENV_NAME}"
  # Key presence only — Coolify redacts env values (value: null) in GET responses,
  # so checking e.get('value') would never match and tokens would rotate every run.
  _existing_token=$(coolify_curl GET "/applications/$APP_UUID/envs" 2>/dev/null \
    | python3 -c "
import json,sys
try:
  envs=json.load(sys.stdin)
  items=envs if isinstance(envs,list) else envs.get('data',[])
  for e in items:
    if e.get('key')=='DOPPLER_TOKEN':
      print('yes'); break
except: pass
" 2>/dev/null || echo "")

  if [ "${ROTATE_TOKENS:-false}" != "true" ] && [ "$_existing_token" = "yes" ]; then
    echo "    TOKEN exists: $TOKEN_NAME — skipping rotation (pass --rotate-tokens to force)"
  else
    doppler_cmd configs tokens revoke "$TOKEN_NAME" -p "$DOPPLER_PROJECT" -c "$DOPPLER_ENV" --yes >/dev/null 2>&1 || true
    DOPPLER_SVC_TOKEN=$(doppler_create_service_token "$DOPPLER_PROJECT" "$DOPPLER_ENV" "$TOKEN_NAME")
    [ -n "$DOPPLER_SVC_TOKEN" ] || { echo "ERROR: failed to create Doppler service token for $DOPPLER_PROJECT/$DOPPLER_ENV" >&2; exit 1; }
    echo "    TOKEN created: $TOKEN_NAME (scope: $DOPPLER_PROJECT/$DOPPLER_ENV)"

    # 2e. Set DOPPLER_TOKEN on the Coolify app — the ONLY env var Coolify needs.
    ENVS_JSON=$(python3 - "$DOPPLER_SVC_TOKEN" <<'PY'
import json, sys
print(json.dumps([{'key': 'DOPPLER_TOKEN', 'value': sys.argv[1], 'is_preview': False}]))
PY
)
    echo "$ENVS_JSON" | coolify_set_app_envs "$APP_UUID" >/dev/null
    echo "    ENVS synced (DOPPLER_TOKEN only — all other secrets fetched from Doppler at container start)"
  fi

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

# 3. Write back coolify_app_ids to coolify.yaml — targeted block edit preserves
# comments outside the block. yaml.safe_dump would strip every # CHANGE:/# LEAVE:
# guide comment on the first run. The block itself is rebuilt from the provisioned
# environment map, so extra environments (qa, preview, ...) get lines appended.
_WRITEBACK_ARGS=()
for _env_line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r _env _ _ <<< "$_env_line"
  _WRITEBACK_ARGS+=("$_env" "${APP_UUIDS[$_env]}")
done
python3 - "$YAML_PATH" "${_WRITEBACK_ARGS[@]}" <<'PY'
import sys, re
path = sys.argv[1]
args = sys.argv[2:]
pairs = list(zip(args[0::2], args[1::2]))
with open(path) as f:
    content = f.read()
block = 'coolify_app_ids:\n' + ''.join(f'  {env}: {uuid}\n' for env, uuid in pairs)
pattern = r'(?m)^coolify_app_ids:[ \t]*\n(?:[ \t]+\S[^\n]*\n?)*'
if re.search(pattern, content):
    content = re.sub(pattern, block, content, count=1)
else:
    if not content.endswith('\n'):
        content += '\n'
    content += block
with open(path, 'w') as f:
    f.write(content)
PY
echo "  WROTE back coolify_app_ids to $YAML_PATH"

# 4. Regenerate deploy.yml now that real UUIDs are available
bash "$SCRIPT_DIR/generate-workflow.sh" "$YAML_PATH"
echo "  REGENERATED .github/workflows/deploy.yml with provisioned app UUIDs"

echo ""
_done_line="DONE:"
for _env_line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r _env _ _ <<< "$_env_line"
  _done_line+=" ${PROJECT}-${_env}=${APP_UUIDS[$_env]}"
done
echo "$_done_line"

# ── Completion summary ─────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo " Provisioning complete"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Target"
echo "  ────────────────────────────────────────────────────────────────────────────"
echo "  Coolify server   : $SERVER_ALIAS → $COOLIFY_URL"
echo "  Deploy server    : $DEPLOY_SERVER_NAME  (uuid: $DEPLOY_SERVER_UUID)"
echo "  Doppler account  : $DOPPLER_ACCOUNT"
echo "  SSH host         : $SSH_HOST"
echo ""
echo "  Apps"
echo "  ────────────────────────────────────────────────────────────────────────────"
for _env_line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r _env _ _ <<< "$_env_line"
  printf '  %-17s: %s  (uuid: %s)\n' "$_env" "${PROJECT}-${_env}" "${APP_UUIDS[$_env]}"
done
echo "  Image            : $REGISTRY_IMAGE"
echo ""
echo "  Domains"
echo "  ────────────────────────────────────────────────────────────────────────────"
for _env_line in "${ENV_LINES[@]}"; do
  IFS=$'\t' read -r _env _domain _ <<< "$_env_line"
  printf '  %-11s: https://%s\n' "$_env" "$_domain"
done
if [ "$DNS_ENABLED" = true ]; then
  echo ""
  echo "  DNS records created"
  echo "  ────────────────────────────────────────────────────────────────────────────"
  echo "  Provider   : $DNS_PROVIDER  (zone: $DNS_ZONE_NAME)"
  for _env_line in "${ENV_LINES[@]}"; do
    IFS=$'\t' read -r _env _domain _ <<< "$_env_line"
    echo "  A  $_domain → $DEPLOY_VPS_IP  (record_id: ${DNS_RECORD_IDS[$_env]:-n/a})"
  done
else
  echo ""
  echo "  DNS records  : skipped (dns: block not configured or provider: none)"
fi
echo ""
echo "  Next steps (one-time per repo)"
echo "  ────────────────────────────────────────────────────────────────────────────"
echo "  1. Set the GitHub Actions secret (if not already set):"
echo "     gh secret set COOLIFY_API_KEY --body \"<your-coolify-api-key>\" --repo <owner/repo>"
echo "  2. Commit and push:"
echo "     git add coolify.yaml .github/workflows/deploy.yml && git push"
echo "═══════════════════════════════════════════════════════════════════════════════"
