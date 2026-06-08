#!/usr/bin/env bash
# validate-deploy-ssh-host.sh — MSRV-07 regression test for deploy_server ↔ deploy_ssh_host coupling.
#
# validate.sh enforces that deploy_server (coolify.yaml) and deploy_ssh_host
# (coolify.json) are either both specified or both absent. This prevents:
#   • deploy_server set + deploy_ssh_host missing → provision.sh falls back to
#     ssh_host (Coolify host) for volume creation and DNS IP resolution, which
#     silently targets the wrong server.
#   • deploy_server absent + deploy_ssh_host present → dead config that confuses
#     operators and may break if future code starts reading deploy_ssh_host
#     unconditionally.
#
# Runs against a real Coolify instance. Requires:
#   - ~/.claude/coolify.json populated
#   - --server <alias> or VALIDATE_SERVER env var
#
# Usage:
#   bash test/validate-deploy-ssh-host.sh --server vultr-stream
#   VALIDATE_SERVER=vultr-stream bash test/validate-deploy-ssh-host.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SH="$REPO_ROOT/scripts/validate.sh"

# ── argv / env parsing ────────────────────────────────────────────────────────
SERVER_ALIAS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER_ALIAS="$2"; shift 2;;
    *)        echo "ERROR: unknown arg: $1" >&2; exit 1;;
  esac
done
SERVER_ALIAS="${SERVER_ALIAS:-${VALIDATE_SERVER:-}}"
if [ -z "$SERVER_ALIAS" ]; then
  echo "ERROR: server alias required. Pass --server <alias> or set VALIDATE_SERVER." >&2
  echo "Aliases available in ~/.claude/coolify.json:" >&2
  python3 -c "import json; print('  ' + '\n  '.join(json.load(open('$HOME/.claude/coolify.json')).get('servers', {}).keys()))" >&2 || true
  exit 1
fi
if [ ! -f "$VALIDATE_SH" ]; then
  echo "ERROR: validate.sh not found at $VALIDATE_SH" >&2; exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }
step() { echo ""; echo "── $* ──"; }

# ── temp dir + cleanup trap ───────────────────────────────────────────────────
TMP=$(mktemp -d -t csd-validate-deploy-ssh-host.XXXXXXXX)
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ── fixture builder ───────────────────────────────────────────────────────────
write_fixture() {
  local path="$1" deploy_srv="${2:-}"
  cat > "$path" <<YAML
project: csd-validate-test
server: $SERVER_ALIAS
doppler_project: claude-skills-deploy
registry:
  image: ghcr.io/example/csd-validate-test
environments:
  staging:
    domain: csd-validate-test-staging.example.com
    doppler_environment: stg
  production:
    domain: csd-validate-test.example.com
    doppler_environment: prd
env_vars:
  - DUMMY_KEY
dns:
  provider: none
  zone_name: ""
  credential_source: doppler
  credential_key: ""
YAML
  if [ -n "$deploy_srv" ]; then
    echo "deploy_server: $deploy_srv" >> "$path"
  fi
}

# ── Read real config state ────────────────────────────────────────────────────
REAL_DEPLOY_SSH_HOST=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER_ALIAS',{}).get('deploy_ssh_host',''))
")

echo ""
echo "Real config: deploy_ssh_host=${REAL_DEPLOY_SSH_HOST:-<missing>}"

# ── Case 1: deploy_server set but deploy_ssh_host missing ─────────────────────
step "Case 1: deploy_server set + deploy_ssh_host missing → expect deploy_ssh_host error"

if [ -n "$REAL_DEPLOY_SSH_HOST" ]; then
  echo "  SKIP: real coolify.json already has deploy_ssh_host for $SERVER_ALIAS"
else
  FIXTURE1="$TMP/fixture-deploy-no-ssh.yaml"
  write_fixture "$FIXTURE1" "localhost"

  STDERR1=$(bash "$VALIDATE_SH" "$FIXTURE1" 2>&1 1>/dev/null || true)
  RC1=$(bash "$VALIDATE_SH" "$FIXTURE1" >/dev/null 2>&1; echo $?)

  if [ "$RC1" -ne 0 ]; then
    pass "validate.sh exited non-zero (rc=$RC1)"
  else
    fail "validate.sh exited 0 — expected non-zero when deploy_server is set but deploy_ssh_host missing"
  fi

  if echo "$STDERR1" | grep -q "deploy_ssh_host"; then
    pass "stderr names deploy_ssh_host field"
  else
    fail "stderr does not name deploy_ssh_host field"
    echo "$STDERR1" >&2
  fi

  if echo "$STDERR1" | grep -q "required when deploy_server is set"; then
    pass "stderr includes 'required when deploy_server is set'"
  else
    fail "stderr missing 'required when deploy_server is set'"
  fi
