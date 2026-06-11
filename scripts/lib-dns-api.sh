#!/usr/bin/env bash
# lib-dns-api.sh — DNS provider REST API wrapper functions (Cloudflare-first).
# Source this from other scripts. Do not execute directly.
#
# Globals set by dns_load_credentials: DNS_PROVIDER, DNS_ZONE_NAME, DNS_API_TOKEN
# Cloudflare is the only provider in this release. Provider dispatch shim
# (dns_upsert_a_record, dns_delete_record) makes adding others straightforward.
#
# Credential storage options (set via coolify.yaml dns.credential_source):
#   doppler      — token fetched from Doppler staging config at call time (default)
#   coolify_json — token read from ~/.claude/coolify.json servers.<alias>.<credential_key>
#
# Prerequisites: curl, python3, pyyaml; for doppler source: doppler CLI authenticated

set -euo pipefail

: "${COOLIFY_REGISTRY:=$HOME/.claude/coolify.json}"

# ── Credential loading ─────────────────────────────────────────────────────────

_dns_resolve_coolify_json_cred() {
  # Resolve a credential key from coolify.json. Echoes "<source>|<value>" where
  # source is: alias (servers.$SERVER_ALIAS — the only non-deprecated path),
  # scan (any-alias fallback), top (legacy top-level key), or none.
  # The key is passed via argv — never interpolated into Python source.
  local cred_key="$1"
  python3 - "$COOLIFY_REGISTRY" "$cred_key" <<'PY' 2>/dev/null || echo "none|"
import json, sys, os
registry, key = sys.argv[1], sys.argv[2]
d = json.load(open(registry))
servers = d.get('servers', {})
current = os.environ.get('SERVER_ALIAS', '')
if current and current in servers:
    val = servers[current].get(key, '')
    if val:
        print(f'alias|{val}'); sys.exit(0)
for alias, srv in servers.items():
    val = srv.get(key, '')
    if val:
        print(f'scan|{val}'); sys.exit(0)
val = d.get(key, '')
print(f'top|{val}' if val else 'none|')
PY
}

_dns_warn_cred_fallback() {
  # DEPRECATED fallbacks (Fable 6.5): the any-alias scan and the top-level key
  # can silently pick up the wrong org's token in a multi-server coolify.json.
  # They keep working for now but warn loudly; a future release removes them.
  local source="$1" cred_key="$2" caller="$3"
  case "$source" in
    scan)
      echo "WARN: $caller: '$cred_key' resolved by scanning ALL server entries in coolify.json (DEPRECATED)." >&2
      echo "      In a multi-server setup this can silently use the wrong org's token." >&2
      echo "      Fix: move '$cred_key' into servers.${SERVER_ALIAS:-<your-alias>} — this fallback will be removed." >&2
      ;;
    top)
      echo "WARN: $caller: '$cred_key' resolved from the top-level of coolify.json (DEPRECATED legacy location)." >&2
      echo "      Fix: move '$cred_key' into servers.${SERVER_ALIAS:-<your-alias>} — this fallback will be removed." >&2
      ;;
  esac
}

