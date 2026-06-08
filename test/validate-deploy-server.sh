#!/usr/bin/env bash
# validate-deploy-server.sh — MSRV-03 regression test for scripts/validate.sh.
#
# Asserts that validate.sh:
#   1. Exits non-zero with a named-server error when coolify.yaml's
#      deploy_server: references a server not registered in Coolify
#   2. Skips the deploy_server check entirely when deploy_server is absent
#      (backward compatibility — MSRV-06)
#
# Runs against a real Coolify instance (no mocks). Requires:
#   - ~/.claude/coolify.json populated
#   - --server <alias> or VALIDATE_SERVER env var naming a reachable server alias
#
# Usage:
#   bash test/validate-deploy-server.sh --server vultr-stream
#   VALIDATE_SERVER=vultr-stream bash test/validate-deploy-server.sh

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
TMP=$(mktemp -d -t csd-validate-deploy-server.XXXXXXXX)
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ── fixture builder ───────────────────────────────────────────────────────────
# Writes a minimal coolify.yaml at $1. If $2 is non-empty, includes deploy_server: $2.
NONCE="csd-validate-test-nonexistent-$(date +%s)-$$"
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

# ── Case 1: deploy_server names a nonexistent server → expect non-zero exit ──
step "Case 1: deploy_server=$NONCE (nonexistent) → expect non-zero exit + named-server error"

FIXTURE1="$TMP/fixture-nonexistent.yaml"
write_fixture "$FIXTURE1" "$NONCE"

STDERR1=$(bash "$VALIDATE_SH" "$FIXTURE1" 2>&1 1>/dev/null || true)
RC1=$(bash "$VALIDATE_SH" "$FIXTURE1" >/dev/null 2>&1; echo $?)

if [ "$RC1" -ne 0 ]; then
  pass "validate.sh exited non-zero (rc=$RC1)"
else
  fail "validate.sh exited 0 — expected non-zero when deploy_server is nonexistent"
fi

if echo "$STDERR1" | grep -q "deploy_server '$NONCE'"; then
  pass "stderr names the offending deploy_server value ($NONCE)"
else
  fail "stderr does not name the offending deploy_server value. Stderr was:"
  echo "$STDERR1" >&2
fi

if echo "$STDERR1" | grep -q "not registered in Coolify"; then
  pass "stderr includes 'not registered in Coolify' phrase"
else
  fail "stderr missing 'not registered in Coolify' phrase"
fi

if echo "$STDERR1" | grep -q "available:"; then
  pass "stderr lists available servers ('available:' marker present)"
else
  fail "stderr missing 'available:' server list marker"
fi

# ── Case 2: deploy_server absent (backward compat) → MSRV-03 check skipped ──
step "Case 2: deploy_server absent (baseline) → MSRV-03 check skipped"

FIXTURE2="$TMP/fixture-baseline.yaml"
write_fixture "$FIXTURE2" ""

STDERR2=$(bash "$VALIDATE_SH" "$FIXTURE2" 2>&1 1>/dev/null || true)
# NOTE: this fixture's Doppler keys probably do not exist, so validate.sh
# may fail at the Doppler check. That's fine — we only assert the
# deploy_server check did NOT contribute a fail line.

if ! echo "$STDERR2" | grep -q "FAIL: INVALID:coolify.yaml:deploy_server"; then
  pass "stderr does NOT contain a deploy_server fail line (MSRV-06 backward compat)"
else
  fail "stderr contains a deploy_server fail line when deploy_server was absent — MSRV-06 regression"
  echo "$STDERR2" >&2
fi

if ! echo "$STDERR2" | grep -q "validate: deploy_server"; then
  pass "stderr does NOT contain the deploy_server success log (check fully skipped)"
else
  fail "stderr contains 'validate: deploy_server' success log — expected check to be skipped entirely"
  echo "$STDERR2" >&2
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "RESULT: validate-deploy-server FAILED — see failures above" >&2
  exit 1
fi

echo ""
echo "RESULT: validate-deploy-server PASSED ($PASS checks)"
exit 0