fi

# ── Case 2: deploy_server absent but deploy_ssh_host present ──────────────────
step "Case 2: deploy_server absent + deploy_ssh_host present → expect deploy_ssh_host error"

if [ -z "$REAL_DEPLOY_SSH_HOST" ]; then
  echo "  SKIP: real coolify.json has no deploy_ssh_host for $SERVER_ALIAS"
else
  FIXTURE2="$TMP/fixture-no-deploy-yes-ssh.yaml"
  write_fixture "$FIXTURE2" ""

  STDERR2=$(bash "$VALIDATE_SH" "$FIXTURE2" 2>&1 1>/dev/null || true)
  RC2=$(bash "$VALIDATE_SH" "$FIXTURE2" >/dev/null 2>&1; echo $?)

  if [ "$RC2" -ne 0 ]; then
    pass "validate.sh exited non-zero (rc=$RC2)"
  else
    fail "validate.sh exited 0 — expected non-zero when deploy_server absent but deploy_ssh_host present"
  fi

  if echo "$STDERR2" | grep -q "deploy_ssh_host"; then
    pass "stderr names deploy_ssh_host field"
  else
    fail "stderr does not name deploy_ssh_host field"
    echo "$STDERR2" >&2
  fi

  if echo "$STDERR2" | grep -q "present but deploy_server is absent"; then
    pass "stderr includes 'present but deploy_server is absent'"
  else
    fail "stderr missing 'present but deploy_server is absent'"
  fi
fi

# ── Case 3: happy path — both present ─────────────────────────────────────────
step "Case 3: deploy_server set + deploy_ssh_host present → coupling OK"

if [ -z "$REAL_DEPLOY_SSH_HOST" ]; then
  echo "  SKIP: real coolify.json has no deploy_ssh_host"
else
  FIXTURE3="$TMP/fixture-both-present.yaml"
  write_fixture "$FIXTURE3" "localhost"

  STDERR3=$(bash "$VALIDATE_SH" "$FIXTURE3" 2>&1 1>/dev/null || true)

  if ! echo "$STDERR3" | grep -q "FAIL: INVALID:coolify.json:servers.*deploy_ssh_host"; then
    pass "stderr does NOT contain a deploy_ssh_host fail line"
  else
    fail "stderr contains a deploy_ssh_host fail line when both are present"
  fi

  if echo "$STDERR3" | grep -q "deploy_server + deploy_ssh_host coupling OK"; then
    pass "stderr includes coupling OK log"
  else
    fail "stderr missing coupling OK log"
  fi
fi

# ── Case 4: happy path — both absent ──────────────────────────────────────────
step "Case 4: deploy_server absent + deploy_ssh_host absent → coupling OK"

if [ -n "$REAL_DEPLOY_SSH_HOST" ]; then
  echo "  SKIP: real coolify.json has deploy_ssh_host"
else
  FIXTURE4="$TMP/fixture-both-absent.yaml"
  write_fixture "$FIXTURE4" ""

  STDERR4=$(bash "$VALIDATE_SH" "$FIXTURE4" 2>&1 1>/dev/null || true)

  if ! echo "$STDERR4" | grep -q "FAIL: INVALID:coolify.json:servers.*deploy_ssh_host"; then
    pass "stderr does NOT contain a deploy_ssh_host fail line"
  else
    fail "stderr contains a deploy_ssh_host fail line when both are absent"
  fi

  if ! echo "$STDERR4" | grep -q "deploy_server + deploy_ssh_host coupling OK"; then
    pass "stderr does NOT contain coupling OK log (check correctly skipped)"
  else
    fail "stderr contains coupling OK log when both are absent"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "RESULT: validate-deploy-ssh-host FAILED — see failures above" >&2
  exit 1
fi

echo ""
echo "RESULT: validate-deploy-ssh-host PASSED ($PASS checks)"
exit 0