dns_load_credentials() {
  # Parse dns: block from coolify.yaml and export DNS_PROVIDER, DNS_ZONE_NAME,
  # DNS_API_TOKEN. Hard-fails with named-field messages on any missing value.
  # For doppler source, DOPPLER_PROJECT + DOPPLER_ENV must already be set by
  # the caller (use staging config — DNS credentials are shared across envs).
  local yaml_path="$1"
  if [ ! -f "$yaml_path" ]; then
    echo "ERROR: dns_load_credentials: yaml path not found: $yaml_path" >&2; exit 1
  fi

  local dns_fields
  dns_fields=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$yaml_path'))
dns = d.get('dns', {})
provider = dns.get('provider', 'none')
if provider == 'none' or not provider:
    print('DNS_PROVIDER=none')
    sys.exit(0)
zone_name    = dns.get('zone_name', '')
cred_source  = dns.get('credential_source', 'doppler')
cred_key     = dns.get('credential_key', '')
if not zone_name:  print('ERROR: dns.zone_name is empty in $yaml_path', file=sys.stderr); sys.exit(1)
if not cred_key:   print('ERROR: dns.credential_key is empty in $yaml_path', file=sys.stderr); sys.exit(1)
print(f'DNS_PROVIDER={provider}')
print(f'DNS_ZONE_NAME={zone_name}')
print(f'DNS_CREDENTIAL_SOURCE={cred_source}')
print(f'DNS_CREDENTIAL_KEY={cred_key}')
")
  eval "$dns_fields"

  if [ "${DNS_PROVIDER:-none}" = "none" ]; then
    echo "dns_load_credentials: provider=none — skipping credential load" >&2
    return 0
  fi

  export DNS_PROVIDER DNS_ZONE_NAME

  # Resolve the actual token value from the declared source
  case "${DNS_CREDENTIAL_SOURCE:-doppler}" in
    doppler)
      if [ -z "${DOPPLER_PROJECT:-}" ]; then
        echo "ERROR: dns_load_credentials: DOPPLER_PROJECT must be set for credential_source=doppler" >&2; exit 1
      fi
      if [ -z "${DOPPLER_ENV:-}" ]; then
        echo "ERROR: dns_load_credentials: DOPPLER_ENV must be set for credential_source=doppler" >&2; exit 1
      fi
      DNS_API_TOKEN=$(doppler secrets get "$DNS_CREDENTIAL_KEY" \
        --project "$DOPPLER_PROJECT" --config "$DOPPLER_ENV" --plain 2>/dev/null || echo "")
      if [ -z "$DNS_API_TOKEN" ]; then
        echo "ERROR: dns_load_credentials: '$DNS_CREDENTIAL_KEY' not found in Doppler $DOPPLER_PROJECT/$DOPPLER_ENV" >&2
        exit 1
      fi
      ;;
    coolify_json)
      if [ ! -f "$COOLIFY_REGISTRY" ]; then
        echo "ERROR: dns_load_credentials: $COOLIFY_REGISTRY not found" >&2; exit 1
      fi
      local _resolved
      _resolved=$(_dns_resolve_coolify_json_cred "$DNS_CREDENTIAL_KEY")
      DNS_API_TOKEN="${_resolved#*|}"
      _dns_warn_cred_fallback "${_resolved%%|*}" "$DNS_CREDENTIAL_KEY" "dns_load_credentials"
      if [ -z "$DNS_API_TOKEN" ]; then
        echo "ERROR: dns_load_credentials: '$DNS_CREDENTIAL_KEY' not found in $COOLIFY_REGISTRY" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: dns_load_credentials: unknown credential_source '${DNS_CREDENTIAL_SOURCE}' (expected: doppler | coolify_json)" >&2
      exit 1
      ;;
  esac
  export DNS_API_TOKEN
}

dns_load_credentials_from_env() {
  # Load credentials from already-set shell variables (used by cleanup-deployment.sh
  # which reads provider/zone/cred from the report and cannot call dns_load_credentials).
  # Expects: DNS_PROVIDER, DNS_ZONE_NAME, DNS_CREDENTIAL_SOURCE, DNS_CREDENTIAL_KEY,
  #          DOPPLER_PROJECT (for doppler source), DOPPLER_ENV (for doppler source).
  # On success exports DNS_API_TOKEN.
  if [ "${DNS_PROVIDER:-none}" = "none" ]; then
    return 0
  fi
  case "${DNS_CREDENTIAL_SOURCE:-doppler}" in
    doppler)
      if [ -z "${DOPPLER_PROJECT:-}" ] || [ -z "${DOPPLER_ENV:-}" ]; then
        echo "ERROR: dns_load_credentials_from_env: DOPPLER_PROJECT and DOPPLER_ENV required for doppler source" >&2; exit 1
      fi
      DNS_API_TOKEN=$(doppler secrets get "${DNS_CREDENTIAL_KEY}" \
        --project "$DOPPLER_PROJECT" --config "$DOPPLER_ENV" --plain 2>/dev/null || echo "")
      if [ -z "$DNS_API_TOKEN" ]; then
        echo "ERROR: dns_load_credentials_from_env: '${DNS_CREDENTIAL_KEY}' not found in Doppler $DOPPLER_PROJECT/$DOPPLER_ENV" >&2; exit 1
      fi
      ;;
    coolify_json)
      local _resolved
      _resolved=$(_dns_resolve_coolify_json_cred "${DNS_CREDENTIAL_KEY}")
      DNS_API_TOKEN="${_resolved#*|}"
      _dns_warn_cred_fallback "${_resolved%%|*}" "${DNS_CREDENTIAL_KEY}" "dns_load_credentials_from_env"
      if [ -z "$DNS_API_TOKEN" ]; then
        echo "ERROR: dns_load_credentials_from_env: '${DNS_CREDENTIAL_KEY}' not found in $COOLIFY_REGISTRY" >&2; exit 1
      fi
      ;;
    *)
      echo "ERROR: dns_load_credentials_from_env: unknown credential_source '${DNS_CREDENTIAL_SOURCE}'" >&2; exit 1
      ;;
  esac
  export DNS_API_TOKEN
}

