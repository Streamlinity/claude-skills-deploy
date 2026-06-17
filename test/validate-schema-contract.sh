#!/usr/bin/env bash
# validate-schema-contract.sh — Offline contract tests for Phase 999.1 validate.sh changes.
# Tests: V1 (doppler_token Tier 1), V2 (cloudflare Tier 2), V3 (baseline exits 0),
#        V3.5 (deploy_server+missing deploy_ssh_host MSRV-07), V4 (env_vars grep scan WARN),
#        V5 (hook called), V6 (hook failure propagated).
# Runs fully offline — no live Coolify, Doppler, or SSH calls required.
# Usage: bash test/validate-schema-contract.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SH="$REPO_ROOT/scripts/validate.sh"

# ── helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }
step() { echo ""; echo "── $* ──"; }

# ── temp dir + cleanup ────────────────────────────────────────────────────────
TMP=$(mktemp -d -t csd-contract-XXXX)
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ── Stub directory — intercepts curl, ssh, doppler ───────────────────────────
mkdir -p "$TMP/bin"

# curl stub: return plausible Coolify API responses based on the URL path
cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
# Minimal curl stub for validate.sh offline tests.
# Detects /projects, /servers, /applications calls; returns fixture JSON.
URL=""
_skip_next=false
for _arg in "$@"; do
  if $_skip_next; then _skip_next=false; continue; fi
  case "$_arg" in
    -s|-f|-L|-S|--fail|--silent|-k|--insecure) ;;
    -X|-H|-d|--data|--data-binary|-o|--connect-timeout|--max-time|-w) _skip_next=true ;;
    http*) URL="$_arg" ;;
  esac
