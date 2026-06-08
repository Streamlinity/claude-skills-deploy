#!/usr/bin/env bash
# e2e.sh — End-to-end integration test for claude-skills-deploy.
#
# Creates a throwaway Coolify project + Doppler project, provisions staging +
# production apps, triggers staging + production deploys, smoke-tests the live
# staging URL. On success leaves everything running (DNS, apps, Doppler) so the
# operator can inspect the live deployment; run cleanup-deployment.sh when done.
# On failure cleans up all resources (DNS, Coolify apps, Doppler, Docker volumes).
# Before starting, sweeps for stale csd-hello-test-* resources from prior runs and
# removes them so each test starts from a clean slate.
#
# Usage:
#   bash test/e2e.sh --server hetzner-strategem       # test against a specific server
#   bash test/e2e.sh --keep                           # skip cleanup (debug failures)
#   E2E_SERVER=my-server bash test/e2e.sh             # REQUIRED — alias from ~/.claude/coolify.json
#   E2E_BASE_DOMAIN=ci.example.com bash test/e2e.sh   # REQUIRED — base domain for test URLs
#   E2E_IMAGE=ghcr.io/my-org/my-hello:latest bash test/e2e.sh
#
# Prerequisites:
#   ~/.claude/coolify.json  configured with a server alias (ssh_host required)
#   doppler CLI             authenticated (doppler whoami)
#   python3 + pyyaml        (pip3 install pyyaml)
#   curl, ssh
#
# The test image (nginx:alpine on port 3000 with /api/health) must be pushed to
# GHCR before the first run:
#   bash test/push-hello-world.sh

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/scripts/lib-coolify-api.sh"
source "$SKILL_DIR/scripts/lib-doppler-api.sh"
source "$SKILL_DIR/scripts/lib-dns-api.sh"

# ── Configuration ──────────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d%H%M%S)
TEST_PROJECT="csd-hello-test-$(date +%Y%m%d-%H%M%S)"
KEEP_ON_EXIT=false
# E2E_SERVER:      Required. Coolify server alias key from ~/.claude/coolify.json
#                  (an alias, NOT a raw hostname). The alias maps to the Coolify
#                  instance URL, API key, Doppler account, and SSH host.
# E2E_BASE_DOMAIN: Required. Base domain under which test app URLs are
#                  constructed (e.g. ci.example.com → <project>-staging.ci.example.com).
E2E_SERVER="${E2E_SERVER:-}"
E2E_BASE_DOMAIN="${E2E_BASE_DOMAIN:-}"
SERVER_ALIAS=""
# E2E_IMAGE: Docker image to deploy as the test fixture.
#            Default: ghcr.io/streamlinity/csd-hello-world:latest — a public,
#            domain-neutral image published by the repo maintainer (Streamlinity).
#            It serves HTTP 200 on /api/health and a known sentinel string
#            ("claude-skills-deploy-e2e-ok") on /, which is what the smoke test
#            in Step 9 looks for.
#            To use your own test image, see test/hello-world/ for the source
#            and test/push-hello-world.sh for the build+push helper. Your image
#            must listen on port 3000, serve /api/health → 200, and be pullable
#            by the Coolify VPS (public or pre-authenticated in the Coolify UI).
E2E_IMAGE="${E2E_IMAGE:-ghcr.io/streamlinity/csd-hello-world:latest}"
DEPLOY_TIMEOUT=180    # seconds to wait for Coolify deploy to finish
SMOKE_TIMEOUT=120     # seconds to wait for HTTPS smoke test (cert issuance takes ~30-60s)

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_ALIAS="$2"; shift 2 ;;
    --keep)   KEEP_ON_EXIT=true; shift ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: bash test/e2e.sh [--server ALIAS] [--keep]" >&2; exit 1 ;;
  esac
done

# ── Required env vars (no maintainer-specific defaults) ────────────────────────
MISSING_VARS=()
if [ -z "$SERVER_ALIAS" ] && [ -z "$E2E_SERVER" ]; then
  MISSING_VARS+=(E2E_SERVER)
fi
if [ -z "$E2E_BASE_DOMAIN" ]; then
  MISSING_VARS+=(E2E_BASE_DOMAIN)
fi
if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  for v in "${MISSING_VARS[@]}"; do
    case "$v" in
      E2E_SERVER)
        cat >&2 <<'ERR'
ERROR: E2E_SERVER is required.
  Set it to the server alias key in ~/.claude/coolify.json (e.g. my-server).
  This alias points to your Coolify instance URL, API key, and SSH host.
  Run /setup-coolify init in any Claude Code session to create or extend ~/.claude/coolify.json.

  E2E_SERVER=my-server bash test/e2e.sh
ERR
        ;;
      E2E_BASE_DOMAIN)
        cat >&2 <<'ERR'
ERROR: E2E_BASE_DOMAIN is required.
  Set it to the base domain under which test app URLs are constructed.
  The script appends "<project>-staging." and "<project>-production." to it,
  so the resulting hostnames must resolve to your Coolify VPS via DNS.

  E2E_BASE_DOMAIN=ci.example.com bash test/e2e.sh
