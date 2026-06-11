#!/usr/bin/env bash
# test-lib-coolify-api.sh — Fixture-driven unit tests for lib-coolify-api.sh JSON parsing.
#
# Usage: bash test/test-lib-coolify-api.sh
#
# Runs fully offline — coolify_curl is stubbed to emit canned JSON fixtures, so
# no Coolify instance, credentials, or network access is needed. Exercises the
# response-shape variants Coolify is known to return (bare list vs {data:[...]}),
# plus not-found, empty-list, and invalid-JSON inputs.
#
# Exit 0: all tests pass. Exit 1: at least one failure (all failures printed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SKILL_DIR/scripts/lib-coolify-api.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

# ── coolify_curl stub ──────────────────────────────────────────────────────────
# Each test sets FIXTURE_* variables; the stub returns them by API path so
# multi-endpoint functions (coolify_get_destination_uuid) get distinct fixtures.

FIXTURE_DEFAULT=""
FIXTURE_APPLICATIONS=""
FIXTURE_DESTINATIONS=""

coolify_curl() {
  local method="$1" path="$2"
  case "$path" in
    /applications) printf '%s' "$FIXTURE_APPLICATIONS" ;;
    /destinations) printf '%s' "$FIXTURE_DESTINATIONS" ;;
    *)             printf '%s' "$FIXTURE_DEFAULT" ;;
  esac
}

# assert_eq <test-name> <expected> <actual>
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

echo "=== coolify_get_project_uuid ==="

FIXTURE_DEFAULT='[{"name":"alpha","uuid":"uuid-a"},{"name":"beta","uuid":"uuid-b"}]'
assert_eq "bare list, name found"      "uuid-b" "$(coolify_get_project_uuid beta)"
assert_eq "bare list, name not found"  ""       "$(coolify_get_project_uuid gamma)"

FIXTURE_DEFAULT='{"data":[{"name":"alpha","uuid":"uuid-a"}]}'
assert_eq "{data:[...]} wrapper, found" "uuid-a" "$(coolify_get_project_uuid alpha)"

FIXTURE_DEFAULT='[]'
assert_eq "empty list -> empty output"  ""       "$(coolify_get_project_uuid alpha)"

FIXTURE_DEFAULT='[{"uuid":"uuid-x"}]'
assert_eq "item missing name field"     ""       "$(coolify_get_project_uuid alpha)"

# Invalid JSON must fail loudly (non-zero), NOT return empty — empty means
# "not found" to callers and would trigger a duplicate create.
FIXTURE_DEFAULT='not json at all'
if coolify_get_project_uuid alpha >/dev/null 2>&1; then
  fail "invalid JSON should exit non-zero"
else
  pass "invalid JSON exits non-zero (fail-loud, no silent empty)"
fi

echo "=== coolify_get_server_uuid ==="

FIXTURE_DEFAULT='[{"name":"localhost","uuid":"srv-1"},{"name":"worker","uuid":"srv-2"}]'
assert_eq "bare list, name found"       "srv-1" "$(coolify_get_server_uuid localhost)"
assert_eq "bare list, name not found"   ""      "$(coolify_get_server_uuid missing)"

FIXTURE_DEFAULT='{"data":[{"name":"worker","uuid":"srv-2"}]}'
assert_eq "{data:[...]} wrapper, found" "srv-2" "$(coolify_get_server_uuid worker)"

# Name containing quotes must not break parsing (injection-regression guard)
FIXTURE_DEFAULT='[{"name":"it'\''s \"quoted\"","uuid":"srv-q"}]'
assert_eq "name with quotes"            "srv-q" "$(coolify_get_server_uuid "it's \"quoted\"")"

echo "=== coolify_find_app_by_name ==="

FIXTURE_APPLICATIONS='[{"name":"app-staging","uuid":"app-1"},{"name":"app-production","uuid":"app-2"}]'
assert_eq "bare list, name found"       "app-2" "$(coolify_find_app_by_name app-production)"
assert_eq "bare list, name not found"   ""      "$(coolify_find_app_by_name nope)"

FIXTURE_APPLICATIONS='{"data":[{"name":"app-staging","uuid":"app-1"}]}'
assert_eq "{data:[...]} wrapper, found" "app-1" "$(coolify_find_app_by_name app-staging)"

echo "=== coolify_get_destination_uuid ==="

# Strategy 1: match destination.server.uuid across existing apps
FIXTURE_APPLICATIONS='[{"name":"x","destination":{"uuid":"dest-1","server":{"uuid":"srv-1"}}}]'
FIXTURE_DESTINATIONS=''
assert_eq "strategy 1: matched via app destination" "dest-1" "$(coolify_get_destination_uuid srv-1 || true)"

# Strategy 2: /applications has no match -> falls through to /destinations
FIXTURE_APPLICATIONS='[]'
FIXTURE_DESTINATIONS='[{"uuid":"dest-2","server":{"uuid":"srv-2"}}]'
assert_eq "strategy 2: matched via /destinations"   "dest-2" "$(coolify_get_destination_uuid srv-2 || true)"

# Strategy 2 alternate field: server_uuid at top level
FIXTURE_DESTINATIONS='[{"uuid":"dest-3","server_uuid":"srv-3"}]'
assert_eq "strategy 2: matched via server_uuid field" "dest-3" "$(coolify_get_destination_uuid srv-3 || true)"

# Strategy 3: no match anywhere -> empty (Coolify auto-assigns at create)
FIXTURE_APPLICATIONS='[]'
FIXTURE_DESTINATIONS='[]'
assert_eq "strategy 3: no match -> empty"           ""       "$(coolify_get_destination_uuid srv-x || true)"

# Malformed JSON in both endpoints must degrade to empty, not crash
# (this function has try/except by design — empty triggers auto-assign)
FIXTURE_APPLICATIONS='garbage'
FIXTURE_DESTINATIONS='garbage'
assert_eq "invalid JSON degrades to empty"          ""       "$(coolify_get_destination_uuid srv-x || true)"

echo "=== coolify_deploy_app ==="

FIXTURE_DEFAULT='{"deployments":[{"deployment_uuid":"dep-123"}]}'
assert_eq "deployment uuid extracted"   "dep-123" "$(coolify_deploy_app app-1)"

FIXTURE_DEFAULT='{"deployments":[]}'
assert_eq "empty deployments -> empty"  ""        "$(coolify_deploy_app app-1)"

FIXTURE_DEFAULT='not json'
assert_eq "invalid JSON degrades to empty" ""     "$(coolify_deploy_app app-1)"

echo "=== coolify_get_github_app_uuid ==="

FIXTURE_DEFAULT='[{"type":"github_app","uuid":"gh-1"}]'
assert_eq "bare list, type matched"     "gh-1"  "$(coolify_get_github_app_uuid)"

FIXTURE_DEFAULT='{"data":[{"name":"My GitHub Source","uuid":"gh-2"}]}'
assert_eq "{data:[...]}, name matched"  "gh-2"  "$(coolify_get_github_app_uuid)"

FIXTURE_DEFAULT='[]'
assert_eq "no sources -> empty"         ""      "$(coolify_get_github_app_uuid)"

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo " lib-coolify-api unit tests"
echo "═══════════════════════════════════"
echo "  Passed: $PASS  Failed: $FAIL"
echo "═══════════════════════════════════"

[ "$FAIL" -eq 0 ]