done
case "$URL" in
  */api/v1/projects*)
    echo '[{"name":"csd-test","uuid":"proj-test-uuid-001"}]'
    ;;
  */api/v1/servers*)
    echo '[{"name":"localhost","uuid":"srv-test-uuid-001"},{"name":"extra-server","uuid":"srv-test-uuid-002"}]'
    ;;
  */api/v1/applications/*/envs*)
    echo '{"data":[]}'
    ;;
  *)
    echo '[]'
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

# ssh stub: always exit 0 (SSH probe in validate.sh uses BatchMode=yes)
cat > "$TMP/bin/ssh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/ssh"

# doppler stub: handle doppler_check_key and doppler_load_account calls
cat > "$TMP/bin/doppler" << 'STUB'
#!/usr/bin/env bash
# doppler_check_key calls: doppler secrets get --project P --config C KEY --plain
# doppler_load_account calls doppler whoami or configure get
_cmd="${1:-}"
_sub="${2:-}"
case "$_cmd" in
  secrets)
    case "$_sub" in
      get)
        echo "test-value-from-stub"
        exit 0
        ;;
      download)
        echo ""
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  whoami|configure)
    echo "test-account"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$TMP/bin/doppler"

# Prepend stub bin to PATH for all test invocations
STUB_PATH="$TMP/bin:$PATH"

# ── Fixture writers ───────────────────────────────────────────────────────────

# Write a minimal valid coolify.yaml to $1 (no dns block, no deploy_server)
write_yaml_minimal() {
  local path="$1"
  cat > "$path" << 'YAML'
project: csd-test
server: test-server
doppler_project: csd-test
registry:
  image: ghcr.io/test-org/csd-test
environments:
  staging:
    domain: staging.example.com
    doppler_environment: stg
  production:
    domain: prod.example.com
    doppler_environment: prd
env_vars:
- TEST_KEY
YAML
}

# Write a Tier 1-complete coolify.json to $home_dir/.claude/coolify.json
write_json_tier1_complete() {
  local home_dir="$1"
  mkdir -p "$home_dir/.claude"
  cat > "$home_dir/.claude/coolify.json" << 'JSON'
{
  "servers": {
    "test-server": {
      "url": "https://coolify.example.com",
      "api_key": "test_api_key",
      "doppler_account": "test-account",
      "ssh_host": "test-host",
      "doppler_token": "dp.st.test_token_value"
    }
  }
}
JSON
}

# ══════════════════════════════════════════════════════════════════════════════
# V1: doppler_token absent → hard fail
# ══════════════════════════════════════════════════════════════════════════════
step "V1: doppler_token absent from coolify.json → hard fail"

V1_HOME=$(mktemp -d "$TMP/v1-XXXX")
mkdir -p "$V1_HOME/.claude"
write_yaml_minimal "$V1_HOME/coolify.yaml"

# coolify.json WITHOUT doppler_token
cat > "$V1_HOME/.claude/coolify.json" << 'JSON'
{
  "servers": {
    "test-server": {
      "url": "https://coolify.example.com",
      "api_key": "test_api_key",
      "doppler_account": "test-account",
      "ssh_host": "test-host"
    }
  }
}
JSON

V1_EC=0
V1_OUT=$(env PATH="$STUB_PATH" HOME="$V1_HOME" \
  COOLIFY_REGISTRY="$V1_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V1_HOME/coolify.yaml" 2>&1) || V1_EC=$?

if [ "$V1_EC" -ne 0 ]; then
  pass "V1: exit code is non-zero ($V1_EC) when doppler_token missing"
else
  fail "V1: expected non-zero exit, got 0"
fi

if echo "$V1_OUT" | grep -qi "doppler_token"; then
  pass "V1: output mentions doppler_token"
else
  fail "V1: output does not mention 'doppler_token'"
  echo "  output: $V1_OUT" >&2
fi

if echo "$V1_OUT" | grep -qiE "FAIL|INVALID|ERROR|missing"; then
  pass "V1: output contains failure indicator"
else
  fail "V1: output lacks FAIL/INVALID/ERROR/missing"
  echo "  output: $V1_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# V2: cloudflare_api_token absent when dns.credential_source: coolify_json
# ══════════════════════════════════════════════════════════════════════════════
step "V2: cloudflare_api_token absent with dns.credential_source=coolify_json → hard fail"

V2_HOME=$(mktemp -d "$TMP/v2-XXXX")
mkdir -p "$V2_HOME/.claude"

# coolify.yaml WITH dns block requiring coolify_json credential
cat > "$V2_HOME/coolify.yaml" << 'YAML'
project: csd-test
server: test-server
doppler_project: csd-test
registry:
  image: ghcr.io/test-org/csd-test
environments:
  staging:
    domain: staging.test.example.com
    doppler_environment: stg
  production:
    domain: prod.test.example.com
    doppler_environment: prd
env_vars:
- TEST_KEY
dns:
  provider: cloudflare
  zone_name: example.com
  credential_source: coolify_json
  credential_key: cloudflare_api_token
YAML

# coolify.json with Tier 1 complete but NO cloudflare_api_token
cat > "$V2_HOME/.claude/coolify.json" << 'JSON'
{
  "servers": {
    "test-server": {
      "url": "https://coolify.example.com",
      "api_key": "test_api_key",
      "doppler_account": "test-account",
      "ssh_host": "test-host",
      "doppler_token": "dp.st.test_token_value"
    }
  }
}
JSON

V2_EC=0
V2_OUT=$(env PATH="$STUB_PATH" HOME="$V2_HOME" \
  COOLIFY_REGISTRY="$V2_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V2_HOME/coolify.yaml" 2>&1) || V2_EC=$?

if [ "$V2_EC" -ne 0 ]; then
  pass "V2: exit code is non-zero ($V2_EC) when cloudflare_api_token missing"
else
  fail "V2: expected non-zero exit, got 0"
fi

if echo "$V2_OUT" | grep -qi "cloudflare_api_token"; then
  pass "V2: output mentions cloudflare_api_token"
else
  fail "V2: output does not mention 'cloudflare_api_token'"
  echo "  output: $V2_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# V3: all Tier 1 fields present → baseline exits 0
# ══════════════════════════════════════════════════════════════════════════════
step "V3: all Tier 1 fields present, no dns block → baseline exits 0"

V3_HOME=$(mktemp -d "$TMP/v3-XXXX")
write_json_tier1_complete "$V3_HOME"
write_yaml_minimal "$V3_HOME/coolify.yaml"

V3_EC=0
V3_OUT=$(env PATH="$STUB_PATH" HOME="$V3_HOME" \
  COOLIFY_REGISTRY="$V3_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V3_HOME/coolify.yaml" 2>&1) || V3_EC=$?

if [ "$V3_EC" -eq 0 ]; then
  pass "V3: exit code is 0 with all Tier 1 fields present"
else
  fail "V3: expected exit 0, got $V3_EC"
  echo "  output: $V3_OUT" >&2
fi

if echo "$V3_OUT" | grep -qiE "FAIL.*doppler_token|doppler_token.*FAIL"; then
  fail "V3: output contains FAIL for doppler_token (should not)"
else
  pass "V3: no FAIL for doppler_token in output"
fi

# ══════════════════════════════════════════════════════════════════════════════
# V3.5: deploy_server set + deploy_ssh_host absent → hard fail (MSRV-07)
# ══════════════════════════════════════════════════════════════════════════════
step "V3.5: deploy_server set but deploy_ssh_host absent in coolify.json → hard fail (MSRV-07)"

V35_HOME=$(mktemp -d "$TMP/v35-XXXX")
# Tier 1 complete but NO deploy_ssh_host
write_json_tier1_complete "$V35_HOME"

# coolify.yaml WITH deploy_server referencing the extra-server stub returns
cat > "$V35_HOME/coolify.yaml" << 'YAML'
project: csd-test
server: test-server
doppler_project: csd-test
deploy_server: extra-server
registry:
  image: ghcr.io/test-org/csd-test
environments:
  staging:
    domain: staging.example.com
    doppler_environment: stg
  production:
    domain: prod.example.com
    doppler_environment: prd
env_vars:
- TEST_KEY
YAML

V35_EC=0
V35_OUT=$(env PATH="$STUB_PATH" HOME="$V35_HOME" \
  COOLIFY_REGISTRY="$V35_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V35_HOME/coolify.yaml" 2>&1) || V35_EC=$?

if [ "$V35_EC" -ne 0 ]; then
  pass "V3.5: exit code is non-zero ($V35_EC) when deploy_server set but deploy_ssh_host absent"
else
  fail "V3.5: expected non-zero exit, got 0"
  echo "  output: $V35_OUT" >&2
fi

if echo "$V35_OUT" | grep -qi "deploy_ssh_host"; then
  pass "V3.5: output mentions deploy_ssh_host"
else
  fail "V3.5: output does not mention 'deploy_ssh_host'"
  echo "  output: $V35_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# V4: env_vars grep scan → WARN for stale key not found in codebase
# ══════════════════════════════════════════════════════════════════════════════
step "V4: env_vars grep scan → WARN for key not found in codebase"

V4_HOME=$(mktemp -d "$TMP/v4-XXXX")
write_json_tier1_complete "$V4_HOME"

# Write to a project directory with .git so the grep scan activates
mkdir -p "$V4_HOME/project/.git"

cat > "$V4_HOME/project/coolify.yaml" << 'YAML'
project: csd-test
server: test-server
doppler_project: csd-test
registry:
  image: ghcr.io/test-org/csd-test
environments:
  staging:
    domain: staging.example.com
    doppler_environment: stg
  production:
    domain: prod.example.com
    doppler_environment: prd
env_vars:
- STALE_KEY_NOBODY_USES
YAML

V4_EC=0
V4_OUT=$(env PATH="$STUB_PATH" HOME="$V4_HOME" \
  COOLIFY_REGISTRY="$V4_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V4_HOME/project/coolify.yaml" 2>&1) || V4_EC=0

if echo "$V4_OUT" | grep -qiE "WARN|stale"; then
  pass "V4: output contains WARN or stale for undeclared key"
else
  fail "V4: expected WARN/stale in output for missing-in-codebase key"
  echo "  output: $V4_OUT" >&2
fi

if echo "$V4_OUT" | grep -q "STALE_KEY_NOBODY_USES"; then
  pass "V4: output names the stale key STALE_KEY_NOBODY_USES"
else
  fail "V4: output does not name 'STALE_KEY_NOBODY_USES'"
  echo "  output: $V4_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# V5: .coolify/validate.sh hook called when present and exits 0
# ══════════════════════════════════════════════════════════════════════════════
step "V5: .coolify/validate.sh hook called when present (hook exits 0)"

V5_HOME=$(mktemp -d "$TMP/v5-XXXX")
write_json_tier1_complete "$V5_HOME"
mkdir -p "$V5_HOME/project/.coolify"
write_yaml_minimal "$V5_HOME/project/coolify.yaml"

cat > "$V5_HOME/project/.coolify/validate.sh" << 'HOOK'
#!/usr/bin/env bash
echo "hook called"
exit 0
HOOK
chmod +x "$V5_HOME/project/.coolify/validate.sh"

V5_EC=0
V5_OUT=$(env PATH="$STUB_PATH" HOME="$V5_HOME" \
  COOLIFY_REGISTRY="$V5_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V5_HOME/project/coolify.yaml" 2>&1) || V5_EC=$?

if echo "$V5_OUT" | grep -q "hook called"; then
  pass "V5: hook output 'hook called' found — hook was invoked"
else
  fail "V5: hook was not called (expected 'hook called' in output)"
  echo "  output: $V5_OUT" >&2
fi

if [ "$V5_EC" -eq 0 ]; then
  pass "V5: exit code 0 when hook exits 0"
else
  fail "V5: expected exit 0 when hook exits 0, got $V5_EC"
  echo "  output: $V5_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# V6: .coolify/validate.sh hook exits 1 → validate.sh exits 1
# ══════════════════════════════════════════════════════════════════════════════
step "V6: .coolify/validate.sh hook exits 1 → validate.sh propagates failure"

V6_HOME=$(mktemp -d "$TMP/v6-XXXX")
write_json_tier1_complete "$V6_HOME"
mkdir -p "$V6_HOME/project/.coolify"
write_yaml_minimal "$V6_HOME/project/coolify.yaml"

cat > "$V6_HOME/project/.coolify/validate.sh" << 'HOOK'
#!/usr/bin/env bash
echo "hook: repo-specific check failed"
exit 1
HOOK
chmod +x "$V6_HOME/project/.coolify/validate.sh"

V6_EC=0
V6_OUT=$(env PATH="$STUB_PATH" HOME="$V6_HOME" \
  COOLIFY_REGISTRY="$V6_HOME/.claude/coolify.json" \
  bash "$VALIDATE_SH" "$V6_HOME/project/coolify.yaml" 2>&1) || V6_EC=$?

if [ "$V6_EC" -ne 0 ]; then
  pass "V6: exit code is non-zero ($V6_EC) when hook exits 1"
else
  fail "V6: expected non-zero exit when hook fails, got 0"
fi

if echo "$V6_OUT" | grep -qiE "FAIL|hook|INVALID"; then
  pass "V6: output contains failure indicator for hook failure"
else
  fail "V6: output does not mention FAIL/hook/INVALID"
  echo "  output: $V6_OUT" >&2
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo "  Results: PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
