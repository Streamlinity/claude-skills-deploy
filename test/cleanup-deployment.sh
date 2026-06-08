#!/usr/bin/env bash
# cleanup-deployment.sh — Delete Coolify/Doppler/Docker resources from an E2E test run.
#
# Usage:
#   bash test/cleanup-deployment.sh test/results/YYYYMMDDHHMMSS.json
#
# Reads all credentials and UUIDs from the report file written by test/e2e.sh.
# Operator passes nothing else — no flags, no env vars.
#
# Prerequisites:
#   ~/.claude/coolify.json   configured (server_alias from report must match)
#   doppler CLI              authenticated
#   curl, ssh, python3

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/scripts/lib-coolify-api.sh"
source "$SKILL_DIR/scripts/lib-doppler-api.sh"
source "$SKILL_DIR/scripts/lib-dns-api.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────

REPORT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; echo "Usage: bash test/cleanup-deployment.sh <report-file>" >&2; exit 1 ;;
    *)  REPORT_FILE="$1"; shift ;;
  esac
done

[ -n "$REPORT_FILE" ] || { echo "ERROR: report file path required" >&2; echo "Usage: bash test/cleanup-deployment.sh <report-file>" >&2; exit 1; }

# ── Report file validation + field extraction ──────────────────────────────────

# eval "$(python3 ...)" drops Python's exit code — capture output separately so
# errors surface immediately rather than leaving variables unbound.
_fields=$(python3 - "$REPORT_FILE" 2>&1 <<'PY'
import json, sys

report_file = sys.argv[1]
try:
    d = json.load(open(report_file))
except FileNotFoundError:
    print(f"ERROR: report file not found: {report_file}", file=sys.stderr); sys.exit(1)
except json.JSONDecodeError as e:
    print(f"ERROR: invalid JSON in report file: {e}", file=sys.stderr); sys.exit(1)

# Accept project_uuid as fallback for coolify_project_uuid (pre-phase-3 reports)
project_uuid = d.get('coolify_project_uuid') or d.get('project_uuid', '')

required = ['server_alias', 'ssh_host', 'staging_app_uuid', 'production_app_uuid', 'doppler_project']
missing = [k for k in required if not d.get(k)]
if not project_uuid:
    missing.append('coolify_project_uuid')
if missing:
    print("ERROR: report file missing fields: " + ", ".join(missing), file=sys.stderr); sys.exit(1)

print(f"SERVER_ALIAS='{d['server_alias']}'")
print(f"SSH_HOST='{d['ssh_host']}'")
print(f"COOLIFY_PROJECT_UUID='{project_uuid}'")
print(f"STAGING_APP_UUID='{d['staging_app_uuid']}'")
print(f"PRODUCTION_APP_UUID='{d['production_app_uuid']}'")
print(f"DOPPLER_PROJECT='{d['doppler_project']}'")

# DNS fields (optional — absent in pre-DNS reports; default to empty for backward compat)
dns_provider        = d.get('dns_provider', '')
dns_zone_id         = d.get('dns_zone_id', '')
dns_zone_name       = d.get('dns_zone_name', '')
dns_cred_source     = d.get('dns_credential_source', 'doppler')
dns_cred_key        = d.get('dns_credential_key', '')
dns_records         = d.get('dns_records', [])

print(f"DNS_PROVIDER_REPORT='{dns_provider}'")
print(f"DNS_ZONE_ID_REPORT='{dns_zone_id}'")
print(f"DNS_ZONE_NAME_REPORT='{dns_zone_name}'")
print(f"DNS_CREDENTIAL_SOURCE_REPORT='{dns_cred_source}'")
print(f"DNS_CREDENTIAL_KEY_REPORT='{dns_cred_key}'")

# Build a tab-separated string: <name>\t<record_id> per record
tsv_lines = []
for rec in dns_records:
    name = rec.get('name', '')
    rec_id = rec.get('record_id', '')
    if name and rec_id:
        tsv_lines.append(f"{name}\t{rec_id}")
print(f'DNS_RECORDS_TSV="{chr(30).join(tsv_lines)}"')
PY
) || { echo "$_fields" >&2; exit 1; }
eval "$_fields"

# ── Load server credentials ────────────────────────────────────────────────────

coolify_load_server "$SERVER_ALIAS"
doppler_load_account "$SERVER_ALIAS"

echo "═══════════════════════════════════"
echo " Cleanup: $DOPPLER_PROJECT"
echo "═══════════════════════════════════"
echo "  Report file:     $REPORT_FILE"
echo "  Server alias:    $SERVER_ALIAS → $COOLIFY_URL"
echo "  SSH host:        $SSH_HOST"
echo ""

