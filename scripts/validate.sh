#!/usr/bin/env bash
# validate.sh — Dry-run validation for /setup-coolify.
# Reads ./coolify.yaml. Exits 0 only when:
#   1. coolify.yaml parses and required fields are present
#   2. ~/.claude/coolify.json has the server alias referenced by coolify.yaml
#   3. Every env_vars key exists in Doppler staging AND production (non-empty, non-placeholder)
#   4. Coolify API reachable: GET /projects returns 200
# On failure: prints MISSING/INVALID lines and exits 1. No Coolify mutations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-coolify-api.sh"
source "$SCRIPT_DIR/lib-doppler-api.sh"
source "$SCRIPT_DIR/lib-dns-api.sh"

YAML_PATH="${1:-./coolify.yaml}"

if [ ! -f "$YAML_PATH" ]; then
  echo "ERROR: $YAML_PATH not found" >&2
  exit 1
fi

# Parse coolify.yaml fields into shell vars
eval "$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$YAML_PATH'))
print(f\"PROJECT='{d.get('project','')}'\")
print(f\"DEPLOY_SERVER='{d.get('deploy_server','')}'\")
print(f\"SERVER='{d.get('server','')}'\")
print(f\"DOPPLER_PROJECT='{d.get('doppler_project','')}'\")
print(f\"REGISTRY_IMAGE='{d.get('registry',{}).get('image','')}'\")
print(f\"STAGING_DOMAIN='{d.get('environments',{}).get('staging',{}).get('domain','')}'\")
print(f\"STAGING_DOPPLER='{d.get('environments',{}).get('staging',{}).get('doppler_environment','')}'\")
print(f\"PROD_DOMAIN='{d.get('environments',{}).get('production',{}).get('domain','')}'\")
print(f\"PROD_DOPPLER='{d.get('environments',{}).get('production',{}).get('doppler_environment','')}'\")
print(f\"ENV_VARS='{' '.join(d.get('env_vars',[]))}'\")
")"

ERRORS=0
fail() { echo "FAIL: $*" >&2; ERRORS=$((ERRORS+1)); }

[ -n "$PROJECT" ] || fail "INVALID:coolify.yaml:project (empty)"
[ -n "$SERVER" ] || fail "INVALID:coolify.yaml:server (empty)"
[ -n "$DOPPLER_PROJECT" ] || fail "INVALID:coolify.yaml:doppler_project (empty)"
[ -n "$REGISTRY_IMAGE" ] || fail "INVALID:coolify.yaml:registry.image (empty)"
[ -n "$STAGING_DOMAIN" ] || fail "INVALID:coolify.yaml:environments.staging.domain"
[ -n "$PROD_DOMAIN" ] || fail "INVALID:coolify.yaml:environments.production.domain"
[ -n "$ENV_VARS" ] || fail "INVALID:coolify.yaml:env_vars (empty list)"

if [ "$ERRORS" -gt 0 ]; then
  echo "" >&2
  echo "Stop: coolify.yaml schema errors above. Fix and re-run." >&2
  exit 1
fi

# Verify the server alias exists in coolify.json
if ! coolify_load_server "$SERVER"; then
  fail "INVALID:coolify.json:server alias '$SERVER' not found"
  echo "" >&2; echo "Run /setup-coolify init to add it." >&2
  exit 1
fi
doppler_load_account "$SERVER"

# Verify ssh_host is set in the coolify.json server entry (required by provision.sh)
SSH_HOST_CHECK=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER',{}).get('ssh_host',''))
")
if [ -z "$SSH_HOST_CHECK" ]; then
  fail "INVALID:coolify.json:servers.$SERVER.ssh_host (missing — required by provision.sh)"
  echo "" >&2
  echo "Add ssh_host to ~/.claude/coolify.json. Example:" >&2
  echo "  \"$SERVER\": { ..., \"ssh_host\": \"v_cicd_stream\" }" >&2
  exit 1
fi

echo "validate: server alias '$SERVER' -> $COOLIFY_URL (doppler account: $DOPPLER_ACCOUNT, ssh_host: $SSH_HOST_CHECK)"

# Verify Coolify API reachable
if ! coolify_curl GET "/projects" >/dev/null 2>&1; then
  fail "INVALID:coolify:api unreachable at $COOLIFY_URL (check api_key, HTTPS, allowed_ips)"
  exit 1
fi
echo "validate: Coolify API reachable"

# MSRV-03: when deploy_server is set in coolify.yaml, verify it exists in Coolify.
if [ -n "${DEPLOY_SERVER:-}" ]; then
  DEPLOY_SRV_UUID=$(coolify_get_server_uuid "$DEPLOY_SERVER")
  if [ -z "$DEPLOY_SRV_UUID" ]; then
    AVAILABLE=$(coolify_curl GET "/servers" 2>/dev/null | python3 -c "
import json,sys
try: srvs=json.load(sys.stdin)
except: sys.exit(0)
print(', '.join(s.get('name','') for s in srvs if s.get('name')))
" 2>/dev/null || echo "<unable to list>")
    fail "INVALID:coolify.yaml:deploy_server '$DEPLOY_SERVER' not registered in Coolify (available: $AVAILABLE)"
  else
    echo "validate: deploy_server '$DEPLOY_SERVER' -> uuid=$DEPLOY_SRV_UUID OK"
  fi
fi

# P04 gap: when deploy_server is absent, verify the effective Coolify server ("localhost" or
# server_name from coolify.json) is registered — provision.sh hard-fails if it is missing.
if [ -z "${DEPLOY_SERVER:-}" ]; then
  EFFECTIVE_SERVER=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER',{}).get('server_name','localhost'))
")
  EFFECTIVE_UUID=$(coolify_get_server_uuid "$EFFECTIVE_SERVER")
  if [ -z "$EFFECTIVE_UUID" ]; then
    AVAILABLE=$(coolify_curl GET "/servers" 2>/dev/null | python3 -c "
import json,sys
try: srvs=json.load(sys.stdin)
except: sys.exit(0)
print(', '.join(s.get('name','') for s in srvs if s.get('name')))
" 2>/dev/null || echo "<unable to list>")
    fail "INVALID:coolify.json:server_name '$EFFECTIVE_SERVER' not found in Coolify (available: $AVAILABLE) — set server_name in coolify.json servers.$SERVER or register the server in Coolify"
  else
    echo "validate: effective Coolify server '$EFFECTIVE_SERVER' -> uuid=$EFFECTIVE_UUID OK"
  fi
fi

# MSRV-07: deploy_server and deploy_ssh_host must be specified together or skipped together.
DEPLOY_SSH_HOST_CHECK=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER',{}).get('deploy_ssh_host',''))
")
if [ -n "${DEPLOY_SERVER:-}" ] && [ -z "$DEPLOY_SSH_HOST_CHECK" ]; then
  fail "INVALID:coolify.json:servers.$SERVER.deploy_ssh_host (missing — required when deploy_server is set)"
  echo "" >&2
  echo "deploy_server '$DEPLOY_SERVER' deploys apps to a separate server." >&2
  echo "provision.sh needs deploy_ssh_host for Docker volume creation and DNS IP resolution." >&2
  echo "Add it to ~/.claude/coolify.json servers.$SERVER. Example:" >&2
  echo "  \"$SERVER\": { ..., \"deploy_ssh_host\": \"my-app-vps\" }" >&2
  exit 1
fi
if [ -z "${DEPLOY_SERVER:-}" ] && [ -n "$DEPLOY_SSH_HOST_CHECK" ]; then
  fail "INVALID:coolify.json:servers.$SERVER.deploy_ssh_host (present but deploy_server is absent in coolify.yaml)"
  echo "" >&2
  echo "deploy_ssh_host is only used when deploy_server is set. Either:" >&2
  echo "  • Set deploy_server in coolify.yaml to deploy to a separate server, OR" >&2
  echo "  • Remove deploy_ssh_host from ~/.claude/coolify.json servers.$SERVER." >&2
  exit 1
fi
if [ -n "${DEPLOY_SERVER:-}" ] && [ -n "$DEPLOY_SSH_HOST_CHECK" ]; then
  echo "validate: deploy_server + deploy_ssh_host coupling OK"
fi

# P07/P08 gap: validate deploy_vps_ip from coolify.json if statically configured.
# provision.sh hard-fails (P07) when it cannot resolve the VPS IP after all 4 steps;
# it also hard-fails (P08) when the resolved value is not a valid IPv4 address.
DEPLOY_VPS_IP_CHECK=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER',{}).get('deploy_vps_ip',''))
")
if [ -n "$DEPLOY_VPS_IP_CHECK" ]; then
  if ! python3 -c "
import re,sys
ip=sys.argv[1]
oct_re=r'(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
if not re.fullmatch(rf'{oct_re}\.{oct_re}\.{oct_re}\.{oct_re}',ip):
    sys.exit(1)
" "$DEPLOY_VPS_IP_CHECK" 2>/dev/null; then
    fail "INVALID:coolify.json:servers.$SERVER.deploy_vps_ip '$DEPLOY_VPS_IP_CHECK' is not a valid IPv4 address"
  else
    echo "validate: deploy_vps_ip $DEPLOY_VPS_IP_CHECK (static) — format OK"
  fi
else
  echo "validate: deploy_vps_ip not static — will be resolved at provision time"
fi

# P12 gap: probe SSH connectivity to the effective deploy host before any Coolify mutations.
# provision.sh calls ssh to create Docker volumes and may resolve IPs via SSH; an unreachable
# host causes a mid-run abort that leaves Coolify in a partially-provisioned state.
EFFECTIVE_SSH_HOST="${DEPLOY_SSH_HOST_CHECK:-$SSH_HOST_CHECK}"
if [ -n "$EFFECTIVE_SSH_HOST" ]; then
  if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
       "$EFFECTIVE_SSH_HOST" true 2>/dev/null; then
    fail "INVALID:ssh:$EFFECTIVE_SSH_HOST unreachable or authentication failed (check ~/.ssh/config, keys, and server firewall)"
  else
    echo "validate: SSH probe to '$EFFECTIVE_SSH_HOST' OK"
  fi
fi

# Verify every env_vars key exists in BOTH staging and production with non-placeholder values
for ENV in "$STAGING_DOPPLER" "$PROD_DOPPLER"; do
  for KEY in $ENV_VARS; do
    # Strip trailing comment-encoded build_time annotation if any survived (defensive)
    KEY="${KEY%%#*}"
    KEY="${KEY// /}"
    [ -z "$KEY" ] && continue
    if ! doppler_check_key "$DOPPLER_PROJECT" "$ENV" "$KEY"; then
      RC=$?
      if [ "$RC" = "2" ]; then
        fail "MISSING:$KEY:$ENV (present but value is TODO_REPLACE_BEFORE_DEPLOY)"
      else
        fail "MISSING:$KEY:$ENV (key absent in Doppler)"
      fi
    fi
  done
done

if [ "$ERRORS" -gt 0 ]; then
  echo "" >&2
  echo "Stop: $ERRORS Doppler key error(s) above. Fix in Doppler dashboard or via:" >&2
  echo "  doppler --account $DOPPLER_ACCOUNT secrets set --project $DOPPLER_PROJECT --config <env> KEY=VALUE" >&2
  exit 1
fi

# Validate DNS block (if present and not provider: none)
DNS_VALIDATION=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$YAML_PATH'))
dns = d.get('dns', {})
provider = dns.get('provider', 'none')
if not provider or provider == 'none':
    print('skip')
    sys.exit(0)
zone_name    = dns.get('zone_name', '')
cred_source  = dns.get('credential_source', 'doppler')
cred_key     = dns.get('credential_key', '')
staging_dom  = d.get('environments',{}).get('staging',{}).get('domain','')
prod_dom     = d.get('environments',{}).get('production',{}).get('domain','')
print(f'provider={provider}')
print(f'zone_name={zone_name}')
print(f'cred_source={cred_source}')
print(f'cred_key={cred_key}')
print(f'staging_domain={staging_dom}')
print(f'prod_domain={prod_dom}')
")

if [ "$DNS_VALIDATION" = "skip" ]; then
  echo "validate: dns: skipped (provider: none or block absent)"
else
  eval "$DNS_VALIDATION"

  if [ -z "${zone_name:-}" ]; then
    fail "INVALID:coolify.yaml:dns.zone_name (empty — required when dns.provider is not none)"
  fi
  if [ -z "${cred_key:-}" ]; then
    fail "INVALID:coolify.yaml:dns.credential_key (empty — required when dns.provider is not none)"
  fi

  # Zone must be a suffix of both domains
  if [ -n "${zone_name:-}" ] && [ -n "${staging_domain:-}" ]; then
    if [[ "$staging_domain" != *".$zone_name" ]] && [[ "$staging_domain" != "$zone_name" ]]; then
      fail "INVALID:coolify.yaml:dns.zone_name '$zone_name' is not a suffix of staging domain '$staging_domain'"
    fi
  fi
  if [ -n "${zone_name:-}" ] && [ -n "${prod_domain:-}" ]; then
    if [[ "$prod_domain" != *".$zone_name" ]] && [[ "$prod_domain" != "$zone_name" ]]; then
      fail "INVALID:coolify.yaml:dns.zone_name '$zone_name' is not a suffix of production domain '$prod_domain'"
    fi
  fi

  # Check credential is reachable (no mutations)
  export DOPPLER_PROJECT DOPPLER_ENV="${STAGING_DOPPLER:-stg}"
  if ! dns_check_credentials "$YAML_PATH"; then
    fail "MISSING:DNS_CREDENTIAL:${cred_key:-<credential_key>} (not found in ${cred_source:-doppler})"
  else
    echo "validate: dns: provider=$provider zone=$zone_name credential=$cred_key (source: ${cred_source:-doppler}) — OK"
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "" >&2
  echo "Stop: $ERRORS error(s) above. Fix and re-run." >&2
  exit 1
fi

echo "OK: All keys present in $DOPPLER_PROJECT/$STAGING_DOPPLER and $DOPPLER_PROJECT/$PROD_DOPPLER"
echo "OK: $COOLIFY_URL API reachable"
echo "OK: ready to provision (run /setup-coolify without arguments)"
exit 0
