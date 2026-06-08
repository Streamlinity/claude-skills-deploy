#!/usr/bin/env bash
# validate-dns-ip-filter.sh — Regression test for MSRV-05 private/loopback IP filtering.
#
# provision.sh (MSRV-05) resolves DEPLOY_VPS_IP for DNS A records. When a
# separately-registered Coolify server has a private IP (NAT, private network),
# the Coolify API GET /servers/{uuid}.ip returns that private IP. Using it for
# public DNS would create unreachable A records.
#
# This test asserts that the embedded Python filter in provision.sh rejects
# RFC1918 / reserved / loopback / CGN / link-local IPs from the Coolify API
# and only permits globally-routable addresses.
#
# Run standalone:
#   bash test/validate-dns-ip-filter.sh

set -euo pipefail

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }
step() { echo ""; echo "── $* ──"; }

# The exact Python filter logic from provision.sh (MSRV-05 Step 2).
# Given an IP string on stdin, it echoes the IP if it passes the filter,
# or outputs nothing if the IP is rejected.
run_filter() {
  local ip="$1"
  python3 -c "
import sys,ipaddress
ip = '$ip'
if ip and ip != 'host.docker.internal':
    try:
        addr = ipaddress.ip_address(ip)
        if addr.is_global:
            print(ip)
    except ValueError:
        pass
" 2>/dev/null
}

step "Test: accepted public addresses"

PUBLIC_IPS=(
  "8.8.8.8"
  "1.1.1.1"
  "149.248.4.46"
)

for ip in "${PUBLIC_IPS[@]}"; do
  result=$(run_filter "$ip")
  if [ "$result" = "$ip" ]; then
    pass "accepts $ip (public)"
  else
    fail "rejected $ip — should accept public addresses"
  fi
done

step "Test: rejected addresses (RFC1918 / reserved / loopback / link-local / CGN)"

REJECTED_IPS=(
  "10.0.0.5"
  "10.255.255.255"
  "172.16.0.1"
  "172.31.255.255"
  "192.168.0.100"
  "192.168.255.255"
  "169.254.1.1"
  "127.0.0.1"
  "127.0.0.53"
  "0.0.0.0"
  "203.0.113.42"           # TEST-NET-3
  "198.51.100.1"           # TEST-NET-2
  "100.64.5.5"             # Shared Address Space (CGN)
  "host.docker.internal"   # Docker internal alias
  ""                       # empty
  "invalid"                # not an IP
  "256.0.0.1"             # invalid octet
)

for ip in "${REJECTED_IPS[@]}"; do
  result=$(run_filter "$ip")
  if [ -z "$result" ]; then
    pass "rejects '$ip'"
  else
    fail "accepted '$ip' — should reject it"
  fi
done

step "Test: IPv6 public addresses are accepted by the filter (downstream IPv4 regex rejects them)"

IPV6_PUBLIC=(
  "2607:f8b0:4005:80a::200e"
  "2606:4700:4700::1111"
  "::ffff:8.8.8.8"
)

for ip in "${IPV6_PUBLIC[@]}"; do
  result=$(run_filter "$ip")
  if [ -n "$result" ]; then
    pass "filter accepts '$ip' (IPv6 — downstream IPv4 regex will reject it)"
  else
    fail "rejected '$ip' — filter should accept it (IPv4 regex handles downstream)"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "RESULT: validate-dns-ip-filter FAILED" >&2
  exit 1
fi

echo ""
echo "RESULT: validate-dns-ip-filter PASSED ($PASS checks)"
exit 0
