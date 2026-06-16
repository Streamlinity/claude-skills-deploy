#!/usr/bin/env bash
# validate-workflow-contract.sh — Assert the generated deploy.yml matches the
# Coolify API sequence that test/e2e.sh has proven works against live Coolify.
#
# Usage: bash test/validate-workflow-contract.sh
#
# Runs fully offline — generates a workflow from a fixture coolify.yaml (with
# provisioned UUIDs and a fixture coolify.json via COOLIFY_REGISTRY) and checks
# the contract, not just YAML validity. Catches drift between the workflow
# generator and the proven deploy sequence, e.g. the ':main' vs SHA tag
# mismatch (Fable review 1.7) or a renamed PATCH field.
#
# The contract (each assertion mirrors a step e2e.sh executes live):
#   C1  build tags the image with the commit short SHA (same-image promotion)
#   C2  staging PATCHes docker_registry_image_tag — the exact field e2e.sh
#       PATCHes before triggering a deploy
#   C3  staging deploys via /api/v1/deploy?uuid=<staging>&force=false — the
#       exact endpoint+param coolify_deploy_app uses
#   C4  smoke test hits the staging domain at health_check_path from coolify.yaml
#   C5  deploy-production is gated on deploy-staging (needs:)
#   C6  production PATCHes the SAME tag source (needs.build.outputs.tag) —
#       byte-identical image promotion, no rebuild
#   C7  production deploys via /api/v1/deploy?uuid=<production>&force=false
#   C8  no REPLACE_WITH_* placeholders survive when UUIDs are provisioned
#   C9  no build-args (env-specific build-args break same-image promotion)
#   C10 structural validity (delegates to validate-workflow.sh)
#
# Exit 0: all contract checks pass. Exit 1: at least one failed (all printed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

