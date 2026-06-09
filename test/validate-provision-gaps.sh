#!/usr/bin/env bash
# validate-provision-gaps.sh — Regression tests for T02 provision-gap checks in validate.sh.
#
# Covers the four pre-mutation guards added to validate.sh to close gaps identified
# in T01 (coverage matrix):
#
#   P04 gap — effective Coolify server checked when deploy_server is absent in coolify.yaml
#   P07 gap — deploy_vps_ip present-but-not-resolvable detected early
#   P08 gap — deploy_vps_ip format validated against IPv4 regex before any mutation
#   P12 gap — SSH probe to effective ssh_host before Coolify/Docker operations
#
# Structure
# ─────────
#   Part 1 (no deps)   — IPv4 format validation logic (P07 + P08)
#   Part 2 (no deps)   — SSH probe mechanics (P12)
#   Part 3 (--server)  — end-to-end validate.sh integration (P04, P07/P08, P12)
#                        Automatically SKIPPED when --server is not supplied.
#
# Usage:
#   bash test/validate-provision-gaps.sh                         # unit tests only
#   bash test/validate-provision-gaps.sh --server vultr-stream   # unit + integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SH="$REPO_ROOT/scripts/validate.sh"

# ── argv ──────────────────────────────────────────────────────────────────────
SERVER_ALIAS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER_ALIAS="$2"; shift 2;;
    *)        echo "ERROR: unknown arg: $1" >&2; exit 1;;
  esac
done
SERVER_ALIAS="${SERVER_ALIAS:-${VALIDATE_SERVER:-}}"

# ── helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $*"; }
step() { echo ""; echo "── $* ──"; }

# ── temp dir + cleanup ────────────────────────────────────────────────────────
TMP=$(mktemp -d -t csd-validate-provision-gaps.XXXXXXXX)
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# PART 1: IPv4 format validation — P07 / P08 logic extracted from validate.sh
#
# validate.sh (P08 check) uses Python re.fullmatch with per-octet 0–255 range
# validation. Tests here exercise the same logic in isolation, covering both
# the success path (valid IPv4 accepted) and error paths (bad formats rejected).
# ══════════════════════════════════════════════════════════════════════════════

step "Part 1: IPv4 format check (P07/P08 logic)"

# Replicate the exact regex from validate.sh P08 section.
check_ipv4() {
  local ip="$1"
  python3 -c "
import re, sys
ip = sys.argv[1]
oct_re = r'(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
if re.fullmatch(rf'{oct_re}\.{oct_re}\.{oct_re}\.{oct_re}', ip):
    sys.exit(0)
else:
    sys.exit(1)
" "$ip" 2>/dev/null
}

# ── Success path: valid IPv4 addresses ────────────────────────────────────────
step "Part 1a: valid IPv4 addresses (success path)"

VALID_IPS=(
  "1.2.3.4"
  "0.0.0.0"
  "255.255.255.255"
  "10.0.0.1"
  "192.168.100.200"
  "149.248.4.46"
  "100.64.0.1"
)

for ip in "${VALID_IPS[@]}"; do
  if check_ipv4 "$ip"; then
    pass "accepts valid IPv4: $ip"
  else
    fail "rejected valid IPv4: $ip"
  fi
done

# ── Error path: non-IPv4 and malformed strings ────────────────────────────────
step "Part 1b: malformed / non-IPv4 strings (error path)"

INVALID_CASES=(
  ""                          # empty
  "not-an-ip"                 # hostname string
  "256.0.0.1"                 # octet > 255
  "999.999.999.999"           # all octets out of range
  "1.2.3"                     # only 3 octets
  "1.2.3.4.5"                 # 5 octets
  "::1"                       # IPv6 loopback
  "2001:db8::1"               # IPv6
  "192.168.1.1/24"            # CIDR notation
  "192.168.1 .1"              # space in address
  " 10.0.0.1"                 # leading space
  "10.0.0.1 "                 # trailing space
  "10.0.0"                    # three octets, no fourth
  "host.docker.internal"      # Docker alias string
  "localhost"                 # hostname
)

for ip in "${INVALID_CASES[@]}"; do
  if check_ipv4 "$ip"; then
    fail "accepted invalid value: '$ip'"
  else
    pass "rejected invalid value: '$ip'"
  fi
done

# ── Boundary octets ───────────────────────────────────────────────────────────
step "Part 1c: boundary octet values"

OCTET_BOUNDARIES=(
  "0.0.0.0:valid"
  "255.255.255.255:valid"
  "256.0.0.0:invalid"
  "0.256.0.0:invalid"
  "0.0.256.0:invalid"
  "0.0.0.256:invalid"
  "0.0.0.255:valid"
  "0.0.255.0:valid"
  "0.255.0.0:valid"
  "255.0.0.0:valid"
)