dns_check_credentials() {
  # Verify DNS credentials are present without exporting or mutating.
  # Returns 0 if credentials are resolvable, 1 if not.
  # Used by validate.sh (read-only check).
  local yaml_path="$1"
  if [ ! -f "$yaml_path" ]; then return 1; fi

  # shellcheck disable=SC2034  # all four assigned via eval below; declared local to avoid global leak
  local dns_provider dns_zone_name dns_cred_source dns_cred_key
  eval "$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$yaml_path'))
dns = d.get('dns', {})
provider = dns.get('provider', 'none')
if provider == 'none' or not provider:
    print('dns_provider=none')
    sys.exit(0)
zone_name    = dns.get('zone_name', '')
cred_source  = dns.get('credential_source', 'doppler')
cred_key     = dns.get('credential_key', '')
print(f'dns_provider={provider}')
print(f'dns_zone_name={zone_name}')
print(f'dns_cred_source={cred_source}')
print(f'dns_cred_key={cred_key}')
")"

  if [ "${dns_provider:-none}" = "none" ]; then return 0; fi

  case "${dns_cred_source:-doppler}" in
    doppler)
      local dp="${DOPPLER_PROJECT:-}"
      local de="${DOPPLER_ENV:-stg}"
      if [ -z "$dp" ]; then return 1; fi
      local tok
      tok=$(doppler secrets get "$dns_cred_key" \
        --project "$dp" --config "$de" --plain 2>/dev/null || echo "")
      [ -n "$tok" ]
      ;;
    coolify_json)
      [ -f "$COOLIFY_REGISTRY" ] || return 1
      local tok
      tok=$(python3 -c "
import json, sys, os
d = json.load(open('$COOLIFY_REGISTRY'))
servers = d.get('servers', {})
current = os.environ.get('SERVER_ALIAS', '')
if current and current in servers:
    val = servers[current].get('$dns_cred_key', '')
    if val: print(val); sys.exit(0)
for alias, srv in servers.items():
    val = srv.get('$dns_cred_key', '')
    if val: print(val); sys.exit(0)
print(d.get('$dns_cred_key', ''))
" 2>/dev/null || echo "")
      [ -n "$tok" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# ── Cloudflare REST wrapper ────────────────────────────────────────────────────

dns_cf_curl() {
  # Thin curl wrapper for Cloudflare API. DNS_API_TOKEN must be set.
  # --retry covers transient failures only (408/429/5xx, timeouts, refused
  # connections) — permanent 4xx errors still fail on the first attempt.
  local method="$1" path="$2" body="${3:-}"
  local url="https://api.cloudflare.com/client/v4${path}"
  if [ -n "$body" ]; then
    curl -sfS --retry 3 --retry-delay 2 --retry-connrefused -X "$method" "$url" \
      -H "Authorization: Bearer ${DNS_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sfS --retry 3 --retry-delay 2 --retry-connrefused -X "$method" "$url" \
      -H "Authorization: Bearer ${DNS_API_TOKEN}"
  fi
}

dns_cf_get_zone_id() {
  # Return the Cloudflare zone UUID for the given zone name, or empty string if not found.
  local zone_name="$1"
  dns_cf_curl GET "/zones?name=${zone_name}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
results = d.get('result', [])
if results:
    print(results[0].get('id', ''))
"
}

dns_cf_find_record() {
  # Return the record UUID matching name + type within a zone, or empty string.
  # Idempotency lookup — used before create to avoid duplicates.
  local zone_id="$1" name="$2" type="$3"
  dns_cf_curl GET "/zones/${zone_id}/dns_records?name=${name}&type=${type}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
results = d.get('result', [])
if results:
    print(results[0].get('id', ''))
"
}

dns_cf_upsert_a_record() {
  # Create or update an A record. Echoes the record_id to stdout.
  # Idempotent: looks up existing record first; PATCHes if found, POSTs if not.
  local zone_id="$1" name="$2" ip="$3"
  local existing_id
  existing_id=$(dns_cf_find_record "$zone_id" "$name" "A")

  local body
  body=$(python3 -c "
import json
print(json.dumps({'type': 'A', 'name': '$name', 'content': '$ip', 'ttl': 300, 'proxied': False}))
")

  local record_id
  if [ -n "$existing_id" ]; then
    local patch_body
    patch_body=$(python3 -c "import json; print(json.dumps({'content': '$ip'}))")
    dns_cf_curl PATCH "/zones/${zone_id}/dns_records/${existing_id}" "$patch_body" >/dev/null
    record_id="$existing_id"
  else
    record_id=$(dns_cf_curl POST "/zones/${zone_id}/dns_records" "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('result', {}).get('id', ''))
")
  fi

  if [ -z "$record_id" ]; then
    echo "ERROR: dns_cf_upsert_a_record: failed to create/update A record $name → $ip in zone $zone_id" >&2
    exit 1
  fi
  echo "$record_id"
}

dns_cf_delete_record() {
  # Delete a DNS record by zone_id + record_id. Tolerates 404 (already gone).
  local zone_id="$1" record_id="$2"
  curl -sfS --retry 3 --retry-delay 2 --retry-connrefused -X DELETE \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${DNS_API_TOKEN}" \
    -H "Content-Type: application/json" \
    >/dev/null 2>&1 || true
}

# ── Provider-dispatching wrappers ──────────────────────────────────────────────

dns_upsert_a_record() {
  # Create or update an A record for the given FQDN. Dispatches to provider.
  # Echoes "<zone_id>|<record_id>" to stdout. DNS_PROVIDER, DNS_ZONE_NAME,
  # DNS_API_TOKEN must be set (call dns_load_credentials first).
  local fqdn="$1" ip="$2"

  # Validate fqdn is under the configured zone
  local zone="${DNS_ZONE_NAME:-}"
  if [ -z "$zone" ]; then
    echo "ERROR: dns_upsert_a_record: DNS_ZONE_NAME is not set" >&2; exit 1
  fi
  if [[ "$fqdn" != *".$zone" ]] && [[ "$fqdn" != "$zone" ]]; then
    echo "ERROR: fqdn '$fqdn' is not under configured DNS zone '$zone'" >&2; exit 1
  fi

  case "${DNS_PROVIDER:-cloudflare}" in
    cloudflare)
      local zone_id
      zone_id=$(dns_cf_get_zone_id "$zone")
      if [ -z "$zone_id" ]; then
        echo "ERROR: dns_upsert_a_record: Cloudflare zone '$zone' not found (check DNS_API_TOKEN scope)" >&2; exit 1
      fi
      local record_id
      record_id=$(dns_cf_upsert_a_record "$zone_id" "$fqdn" "$ip")
      echo "${zone_id}|${record_id}"
      ;;
    *)
      echo "ERROR: dns_upsert_a_record: unsupported DNS_PROVIDER '${DNS_PROVIDER}'" >&2; exit 1
      ;;
  esac
}

dns_delete_record() {
  # Delete a DNS record. Dispatches to provider.
  # DNS_PROVIDER and DNS_API_TOKEN must be set.
  local zone_id="$1" record_id="$2"
  case "${DNS_PROVIDER:-cloudflare}" in
    cloudflare)
      dns_cf_delete_record "$zone_id" "$record_id"
      ;;
    *)
      echo "ERROR: dns_delete_record: unsupported DNS_PROVIDER '${DNS_PROVIDER}'" >&2; exit 1
      ;;
  esac
}