# ── Deletion sequence ──────────────────────────────────────────────────────────

echo "=== Deleting DNS records ==="
if [ -z "${DNS_PROVIDER_REPORT:-}" ] || [ -z "${DNS_RECORDS_TSV:-}" ]; then
  echo "  (no DNS records in report — skipped)"
else
  # Load DNS credentials from report metadata + coolify.json/Doppler
  export DNS_PROVIDER="${DNS_PROVIDER_REPORT}"
  export DNS_ZONE_NAME="${DNS_ZONE_NAME_REPORT}"
  export DNS_CREDENTIAL_SOURCE="${DNS_CREDENTIAL_SOURCE_REPORT:-doppler}"
  export DNS_CREDENTIAL_KEY="${DNS_CREDENTIAL_KEY_REPORT}"
  export DOPPLER_PROJECT DOPPLER_ENV="stg"
  dns_load_credentials_from_env

  # DNS_RECORDS_TSV uses ASCII record separator (0x1E) between records, tab within
  IFS=$'\x1e' read -ra _dns_entries <<< "${DNS_RECORDS_TSV}"
  for _entry in "${_dns_entries[@]}"; do
    IFS=$'\t' read -r _dns_name _dns_rec_id <<< "$_entry"
    [ -z "$_dns_rec_id" ] && continue
    dns_delete_record "${DNS_ZONE_ID_REPORT}" "$_dns_rec_id" \
      && echo "  ✓ deleted DNS record $_dns_name ($_dns_rec_id)" \
      || echo "  ⚠ could not delete DNS record $_dns_name ($_dns_rec_id)"
  done
fi
echo ""

echo "=== Deleting Coolify apps ==="
coolify_curl DELETE "/applications/$STAGING_APP_UUID" >/dev/null 2>&1 \
  && echo "  ✓ deleted staging app $STAGING_APP_UUID" \
  || echo "  ⚠ could not delete staging app $STAGING_APP_UUID (may already be deleted)"

coolify_curl DELETE "/applications/$PRODUCTION_APP_UUID" >/dev/null 2>&1 \
  && echo "  ✓ deleted production app $PRODUCTION_APP_UUID" \
  || echo "  ⚠ could not delete production app $PRODUCTION_APP_UUID (may already be deleted)"

echo ""
echo "=== Deleting Coolify project ==="
# Coolify requires apps to be fully removed before the project can be deleted.
# Retry up to 3 times with a short sleep to let the API settle.
_project_deleted=false
for _attempt in 1 2 3; do
  if coolify_curl DELETE "/projects/$COOLIFY_PROJECT_UUID" >/dev/null 2>&1; then
    echo "  ✓ deleted Coolify project $COOLIFY_PROJECT_UUID"
    _project_deleted=true
    break
  fi
  [ "$_attempt" -lt 3 ] && sleep 3
done
$_project_deleted || echo "  ⚠ could not delete Coolify project $COOLIFY_PROJECT_UUID (remove manually)"

echo ""
echo "=== Removing Docker volumes via SSH ==="
for uuid in "$STAGING_APP_UUID" "$PRODUCTION_APP_UUID"; do
  [ -z "$uuid" ] && continue
  ssh "$SSH_HOST" "docker volume rm ${uuid}-doppler-cache 2>/dev/null || true" \
    && echo "  ✓ removed docker volume ${uuid}-doppler-cache" \
    || echo "  ⚠ could not remove docker volume ${uuid}-doppler-cache (ssh failed)"
done

echo ""
echo "=== Deleting Doppler project ==="
doppler projects delete "$DOPPLER_PROJECT" --yes >/dev/null 2>&1 \
  && echo "  ✓ deleted Doppler project $DOPPLER_PROJECT" \
  || echo "  ⚠ could not delete Doppler project $DOPPLER_PROJECT (remove manually at doppler.com)"

# ── Confirmation block (CLEAN-02) ──────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo " Cleanup complete"
echo "═══════════════════════════════════"
echo "  Coolify project:     $DOPPLER_PROJECT ($COOLIFY_PROJECT_UUID)"
echo "  Staging app UUID:    $STAGING_APP_UUID"
echo "  Production app UUID: $PRODUCTION_APP_UUID"
echo "  Doppler project:     $DOPPLER_PROJECT"
echo "  Server:              $SERVER_ALIAS → $COOLIFY_URL"
echo "═══════════════════════════════════"

exit 0