for entry in "${OCTET_BOUNDARIES[@]}"; do
  ip="${entry%%:*}"
  expected="${entry##*:}"
  if check_ipv4 "$ip"; then
    if [ "$expected" = "valid" ]; then
      pass "boundary: '$ip' accepted (expected valid)"
    else
      fail "boundary: '$ip' accepted (expected invalid)"
    fi
  else
    if [ "$expected" = "invalid" ]; then
      pass "boundary: '$ip' rejected (expected invalid)"
    else
      fail "boundary: '$ip' rejected (expected valid)"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# PART 2: SSH probe mechanics — P12 logic
#
# validate.sh P12 check calls:
#   ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
#        "$EFFECTIVE_SSH_HOST" true
# Tests here verify the probe correctly classifies reachable vs unreachable
# hosts using the same invocation.
# ══════════════════════════════════════════════════════════════════════════════

step "Part 2: SSH probe mechanics (P12 logic)"

# Helper: runs the same SSH probe as validate.sh
run_ssh_probe() {
  local host="$1"
  ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "$host" true 2>/dev/null
}

# ── Error path: non-routable / NXDOMAIN host ─────────────────────────────────
step "Part 2a: SSH probe error path — nonexistent host"

BOGUS_HOST="nonexistent-host-csd-validate-$$-xyz.invalid"
if run_ssh_probe "$BOGUS_HOST"; then
  fail "SSH probe succeeded to nonexistent host '$BOGUS_HOST' — expected failure"
else
  pass "SSH probe fails for nonexistent host '$BOGUS_HOST' (exit code: $?)"
fi

# ── Error path: port 22 refused ───────────────────────────────────────────────
step "Part 2b: SSH probe error path — port-closed address"

# 192.0.2.1 is TEST-NET-1 (RFC 5737) — not routable, connection will time out or refuse.
# Use a very short timeout to keep the test fast.
PORT_CLOSED_HOST="192.0.2.1"
PROBE_OUT=$(ssh -q -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
    "$PORT_CLOSED_HOST" true 2>/dev/null && echo "connected" || echo "refused")
if [ "$PROBE_OUT" = "connected" ]; then
  fail "SSH probe unexpectedly succeeded to TEST-NET-1 address $PORT_CLOSED_HOST"
else
  pass "SSH probe correctly fails to $PORT_CLOSED_HOST (connection refused/timed out)"
fi

# ── Success path: SSH to localhost (conditional) ──────────────────────────────
step "Part 2c: SSH probe success path — localhost (skip if no sshd)"

if ssh -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
       localhost true 2>/dev/null; then
  pass "SSH probe succeeds to localhost (sshd is running)"
else
  skip "SSH probe to localhost failed — sshd not running on this machine (test skipped)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PART 3: validate.sh integration — requires --server <alias>
#
# Runs validate.sh end-to-end with a temp coolify.yaml stub and checks that
# the P04/P07/P08/P12 error messages appear correctly. SKIPPED if --server
# was not supplied.
# ══════════════════════════════════════════════════════════════════════════════

if [ -z "$SERVER_ALIAS" ]; then
  echo ""
  echo "── Part 3: validate.sh integration — SKIPPED (no --server supplied) ──"
  echo "   Run with --server <alias> to exercise end-to-end checks."