# ── Round-trip verification ────────────────────────────────────────────────────

dns_verify_a_record() {
  # Confirm the A record for fqdn resolves to expected_ip in the Cloudflare API.
  # Hard-fails if not — mirrors the volume mount round-trip pattern in provision.sh.
  # DNS_PROVIDER, DNS_ZONE_NAME, DNS_API_TOKEN must be set.
  local fqdn="$1" expected_ip="$2"

  case "${DNS_PROVIDER:-cloudflare}" in
    cloudflare)
      local zone_id
      zone_id=$(dns_cf_get_zone_id "${DNS_ZONE_NAME}")
      if [ -z "$zone_id" ]; then
        echo "    FAIL: dns_verify_a_record: zone '${DNS_ZONE_NAME}' not found" >&2; exit 1
      fi
      local record_id
      record_id=$(dns_cf_find_record "$zone_id" "$fqdn" "A")
      if [ -z "$record_id" ]; then
        echo "    FAIL: dns_verify_a_record: no A record found for '$fqdn' in zone '${DNS_ZONE_NAME}'" >&2; exit 1
      fi
      local actual_ip
      actual_ip=$(dns_cf_curl GET "/zones/${zone_id}/dns_records/${record_id}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('result', {}).get('content', ''))
")
      if [ "$actual_ip" != "$expected_ip" ]; then
        echo "    FAIL: dns_verify_a_record: A record '$fqdn' points to '$actual_ip' not '$expected_ip'" >&2; exit 1
      fi
      ;;
    *)
      echo "ERROR: dns_verify_a_record: unsupported DNS_PROVIDER '${DNS_PROVIDER}'" >&2; exit 1
      ;;
  esac
}
