#!/usr/bin/env bash
# test_init.sh — Behavior tests for init/init.sh
# Run from: anywhere (uses absolute paths)
# Tests: idempotency, YAML validity, token substitution, defaults, env_vars format, deploy.yml generation

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SH="$SKILL_DIR/init/init.sh"
PASS=0
FAIL=0
ERRORS=()

run_test() {
  local name="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $name"
    ((PASS++))
  else
    echo "FAIL: $name"
    ((FAIL++))
    ERRORS+=("$name")
  fi
}

# ─── Test 1: Idempotency guard — refuses to overwrite existing coolify.yaml ───
T1_DIR=$(mktemp -d)
touch "$T1_DIR/coolify.yaml"
if (cd "$T1_DIR" && bash "$INIT_SH" > /dev/null 2>&1); then
  run_test "Test 1: coolify.yaml idempotency guard exits non-zero" "1"
else
  run_test "Test 1: coolify.yaml idempotency guard exits non-zero" "0"
fi
rm -rf "$T1_DIR"

# ─── Test 2: Piped input produces valid coolify.yaml ───
T2_DIR=$(mktemp -d)
(
  cd "$T2_DIR" || exit 1
  printf 'testproj\nvultr-stream\n\n\nghcr.io/org/test\ntest-staging.example.com\ntest.example.com\nnone\n\n\nDATABASE_URL OPENAI_API_KEY\n' \
    | bash "$INIT_SH" > /dev/null 2>&1
)
if python3 -c "import yaml; yaml.safe_load(open('$T2_DIR/coolify.yaml'))" 2>/dev/null; then
  run_test "Test 2: piped input produces valid YAML coolify.yaml" "0"
else
  run_test "Test 2: piped input produces valid YAML coolify.yaml" "1"
fi
rm -rf "$T2_DIR"

# ─── Test 3: No unsubstituted {{ tokens remain ───
T3_DIR=$(mktemp -d)
(
  cd "$T3_DIR" || exit 1
  printf 'testproj\nvultr-stream\n\n\nghcr.io/org/test\ntest-staging.example.com\ntest.example.com\nnone\n\n\nDATABASE_URL\n' \
    | bash "$INIT_SH" > /dev/null 2>&1
)
if [ -f "$T3_DIR/coolify.yaml" ] && ! grep -q '{{' "$T3_DIR/coolify.yaml"; then
  run_test "Test 3: no unsubstituted {{ tokens remain" "0"
else
  run_test "Test 3: no unsubstituted {{ tokens remain" "1"
fi
rm -rf "$T3_DIR"

# ─── Test 4: build.context defaults to '.' and build.dockerfile defaults to './Dockerfile' ───
T4_DIR=$(mktemp -d)
(
  cd "$T4_DIR" || exit 1
  # Accept defaults for build.context and build.dockerfile (press Enter twice)
  printf 'testproj\nvultr-stream\n\n\nghcr.io/org/test\ntest-staging.example.com\ntest.example.com\nnone\n\n\nDATABASE_URL\n' \
    | bash "$INIT_SH" > /dev/null 2>&1
)
if python3 -c "
import yaml
d = yaml.safe_load(open('$T4_DIR/coolify.yaml'))
assert d.get('build', {}).get('context') == '.', f'context={d.get(\"build\",{}).get(\"context\")}'
assert d.get('build', {}).get('dockerfile') == './Dockerfile', f'dockerfile={d.get(\"build\",{}).get(\"dockerfile\")}'
print('defaults OK')
" 2>/dev/null; then
  run_test "Test 4: build.context='.', build.dockerfile='./Dockerfile' defaults" "0"
else
  run_test "Test 4: build.context='.', build.dockerfile='./Dockerfile' defaults" "1"
fi
rm -rf "$T4_DIR"

# ─── Test 5: env_vars produces proper YAML list ───
T5_DIR=$(mktemp -d)
(
  cd "$T5_DIR" || exit 1
  printf 'testproj\nvultr-stream\n\n\nghcr.io/org/test\ntest-staging.example.com\ntest.example.com\nnone\n\n\nDATABASE_URL ANTHROPIC_API_KEY\n' \
    | bash "$INIT_SH" > /dev/null 2>&1
)
if python3 -c "
import yaml
d = yaml.safe_load(open('$T5_DIR/coolify.yaml'))
ev = d.get('env_vars', [])
assert 'DATABASE_URL' in ev, f'DATABASE_URL missing from {ev}'
assert 'ANTHROPIC_API_KEY' in ev, f'ANTHROPIC_API_KEY missing from {ev}'
print('env_vars OK')
" 2>/dev/null; then
  run_test "Test 5: env_vars produces YAML list with DATABASE_URL and ANTHROPIC_API_KEY" "0"
else
  run_test "Test 5: env_vars produces YAML list with DATABASE_URL and ANTHROPIC_API_KEY" "1"
fi
rm -rf "$T5_DIR"

# ─── Test 6: init.sh also produces .github/workflows/deploy.yml ───
T6_DIR=$(mktemp -d)
(
  cd "$T6_DIR" || exit 1
  printf 'testproj\nvultr-stream\n\n\nghcr.io/org/test\ntest-staging.example.com\ntest.example.com\nnone\n\n\nDATABASE_URL\n' \
    | bash "$INIT_SH" > /dev/null 2>&1
)
if [ -f "$T6_DIR/.github/workflows/deploy.yml" ] && python3 -c "import yaml; yaml.safe_load(open('$T6_DIR/.github/workflows/deploy.yml'))" 2>/dev/null; then
  run_test "Test 6: .github/workflows/deploy.yml exists and is valid YAML" "0"
else
  run_test "Test 6: .github/workflows/deploy.yml exists and is valid YAML" "1"
fi
rm -rf "$T6_DIR"

# ─── Test 7: deploy.yml idempotency — refuses to overwrite existing deploy.yml ───
T7_DIR=$(mktemp -d)
mkdir -p "$T7_DIR/.github/workflows"
touch "$T7_DIR/.github/workflows/deploy.yml"
(
  cd "$T7_DIR" || exit 1
  bash "$INIT_SH" > /dev/null 2>&1
) && run_test "Test 7: deploy.yml idempotency guard exits non-zero" "1" || run_test "Test 7: deploy.yml idempotency guard exits non-zero" "0"
rm -rf "$T7_DIR"

# ─── Summary ───
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do echo "  - $e"; done
fi

[ "$FAIL" -eq 0 ] || exit 1