WORK_DIR=$(mktemp -d /tmp/csd-workflow-contract-XXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Fixtures ───────────────────────────────────────────────────────────────────
# Non-default health_check_path (/healthz) proves the path is threaded from
# coolify.yaml into the smoke test, not hardcoded (Fable review 3.3).

STG_UUID="fixturestguuid0000000001"
PRD_UUID="fixtureprduuid0000000002"

cat > "$WORK_DIR/coolify.yaml" << EOF
project: contract-test
server: fixture-server
doppler_project: contract-test
registry:
  image: ghcr.io/fixture-org/contract-app:latest
  retention_tags: 7
build:
  context: ./app
  dockerfile: ./app/Dockerfile
environments:
  staging:
    domain: contract-staging.ci.example.com
    doppler_environment: stg
  production:
    domain: contract.ci.example.com
    doppler_environment: prd
env_vars:
  - HELLO
health_check_path: /healthz
coolify_app_ids:
  staging: $STG_UUID
  production: $PRD_UUID
EOF

cat > "$WORK_DIR/coolify.json" << 'EOF'
{"servers":{"fixture-server":{"url":"https://coolify.fixture.example.com","api_key":"fixture-key","doppler_account":"fixture","ssh_host":"fixture-host"}}}
EOF
chmod 600 "$WORK_DIR/coolify.json"

# ── Generate ───────────────────────────────────────────────────────────────────

COOLIFY_REGISTRY="$WORK_DIR/coolify.json" \
  bash "$SKILL_DIR/scripts/generate-workflow.sh" "$WORK_DIR/coolify.yaml" >/dev/null

WF="$WORK_DIR/.github/workflows/deploy.yml"
[ -f "$WF" ] || { echo "FATAL: workflow not generated at $WF" >&2; exit 1; }

echo "=== Workflow contract checks (vs e2e.sh proven sequence) ==="

# C1 — build pushes exactly name:short_sha. The :latest in the fixture's
# registry.image must be stripped — name:latest:sha is an invalid Docker
# reference that breaks the build silently at CI time.
if grep -qE 'tags: ghcr\.io/fixture-org/contract-app:\$\{\{ steps\.tag\.outputs\.short_sha \}\}' "$WF"; then
  pass "C1: build tags image with commit short SHA"
else
  fail "C1: build does not tag with name:short_sha"
fi
if grep -qE 'tags:.*contract-app:(latest|main):' "$WF"; then
  fail "C1b: double tag in build push (registry.image tag not stripped)"
else
  pass "C1b: no double/fixed tag in build push"
fi

# C2 — staging PATCHes docker_registry_image_tag (field e2e.sh PATCHes live)
if grep -qE 'PATCH "\$COOLIFY_URL/api/v1/applications/\$STAGING_APP_UUID"' "$WF" \
   && grep -q 'docker_registry_image_tag' "$WF"; then
  pass "C2: staging PATCH sets docker_registry_image_tag"
else
  fail "C2: staging PATCH of docker_registry_image_tag missing"
fi

# C3 — staging deploy endpoint matches coolify_deploy_app (uuid + force=false)
if grep -qE 'deploy\?uuid=\$STAGING_APP_UUID&force=false' "$WF"; then
  pass "C3: staging deploy via /deploy?uuid=...&force=false"
else
  fail "C3: staging deploy endpoint drifted from coolify_deploy_app"
fi

# C4 — smoke test uses the staging domain (via env) + health_check_path
if grep -qE 'STAGING_DOMAIN: contract-staging\.ci\.example\.com' "$WF" \
   && grep -qE 'https://\$STAGING_DOMAIN/healthz' "$WF"; then
  pass "C4: smoke test hits staging domain at /healthz (threaded from coolify.yaml)"
else
  fail "C4: smoke test does not use health_check_path from coolify.yaml"
fi

# C5 — production is gated on deploy-staging
if python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
needs = jobs["deploy-production"].get("needs", [])
needs = [needs] if isinstance(needs, str) else needs
sys.exit(0 if "deploy-staging" in needs else 1)
PY
then
  pass "C5: deploy-production gated on deploy-staging"
else
  fail "C5: deploy-production not gated on deploy-staging"
fi

# C6 — both deploy jobs use the SAME tag source (needs.build.outputs.tag)
TAG_REFS=$(grep -c 'needs\.build\.outputs\.tag' "$WF" || true)
if [ "$TAG_REFS" -ge 2 ]; then
  pass "C6: staging and production both promote needs.build.outputs.tag ($TAG_REFS refs)"
else
  fail "C6: same-image promotion broken — needs.build.outputs.tag referenced $TAG_REFS time(s), expected >= 2"
fi

# C7 — production deploy endpoint matches coolify_deploy_app
if grep -qE 'deploy\?uuid=\$PROD_APP_UUID&force=false' "$WF"; then
  pass "C7: production deploy via /deploy?uuid=...&force=false"
else
  fail "C7: production deploy endpoint drifted from coolify_deploy_app"
fi

# C8 — provisioned UUIDs embedded; no placeholders survive
if grep -q 'REPLACE_WITH' "$WF"; then
  fail "C8: placeholder UUIDs remain despite provisioned coolify_app_ids"
else
  pass "C8: no REPLACE_WITH placeholders"
fi
if grep -q "$STG_UUID" "$WF" && grep -q "$PRD_UUID" "$WF"; then
  pass "C8b: both provisioned app UUIDs embedded"
else
  fail "C8b: provisioned app UUIDs not embedded in workflow"
fi

# C9 — no env-specific build-args (same-image promotion guarantee)
# Identity-only build-args (GIT_SHA, BUILD_TIMESTAMP) are allowed — they do not
# break same-image promotion because their values are identical for staging and production.
if grep -qE '^\s*build-args:' "$WF"; then
  env_specific=$(grep -A5 'build-args:' "$WF" | grep -v 'GIT_SHA\|BUILD_TIMESTAMP' | grep -c '=') || true
  if [ "$env_specific" -gt 0 ]; then
    fail "C9: env-specific build-args present — breaks same-image promotion"
  else
    pass "C9: build-args are identity-only (GIT_SHA/BUILD_TIMESTAMP) — same-image promotion preserved"
  fi
else
  pass "C9: no build-args in build job"
fi

# C10 — structural validity (YAML parse + needs: resolution)
if bash "$SCRIPT_DIR/validate-workflow.sh" "$WF" >/dev/null 2>&1; then
  pass "C10: validate-workflow.sh structural checks pass"
else
  fail "C10: validate-workflow.sh failed on generated output"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo " workflow contract checks"
echo "═══════════════════════════════════"
echo "  Passed: $PASS  Failed: $FAIL"
echo "═══════════════════════════════════"

[ "$FAIL" -eq 0 ]