ERR
        ;;
    esac
  done
  exit 1
fi

# ── State (populated as test proceeds, used by cleanup) ────────────────────────

WORK_DIR=""
COOLIFY_PROJECT_UUID=""
STG_APP_UUID=""
PRD_APP_UUID=""
DOPPLER_CREATED=false
SSH_HOST=""
PASS=0
FAIL=0
RESULTS=()
REPORT_FILE=""
DNS_PROVIDER=""
DNS_ZONE_ID=""
DNS_ZONE_NAME_E2E=""
DNS_CREDENTIAL_SOURCE_E2E=""
DNS_CREDENTIAL_KEY_E2E=""
declare -a DNS_RECORDS=()

pass() { PASS=$((PASS+1)); RESULTS+=("  ✓ $*"); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL+1)); RESULTS+=("  ✗ $*"); echo "  ✗ $*" >&2; }
step() { echo ""; echo "=== $* ==="; }

# ── Report writer (called once from main body; cleanup() calls if not yet written) ─

write_report() {
  # No-op if already written (idempotency across success path + trap path).
  [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ] && return 0

  local report_dir="$SKILL_DIR/test/results"
  mkdir -p "$report_dir"
  REPORT_FILE="$report_dir/${TIMESTAMP}.json"

  python3 - \
    "$REPORT_FILE" \
    "${STAGING_DOMAIN:-}" \
    "${COOLIFY_PROJECT_UUID:-}" \
    "${STG_APP_UUID:-}" \
    "${PRD_APP_UUID:-}" \
    "$TIMESTAMP" \
    "$SERVER_ALIAS" \
    "${SSH_HOST:-}" \
    "${TEST_PROJECT:-}" \
    "${DNS_PROVIDER:-}" \
    "${DNS_ZONE_ID:-}" \
    "${DNS_ZONE_NAME_E2E:-}" \
    "${DNS_CREDENTIAL_SOURCE_E2E:-}" \
    "${DNS_CREDENTIAL_KEY_E2E:-}" \
    "${DNS_RECORDS[@]+"${DNS_RECORDS[@]}"}" \
    "---results---" \
    "${RESULTS[@]+"${RESULTS[@]}"}" \
    <<'PY'
import sys, json
from datetime import datetime, timezone

args = sys.argv[1:]
report_file        = args[0]
staging_domain     = args[1]
staging_url        = "https://" + staging_domain if staging_domain else ""
coolify_project_uuid = args[2]
staging_app_uuid   = args[3]
production_app_uuid = args[4]
ts_raw             = args[5]
server_alias       = args[6]
ssh_host           = args[7]
doppler_project    = args[8]
dns_provider       = args[9]
dns_zone_id        = args[10]
dns_zone_name      = args[11]
dns_cred_source    = args[12]
dns_cred_key       = args[13]
rest               = args[14:]

# Split at sentinel to separate dns_records from result_lines
sentinel = "---results---"
if sentinel in rest:
    idx = rest.index(sentinel)
    dns_record_args = rest[:idx]
    result_lines    = rest[idx+1:]
else:
    dns_record_args = []
    result_lines    = rest

run_timestamp = datetime.strptime(ts_raw, "%Y%m%d%H%M%S").replace(
    tzinfo=timezone.utc).isoformat()

steps = []
for line in result_lines:
    s = line.strip()
    passed = s.startswith("✓")
    name = s.lstrip("✓✗").strip()
    steps.append({"name": name, "passed": passed, "detail": ""})

# DNS records format: "domain:record_id"
dns_records = []
for entry in dns_record_args:
    if ":" in entry:
        name_part, rec_id = entry.split(":", 1)
        dns_records.append({"name": name_part, "record_id": rec_id, "type": "A"})

report = {
    "run_timestamp": run_timestamp,
    "server_alias": server_alias,
    "ssh_host": ssh_host,
    "staging_url": staging_url,
    "coolify_project_uuid": coolify_project_uuid,
    "staging_app_uuid": staging_app_uuid,
    "production_app_uuid": production_app_uuid,
    "doppler_project": doppler_project,
    "dns_provider": dns_provider,
    "dns_zone_id": dns_zone_id,
    "dns_zone_name": dns_zone_name,
    "dns_credential_source": dns_cred_source,
    "dns_credential_key": dns_cred_key,
    "dns_records": dns_records,
    "steps": steps,
}

with open(report_file, "w") as f:
    json.dump(report, f, indent=2)
PY

  echo "  report written: $REPORT_FILE"
}

# ── Cleanup (EXIT trap) ────────────────────────────────────────────────────────
# Success:    leave everything running (DNS, apps, Doppler); operator uses
#             cleanup-deployment.sh when done inspecting.
# --keep:     failure but operator wants to inspect; leave everything running.
# Failure:    full teardown — DNS, Coolify apps, Docker volumes, Doppler.