else
  # Validate prereqs
  if [ ! -f "$VALIDATE_SH" ]; then
    echo "ERROR: validate.sh not found at $VALIDATE_SH" >&2; exit 1
  fi
  if [ ! -f "$HOME/.claude/coolify.json" ]; then
    echo "ERROR: ~/.claude/coolify.json not found" >&2; exit 1
  fi

  # Read real config state for this server alias
  REAL_DEPLOY_VPS_IP=$(python3 -c "
import json, sys
d = json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers', {}).get('$SERVER_ALIAS', {}).get('deploy_vps_ip', ''))
" 2>/dev/null || echo "")

  REAL_SSH_HOST=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers', {}).get('$SERVER_ALIAS', {}).get('ssh_host', ''))
" 2>/dev/null || echo "")

  REAL_DEPLOY_SSH_HOST=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers', {}).get('$SERVER_ALIAS', {}).get('deploy_ssh_host', ''))
" 2>/dev/null || echo "")

  echo ""
  echo "Integration config ($SERVER_ALIAS):"
  echo "  deploy_vps_ip    = ${REAL_DEPLOY_VPS_IP:-<absent>}"
  echo "  ssh_host         = ${REAL_SSH_HOST:-<absent>}"
  echo "  deploy_ssh_host  = ${REAL_DEPLOY_SSH_HOST:-<absent>}"

  # Minimal coolify.yaml fixture (no deploy_server so P04 effective-server branch runs)
  write_fixture() {
    local path="$1"
    cat > "$path" <<YAML
project: csd-validate-gap-test
server: $SERVER_ALIAS
doppler_project: claude-skills-deploy
registry:
  image: ghcr.io/example/csd-validate-gap-test
environments:
  staging:
    domain: csd-validate-gap-test-staging.example.com
    doppler_environment: stg
  production:
    domain: csd-validate-gap-test.example.com
    doppler_environment: prd
env_vars:
  - DUMMY_KEY
dns:
  provider: none
  zone_name: ""
  credential_source: doppler
  credential_key: ""
YAML
  }

  # ── P07/P08 integration: deploy_vps_ip output messages ────────────────────
  step "Part 3a: P07/P08 — deploy_vps_ip validation message (integration)"

  FIXTURE_BASE="$TMP/fixture-base.yaml"
  write_fixture "$FIXTURE_BASE"

  STDOUT_A=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>/dev/null || true)

  if [ -n "$REAL_DEPLOY_VPS_IP" ]; then
    if echo "$STDOUT_A" | grep -q "deploy_vps_ip $REAL_DEPLOY_VPS_IP (static) — format OK"; then
      pass "P07/P08: validate.sh logs 'deploy_vps_ip ... format OK' for static IP $REAL_DEPLOY_VPS_IP"
    else
      # If IP is invalid, expect a FAIL line instead
      STDERR_A=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>&1 1>/dev/null || true)
      if echo "$STDERR_A" | grep -q "INVALID:coolify.json:servers.*deploy_vps_ip"; then
        pass "P07/P08: validate.sh emits INVALID line for malformed deploy_vps_ip"
      else
        fail "P07/P08: deploy_vps_ip present ($REAL_DEPLOY_VPS_IP) but neither OK nor INVALID message found"
        echo "  stdout: $STDOUT_A" >&2
        echo "  stderr: $STDERR_A" >&2
      fi
    fi
  else
    if echo "$STDOUT_A" | grep -q "deploy_vps_ip not static — will be resolved at provision time"; then
      pass "P07/P08: validate.sh logs 'not static' when deploy_vps_ip absent"
    else
      fail "P07/P08: deploy_vps_ip absent but expected 'not static' log not found"
      echo "  stdout: $STDOUT_A" >&2
    fi
  fi

  # ── P12 integration: SSH probe message present ─────────────────────────────
  step "Part 3b: P12 — SSH probe log or error present (integration)"

  EFFECTIVE_SSH="${REAL_DEPLOY_SSH_HOST:-$REAL_SSH_HOST}"
  if [ -z "$EFFECTIVE_SSH" ]; then
    skip "P12: no ssh_host or deploy_ssh_host configured — probe check skipped by validate.sh"
  else
    STDOUT_B=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>/dev/null || true)
    STDERR_B=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>&1 1>/dev/null || true)

    if echo "$STDOUT_B" | grep -q "validate: SSH probe to '$EFFECTIVE_SSH' OK"; then
      pass "P12: validate.sh logs SSH probe OK for '$EFFECTIVE_SSH'"
    elif echo "$STDERR_B" | grep -q "INVALID:ssh:$EFFECTIVE_SSH"; then
      pass "P12: validate.sh emits SSH INVALID error for unreachable '$EFFECTIVE_SSH'"
    else
      fail "P12: neither SSH OK nor SSH INVALID message found for '$EFFECTIVE_SSH'"
      echo "  stdout: $STDOUT_B" >&2
      echo "  stderr: $STDERR_B" >&2
    fi
  fi

  # ── P04 integration: effective server check log present ───────────────────
  step "Part 3c: P04 — effective server check log (no deploy_server in fixture)"

  STDOUT_C=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>/dev/null || true)
  STDERR_C=$(bash "$VALIDATE_SH" "$FIXTURE_BASE" 2>&1 1>/dev/null || true)

  if echo "$STDOUT_C" | grep -q "validate: effective Coolify server"; then
    pass "P04: validate.sh runs effective-server lookup (log line present)"
  elif echo "$STDERR_C" | grep -q "INVALID:coolify.json:server_name"; then
    pass "P04: validate.sh emits INVALID for effective server not found in Coolify"
  else
    # Could also fail at the deploy_ssh_host coupling check before reaching P04
    if echo "$STDERR_C" | grep -q "deploy_ssh_host"; then
      skip "P04: validate.sh failed at deploy_ssh_host coupling check before P04 — effective server path not reached"
    else
      fail "P04: neither effective-server OK nor INVALID message found in output"
      echo "  stdout: $STDOUT_C" >&2
      echo "  stderr: $STDERR_C" >&2
    fi
  fi

fi  # end Part 3 (--server block)

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "RESULT: validate-provision-gaps FAILED — see failures above" >&2
  exit 1
fi

echo ""
echo "RESULT: validate-provision-gaps PASSED ($PASS checks, $SKIP skipped)"
exit 0