cleanup() {
  local exit_code=$?
  write_report || true
  echo ""
  echo "═══════════════════════════════════"
  echo " Test Results"
  echo "═══════════════════════════════════"
  for r in "${RESULTS[@]}"; do echo "$r"; done
  echo ""
  echo " Passed: $PASS  Failed: $FAIL"
  echo "═══════════════════════════════════"

  # Success — leave everything running so the operator can inspect the live URLs.
  if [ "$exit_code" -eq 0 ]; then
    echo ""
    echo "  Deployment is live — DNS, apps, and Doppler project left running."
    echo "  Run cleanup when done:"
    echo "    bash test/cleanup-deployment.sh ${REPORT_FILE:-<report-file>}"
    exit 0
  fi

  # --keep on failure — leave everything running for debugging; print manual cleanup hints.
  if $KEEP_ON_EXIT; then
    echo ""
    echo "─── --keep: leaving all resources running for inspection ───"
    echo "  Staging URL:        https://${STAGING_DOMAIN:-<not_provisioned>}"
    echo "  Production URL:     https://${PROD_DOMAIN:-<not_provisioned>}"
    echo "  Coolify project:    $TEST_PROJECT (uuid: ${COOLIFY_PROJECT_UUID:-not_created})"
    echo "  Staging app UUID:   ${STG_APP_UUID:-not_created}"
    echo "  Production app UUID:${PRD_APP_UUID:-not_created}"
    echo "  Doppler project:    $TEST_PROJECT (created: $DOPPLER_CREATED)"
    if [ -n "${REPORT_FILE:-}" ] && [ -f "${REPORT_FILE:-}" ]; then
      echo ""
      echo "  Run cleanup when done:"
      echo "    bash test/cleanup-deployment.sh $REPORT_FILE"
    fi
    exit $exit_code
  fi

  # Failure — full teardown: DNS first, then Coolify, then volumes, then Doppler.
  step "Cleanup"

  if [ -n "${DNS_PROVIDER:-}" ] && [ ${#DNS_RECORDS[@]} -gt 0 ]; then
    echo "  Removing DNS records..."
    for entry in "${DNS_RECORDS[@]}"; do
      IFS=':' read -r dns_fqdn dns_rec_id <<< "$entry"
      dns_delete_record "$DNS_ZONE_ID" "$dns_rec_id" \
        && echo "    ✓ deleted $dns_fqdn ($dns_rec_id)" \
        || echo "    ⚠ could not delete $dns_fqdn ($dns_rec_id)"
    done
  fi

  if [ -n "$STG_APP_UUID" ]; then
    coolify_curl DELETE "/applications/$STG_APP_UUID" >/dev/null 2>&1 \
      && echo "  ✓ deleted staging app $STG_APP_UUID" \
      || echo "  ⚠ could not delete staging app $STG_APP_UUID (remove manually)"
  fi
  if [ -n "$PRD_APP_UUID" ]; then
    coolify_curl DELETE "/applications/$PRD_APP_UUID" >/dev/null 2>&1 \
      && echo "  ✓ deleted production app $PRD_APP_UUID" \
      || echo "  ⚠ could not delete production app $PRD_APP_UUID (remove manually)"
  fi
  if [ -n "$COOLIFY_PROJECT_UUID" ]; then
    coolify_curl DELETE "/projects/$COOLIFY_PROJECT_UUID" >/dev/null 2>&1 \
      && echo "  ✓ deleted Coolify project $COOLIFY_PROJECT_UUID" \
      || echo "  ⚠ could not delete Coolify project $COOLIFY_PROJECT_UUID (remove manually)"
  fi

  if [ -n "$SSH_HOST" ]; then
    for uuid in "$STG_APP_UUID" "$PRD_APP_UUID"; do
      [ -z "$uuid" ] && continue
      ssh "$SSH_HOST" "docker volume rm ${uuid}-doppler-cache 2>/dev/null || true" \
        && echo "  ✓ removed docker volume ${uuid}-doppler-cache" \
        || true
    done
  fi

  if $DOPPLER_CREATED; then
    doppler projects delete "$TEST_PROJECT" --yes >/dev/null 2>&1 \
      && echo "  ✓ deleted Doppler project $TEST_PROJECT" \
      || echo "  ⚠ could not delete Doppler project $TEST_PROJECT (remove manually at doppler.com)"
  fi

  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
    echo "  ✓ removed work dir $WORK_DIR"
  fi

  exit $exit_code
}
trap cleanup EXIT

# ── Pre-run stale resource sweep ───────────────────────────────────────────────

purge_stale_e2e_resources() {
  # Delete any csd-hello-test-* resources left over from a previous run (DNS records,
  # Coolify apps, Doppler projects, Docker volumes). Scans three sources:
  #   1. test/results/*.json reports that still have live Coolify projects
  #   2. Coolify apps matching csd-hello-test-* with no corresponding report
  #   3. DNS A records matching csd-hello-test-* in the configured zone
  local found=0

  # 1. Reports matching this server alias whose Coolify project is still alive
  local results_dir="$SKILL_DIR/test/results"
  if [ -d "$results_dir" ]; then
    while IFS= read -r report; do
      [ -f "$report" ] || continue
      local rpt_alias rpt_proj_uuid
      rpt_alias=$(python3 -c "
import json
d = json.load(open('$report'))
print(d.get('server_alias', ''))
" 2>/dev/null || echo "")
      [ "$rpt_alias" != "$SERVER_ALIAS" ] && continue

      rpt_proj_uuid=$(python3 -c "
import json
d = json.load(open('$report'))
print(d.get('coolify_project_uuid') or d.get('project_uuid', ''))
" 2>/dev/null || echo "")
      [ -z "$rpt_proj_uuid" ] && continue

      local proj_alive
      proj_alive=$(coolify_curl GET "/projects/$rpt_proj_uuid" 2>/dev/null \
        | python3 -c "
import json, sys
try: print('yes' if json.load(sys.stdin).get('uuid') else 'no')
except: print('no')
" 2>/dev/null || echo "no")

      if [ "$proj_alive" = "yes" ]; then
        local rpt_name
        rpt_name=$(python3 -c "
import json
print(json.load(open('$report')).get('doppler_project', '$report'))
" 2>/dev/null || echo "$report")
        echo "  stale: $rpt_name — cleaning up via report"
        bash "$SKILL_DIR/test/cleanup-deployment.sh" "$report" 2>&1 | sed 's/^/    /' || true
        found=$((found+1))
      fi
    done < <(find "$results_dir" -name "*.json" -type f | sort)
  fi

  # 2. Orphaned Coolify apps with no matching report
  local orphan_uuids
  orphan_uuids=$(coolify_curl GET "/applications" 2>/dev/null | python3 -c "
import json, sys
try:
    apps = json.load(sys.stdin)
    if isinstance(apps, dict): apps = apps.get('data', [])
    for app in (apps or []):
        if app.get('name', '').startswith('csd-hello-test-'):
            print(app['uuid'])
except: pass
" 2>/dev/null || echo "")

  if [ -n "$orphan_uuids" ]; then
    while IFS= read -r uuid; do
      [ -z "$uuid" ] && continue
      echo "  orphaned app (no report): $uuid — deleting"
      coolify_curl DELETE "/applications/$uuid" >/dev/null 2>&1 \
        && echo "    ✓ deleted" || echo "    ⚠ could not delete $uuid"
      found=$((found+1))
    done <<< "$orphan_uuids"
  fi

  # 3. Orphaned DNS A records matching csd-e2e-* in the configured zone
  local _pre_dns_default
  _pre_dns_default=$(python3 -c "
import json, sys
d = json.load(open('$HOME/.claude/coolify.json'))
dns_def = d.get('servers', {}).get('$SERVER_ALIAS', {}).get('dns_default', {})
if not dns_def or dns_def.get('provider', 'none') == 'none':
    print('none'); sys.exit(0)
print(json.dumps(dns_def))
" 2>/dev/null || echo "none")

  if [ "$_pre_dns_default" != "none" ]; then
    eval "$(echo "$_pre_dns_default" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(f\"DNS_PROVIDER={d.get('provider','none')}\")
print(f\"DNS_ZONE_NAME={d.get('zone_name','')}\")
print(f\"DNS_CREDENTIAL_SOURCE={d.get('credential_source','doppler')}\")
print(f\"DNS_CREDENTIAL_KEY={d.get('credential_key','')}\")
")"
    export DNS_PROVIDER DNS_ZONE_NAME DNS_CREDENTIAL_SOURCE DNS_CREDENTIAL_KEY
    dns_load_credentials_from_env 2>/dev/null || true

    if [ -n "${DNS_API_TOKEN:-}" ] && [ -n "${DNS_ZONE_NAME:-}" ]; then
      local _pre_zone_id
      _pre_zone_id=$(dns_cf_get_zone_id "$DNS_ZONE_NAME" 2>/dev/null || echo "")
      if [ -n "$_pre_zone_id" ]; then
        local orphan_recs
        orphan_recs=$(dns_cf_curl GET "/zones/${_pre_zone_id}/dns_records?per_page=100&type=A" 2>/dev/null \
          | python3 -c "
import json, sys
try:
    for r in json.load(sys.stdin).get('result', []):
        if r.get('name','').startswith('csd-hello-test-'):
            print(f\"{r['id']} {r['name']}\")
except: pass
" 2>/dev/null || echo "")
        if [ -n "$orphan_recs" ]; then
          while IFS=' ' read -r rec_id rec_name; do
            [ -z "$rec_id" ] && continue
            echo "  stale DNS record: $rec_name — deleting"
            dns_cf_delete_record "$_pre_zone_id" "$rec_id" \
              && echo "    ✓ deleted $rec_name" || echo "    ⚠ could not delete $rec_name"
            found=$((found+1))
          done <<< "$orphan_recs"
        fi
      fi
      unset DNS_API_TOKEN
    fi
  fi

  if [ "$found" -eq 0 ]; then echo "  none found — clean slate"; fi
}

# ── Prerequisites ──────────────────────────────────────────────────────────────

step "Prerequisites"

command -v python3 >/dev/null       || { echo "MISSING: python3" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "MISSING: pyyaml — pip3 install pyyaml" >&2; exit 1; }
command -v doppler >/dev/null        || { echo "MISSING: doppler CLI" >&2; exit 1; }
command -v curl >/dev/null           || { echo "MISSING: curl" >&2; exit 1; }
command -v ssh >/dev/null            || { echo "MISSING: ssh" >&2; exit 1; }
[ -f "$HOME/.claude/coolify.json" ]  || { echo "MISSING: ~/.claude/coolify.json" >&2; exit 1; }

# Resolution precedence: --server flag (already set above) > E2E_SERVER env var > error
if [ -z "$SERVER_ALIAS" ]; then
  SERVER_ALIAS="$E2E_SERVER"
fi

coolify_load_server "$SERVER_ALIAS"
doppler_load_account "$SERVER_ALIAS"

SSH_HOST=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER_ALIAS',{}).get('ssh_host',''))
")
[ -n "$SSH_HOST" ] || { echo "MISSING: ssh_host in coolify.json servers.$SERVER_ALIAS" >&2; exit 1; }

echo "  server alias:    $SERVER_ALIAS → $COOLIFY_URL"
echo "  doppler account: $DOPPLER_ACCOUNT"
echo "  ssh host:        $SSH_HOST"
echo "  test project:    $TEST_PROJECT"
echo "  image:           $E2E_IMAGE"
pass "prerequisites met"

# ── Preflight: verify test image is pullable ───────────────────────────────────

step "Preflight: verify test image is pullable"
echo "  image: $E2E_IMAGE"
if docker pull "$E2E_IMAGE" --quiet >/dev/null 2>&1; then
  pass "test image pullable: $E2E_IMAGE"
else
  fail "test image not found or not pullable: $E2E_IMAGE"
  echo "" >&2
  echo "  Build and push the test image first:" >&2
  echo "    export GHCR_TOKEN=ghp_...   # PAT with write:packages scope" >&2
  echo "    bash test/push-hello-world.sh" >&2
  echo "" >&2
  echo "  Or override with a custom image:" >&2
  echo "    E2E_IMAGE=my-org/my-hello-world:latest bash test/e2e.sh" >&2
  exit 1
fi

# ── Work directory ─────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d -t csd-hello-test-XXXX)

# ── Step 0: Pre-run cleanup of stale csd-hello-test-* resources ───────────────

step "Step 0: Pre-run sweep for stale test deployments"
purge_stale_e2e_resources

# ── Step 1: Coolify API reachable ──────────────────────────────────────────────

step "Step 1: Coolify API"
if coolify_curl GET "/projects" >/dev/null 2>&1; then
  pass "Coolify API reachable at $COOLIFY_URL"
else
  fail "Coolify API unreachable at $COOLIFY_URL"
  exit 1
fi

# ── Step 2: Doppler project + secrets ─────────────────────────────────────────

step "Step 2: Doppler test project"

doppler projects create "$TEST_PROJECT" \
  --description "claude-skills-deploy E2E test — auto-deleted" >/dev/null 2>&1
DOPPLER_CREATED=true
echo "  created project: $TEST_PROJECT"

# Doppler creates stg/prd configs by default — use those directly
for cfg in stg prd; do
  doppler secrets set \
    HELLO=world \
    E2E_TEST=true \
    --project "$TEST_PROJECT" \
    --config "$cfg" >/dev/null 2>&1
  echo "  secrets set in: $TEST_PROJECT/$cfg (HELLO, E2E_TEST)"
done

pass "Doppler project ready (staging + production configs with dummy secrets)"

# ── Step 3: Generate coolify.yaml ─────────────────────────────────────────────

step "Step 3: Generate test coolify.yaml"

STAGING_DOMAIN="${TEST_PROJECT}-staging.${E2E_BASE_DOMAIN}"
PROD_DOMAIN="${TEST_PROJECT}-production.${E2E_BASE_DOMAIN}"
YAML_PATH="$WORK_DIR/coolify.yaml"

# Read dns_default from coolify.json for the test server alias (optional).
# If present, the dns: block is injected into the test YAML so DNS provisioning
# is exercised. If absent, the test runs the no-DNS path.
_DNS_DEFAULT=$(python3 -c "
import json, sys
d = json.load(open('$HOME/.claude/coolify.json'))
dns_def = d.get('servers', {}).get('$SERVER_ALIAS', {}).get('dns_default', {})
if not dns_def or dns_def.get('provider', 'none') == 'none':
    print('none')
    sys.exit(0)
import json
print(json.dumps(dns_def))
" 2>/dev/null || echo "none")

python3 - "$YAML_PATH" "$_DNS_DEFAULT" <<'PY'
import yaml, sys, json
path = sys.argv[1]
dns_raw = sys.argv[2]

d = {
    'project': 'E2E_PROJECT_PLACEHOLDER',
    'server': 'E2E_SERVER_PLACEHOLDER',
    'doppler_project': 'E2E_DOPPLER_PLACEHOLDER',
    'registry': {
        'image': 'E2E_IMAGE_PLACEHOLDER',
        'retention_tags': 5
    },
    'build': {'context': '.', 'dockerfile': './Dockerfile'},
    'environments': {
        'staging': {
            'domain': 'E2E_STAGING_DOMAIN_PLACEHOLDER',
            'doppler_environment': 'stg'
        },
        'production': {
            'domain': 'E2E_PROD_DOMAIN_PLACEHOLDER',
            'doppler_environment': 'prd'
        }
    },
    'env_vars': ['HELLO', 'E2E_TEST'],
    'coolify_app_ids': {'staging': None, 'production': None}
}

if dns_raw != 'none':
    try:
        dns_cfg = json.loads(dns_raw)
        d['dns'] = dns_cfg
    except Exception:
        pass

with open(path, 'w') as f:
    yaml.safe_dump(d, f, sort_keys=False, default_flow_style=False)
PY

# Replace placeholder values with actual test values
python3 - "$YAML_PATH" <<PY
import yaml, sys
path = sys.argv[1]
with open(path) as f:
    d = yaml.safe_load(f)
d['project']                                  = '$TEST_PROJECT'
d['server']                                   = '$SERVER_ALIAS'
d['doppler_project']                          = '$TEST_PROJECT'
d['registry']['image']                        = '$E2E_IMAGE'
d['environments']['staging']['domain']        = '$STAGING_DOMAIN'
d['environments']['production']['domain']     = '$PROD_DOMAIN'
with open(path, 'w') as f:
    yaml.safe_dump(d, f, sort_keys=False, default_flow_style=False)
PY

if [ "$_DNS_DEFAULT" != "none" ]; then
  echo "  dns: block injected from coolify.json dns_default for $SERVER_ALIAS"
else
  echo "  dns: disabled for this run (no dns_default in coolify.json servers.$SERVER_ALIAS)"
fi

python3 -c "import yaml; yaml.safe_load(open('$YAML_PATH'))" \
  && pass "coolify.yaml valid YAML" \
  || { fail "coolify.yaml failed YAML parse"; exit 1; }

# ── Step 4: validate.sh ────────────────────────────────────────────────────────

step "Step 4: validate.sh"

if bash "$SKILL_DIR/scripts/validate.sh" "$YAML_PATH" 2>&1; then
  pass "validate.sh passed"
else
  fail "validate.sh failed — aborting before any Coolify mutation"
  exit 1
fi

# ── Step 5: provision.sh ───────────────────────────────────────────────────────

step "Step 5: provision.sh (creates Coolify apps + Doppler service tokens)"

# provision.sh runs validate.sh internally as its first step — that's fine (idempotent)
if bash "$SKILL_DIR/scripts/provision.sh" "$YAML_PATH" 2>&1; then
  pass "provision.sh completed"
else
  fail "provision.sh failed"
  exit 1
fi

# Read back the app UUIDs written by provision.sh into coolify.yaml
eval "$(python3 -c "
import yaml
d=yaml.safe_load(open('$YAML_PATH'))
ids=d.get('coolify_app_ids',{})
print(f\"STG_APP_UUID='{ids.get('staging','')}'\")
print(f\"PRD_APP_UUID='{ids.get('production','')}'\")
")"

if [ -n "$STG_APP_UUID" ] && [ -n "$PRD_APP_UUID" ]; then
  pass "app UUIDs written back: staging=$STG_APP_UUID production=$PRD_APP_UUID"
  # Extract Coolify project UUID for cleanup
  COOLIFY_PROJECT_UUID=$(coolify_curl GET "/projects" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('name')=='$TEST_PROJECT': print(p.get('uuid','')); break
")
else
  fail "coolify_app_ids not written back to coolify.yaml"
  exit 1
fi

# Capture DNS record IDs if provision.sh created them (dns: block was written into test YAML)
eval "$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$YAML_PATH'))
dns = d.get('dns', {})
provider = dns.get('provider', 'none')
if not provider or provider == 'none':
    print('_dns_enabled=false')
    sys.exit(0)
print('_dns_enabled=true')
print(f\"_dns_zone_name={dns.get('zone_name','')}\"  )
print(f\"_dns_cred_source={dns.get('credential_source','doppler')}\"  )
print(f\"_dns_cred_key={dns.get('credential_key','')}\"  )
print(f\"_dns_provider_val={provider}\"  )
")"

if [ "${_dns_enabled:-false}" = "true" ]; then
  DNS_PROVIDER="$_dns_provider_val"
  DNS_ZONE_NAME_E2E="$_dns_zone_name"
  DNS_CREDENTIAL_SOURCE_E2E="$_dns_cred_source"
  DNS_CREDENTIAL_KEY_E2E="$_dns_cred_key"
  export DNS_PROVIDER DNS_ZONE_NAME="$DNS_ZONE_NAME_E2E"
  export DOPPLER_PROJECT="$TEST_PROJECT" DOPPLER_ENV="stg"
  dns_load_credentials "$YAML_PATH"
  DNS_ZONE_ID=$(dns_cf_get_zone_id "$DNS_ZONE_NAME")
  if [ -n "$DNS_ZONE_ID" ]; then
    for d in "$STAGING_DOMAIN" "$PROD_DOMAIN"; do
      rec=$(dns_cf_find_record "$DNS_ZONE_ID" "$d" "A")
      if [ -n "$rec" ]; then
        DNS_RECORDS+=("$d:$rec")
      fi
    done
    pass "DNS records present: ${#DNS_RECORDS[@]} (zone_id=$DNS_ZONE_ID)"
  else
    echo "  dns: zone '$DNS_ZONE_NAME' not found — DNS records not captured"
  fi
fi

# ── Step 6: Trigger staging deploy ────────────────────────────────────────────

step "Step 6: Trigger staging deploy"

# Update the staging app's image tag to 'latest' (provision.sh defaults to 'main')
coolify_curl PATCH "/applications/$STG_APP_UUID" \
  '{"docker_registry_image_tag": "latest"}' >/dev/null 2>&1
echo "  patched staging app image tag → latest"

DEPLOYMENT_UUID=$(coolify_deploy_app "$STG_APP_UUID")
if [ -n "$DEPLOYMENT_UUID" ]; then
  pass "deploy triggered: deployment_uuid=$DEPLOYMENT_UUID"
else
  fail "deploy trigger returned no deployment UUID"
  exit 1
fi

# ── Step 7: Poll deployment status ────────────────────────────────────────────

step "Step 7: Wait for deploy to finish (timeout: ${DEPLOY_TIMEOUT}s)"

START_TS=$(date +%s)
DEPLOY_STATUS="unknown"
while true; do
  DEPLOY_STATUS=$(coolify_curl GET "/deployments/$DEPLOYMENT_UUID" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")

  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))
  echo "  [${ELAPSED}s] deploy status: $DEPLOY_STATUS"

  case "$DEPLOY_STATUS" in
    finished) break ;;
    error|failed|cancelled)
      fail "deploy ended with status: $DEPLOY_STATUS"
      echo "  Check Coolify dashboard for logs: $COOLIFY_URL"
      exit 1
      ;;
  esac

  if (( ELAPSED > DEPLOY_TIMEOUT )); then
    fail "deploy did not finish within ${DEPLOY_TIMEOUT}s (last status: $DEPLOY_STATUS)"
    exit 1
  fi
  sleep 10
done

pass "deploy finished (took $(($(date +%s) - START_TS))s)"

# ── Step 8: Verify app is running via Coolify API ─────────────────────────────

step "Step 8: Verify app status via Coolify API"

APP_STATUS=$(coolify_curl GET "/applications/$STG_APP_UUID" 2>/dev/null \
  | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")

echo "  staging app status: $APP_STATUS"
if [[ "$APP_STATUS" == running* ]]; then
  pass "staging app is running (status: $APP_STATUS)"
else
  fail "staging app status is '$APP_STATUS' (expected 'running' or 'running:healthy')"
  # Don't exit — still attempt the HTTP smoke test; status field may lag
fi

# ── Step 9: HTTP smoke test ────────────────────────────────────────────────────

step "Step 9: HTTP smoke test — https://${STAGING_DOMAIN} (timeout: ${SMOKE_TIMEOUT}s)"
echo "  (Let's Encrypt cert issuance takes ~30-60s on first use for a new domain)"

START_TS=$(date +%s)
SMOKE_PASSED=false

while true; do
  ELAPSED=$(($(date +%s) - START_TS))

  # Check /api/health — must return HTTP 200
  HEALTH_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "https://${STAGING_DOMAIN}/api/health" 2>/dev/null || echo "000")

  echo "  [${ELAPSED}s] /api/health → HTTP $HEALTH_CODE"

  if [ "$HEALTH_CODE" = "200" ]; then
    # Also verify the smoke-test string is in the root page
    BODY=$(curl -sf --max-time 10 "https://${STAGING_DOMAIN}/" 2>/dev/null || echo "")
    if echo "$BODY" | grep -q "claude-skills-deploy-e2e-ok"; then
      SMOKE_PASSED=true
      break
    else
      echo "  /api/health returned 200 but root page body check failed — retrying"
    fi
  fi

  if (( ELAPSED > SMOKE_TIMEOUT )); then
    echo "  smoke test timed out after ${SMOKE_TIMEOUT}s"
    break
  fi
  sleep 10
done

if $SMOKE_PASSED; then
  pass "smoke test: https://${STAGING_DOMAIN}/api/health returned 200 + body check passed"
else
  fail "smoke test: could not reach https://${STAGING_DOMAIN} within ${SMOKE_TIMEOUT}s"
  echo "  This may be a Let's Encrypt cert delay. The deploy itself finished successfully."
  echo "  Verify manually: curl https://${STAGING_DOMAIN}/api/health"
fi

# ── Step 10: Promote image to production ──────────────────────────────────────

step "Step 10: Promote image to production"

coolify_curl PATCH "/applications/$PRD_APP_UUID" \
  '{"docker_registry_image_tag": "latest"}' >/dev/null 2>&1
echo "  patched production app image tag → latest"

PRD_DEPLOYMENT_UUID=$(coolify_deploy_app "$PRD_APP_UUID")
if [ -n "$PRD_DEPLOYMENT_UUID" ]; then
  pass "production deploy triggered: deployment_uuid=$PRD_DEPLOYMENT_UUID"
else
  fail "production deploy trigger returned no deployment UUID"
  exit 1
fi

START_TS=$(date +%s)
PRD_DEPLOY_STATUS="unknown"
while true; do
  PRD_DEPLOY_STATUS=$(coolify_curl GET "/deployments/$PRD_DEPLOYMENT_UUID" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")

  ELAPSED=$(($(date +%s) - START_TS))
  echo "  [${ELAPSED}s] production deploy status: $PRD_DEPLOY_STATUS"

  case "$PRD_DEPLOY_STATUS" in
    finished) break ;;
    error|failed|cancelled)
      fail "production deploy ended with status: $PRD_DEPLOY_STATUS"
      exit 1 ;;
  esac
  [ $ELAPSED -ge $DEPLOY_TIMEOUT ] && fail "production deploy timed out after ${DEPLOY_TIMEOUT}s" && exit 1
  sleep 5
done

pass "production deploy finished (took $(($(date +%s) - START_TS))s)"

PRD_STATUS=$(coolify_curl GET "/applications/$PRD_APP_UUID" 2>/dev/null \
  | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")

echo "  production app status: $PRD_STATUS"
if [[ "$PRD_STATUS" == running* ]]; then
  pass "production app is running (status: $PRD_STATUS)"
else
  fail "production app status is '$PRD_STATUS' (expected 'running' or 'running:healthy')"
fi

# ── Write test report ─────────────────────────────────────────────────────────

step "Write test report"
write_report

# ── Completion summary (success path) ─────────────────────────────────────────

echo ""
# Resolve VPS IP for summary (coolify.json vps_ip field → SSH fallback)
VPS_IP=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers', {}).get('$SERVER_ALIAS', {}).get('vps_ip', ''))
" 2>/dev/null || echo "")
if [ -z "$VPS_IP" ] && [ -n "$SSH_HOST" ]; then
  VPS_IP=$(ssh "$SSH_HOST" "curl -s -4 ifconfig.me" 2>/dev/null || echo "")
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo " Deployment complete — inspect before cleaning up"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  URLs"
echo "  ────────────────────────────────────────────────────────────────────────────"
echo "  Staging    : https://${STAGING_DOMAIN}"
echo "  Production : https://${PROD_DOMAIN}"
echo ""
echo "  DNS records created"
echo "  ────────────────────────────────────────────────────────────────────────────"
if [ ${#DNS_RECORDS[@]} -gt 0 ]; then
  _vps="${VPS_IP:-149.248.4.46}"
  _args=("$_vps")
  for entry in "${DNS_RECORDS[@]}"; do _args+=("$entry"); done
  python3 -c "
import sys
target = sys.argv[1]
rows = [a.split(':', 1) for a in sys.argv[2:]]
max_h = max(max(len(r[0]) for r in rows), len('HOSTNAME'))
max_t = max(len(target), len('TARGET'))
max_i = max(max(len(r[1]) for r in rows), len('RECORD ID'))
hfmt = '  {:<4}  {:<{mh}}  {:<{mt}}  {}'
sep  = '  ' + '─'*4 + '  ' + '─'*max_h + '  ' + '─'*max_t + '  ' + '─'*max_i
print(hfmt.format('TYPE', 'HOSTNAME', 'TARGET', 'RECORD ID', mh=max_h, mt=max_t))
print(sep)
for fqdn, rec_id in rows:
    print(hfmt.format('A', fqdn, target, rec_id, mh=max_h, mt=max_t))
" "${_args[@]}"
else
  echo "  (none — dns: block not configured)"
fi
echo ""
echo "  Cleanup"
echo "  ────────────────────────────────────────────────────────────────────────────"
echo "  bash test/cleanup-deployment.sh $REPORT_FILE"
echo ""
echo "  (next e2e run will auto-clean if you forget)"
echo "═══════════════════════════════════════════════════════════════════════════════"

# ── Done ───────────────────────────────────────────────────────────────────────
# Cleanup runs via trap EXIT
