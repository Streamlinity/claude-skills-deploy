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
#   C11 deployment polling loop present in both deploy jobs (POLL-01/POLL-02)
#   C12 Assert staging version step present with graceful skip (SMOKE-01)
#   C13 Assert production version step present (SMOKE-03)
#   C14 verify-promotion.needs includes build — TAG resolves at runtime (PROMOTE-01)
#   C15 the weekly schedule never builds or deploys (build: if push; all deploys need build)
#   G1  auto mode (no promotion key) is byte-for-byte test/golden/deploy-auto.yml
#
# promotion: manual (deploy.yml, promote.yml, rollback.yml):
#   M1  deploy.yml triggers only on workflow_run of ci_workflow (completed, main) and the schedule
#   M2  no production app UUID or domain in deploy.yml outside drift-check
#   M3  the gate is deploy.yml's first job and every other job needs it
#   M4  deploy.yml has workflow-level concurrency group staging, cancel-in-progress false
#   M5  deploy-staging's first step re-checks the tip (stage_begin, which creates the
#       record only after the check) and comes before the image tag is set
#   M6  every checkout names its ref; deploy.yml builds and checks out workflow_run.head_sha;
#       no workflow uses github.sha
#   M7  promote.yml and rollback.yml trigger only on workflow_dispatch and share the
#       non-cancelling concurrency group production
#   M8  smoke_command runs after each deploy when set, and is absent when not set
#   M9  release_owners and ci_workflow are embedded; structural validity of all three
#   M10 the inlined gate is exactly scripts/release-gate.sh (the tests exercise the same text)
#   M11 promote's clean-up ignores the kept digests and runs only after deploy-production
#   P1-P6 check-promotion: manual needs ci_workflow and release_owners; bad values refused
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

# C11 — deployment polling loop present in both deploy jobs (POLL-01/POLL-02)
POLL_LOOPS=$(grep -c 'seq 1 36' "$WF" || true)
if [ "$POLL_LOOPS" -ge 2 ]; then
  pass "C11: deployment polling loop (seq 1 36) present in both deploy jobs ($POLL_LOOPS refs)"
else
  fail "C11: deployment polling loop missing or present in < 2 jobs (found $POLL_LOOPS)"
fi

# C12 — Assert staging version step present with graceful skip (SMOKE-01)
if grep -q 'Assert staging version' "$WF"; then
  pass "C12: Assert staging version step present in deploy-staging"
else
  fail "C12: Assert staging version step missing from deploy-staging"
fi

# C13 — Assert production version step present (SMOKE-03)
if grep -q 'Assert production version' "$WF"; then
  pass "C13: Assert production version step present in deploy-production"
else
  fail "C13: Assert production version step missing from deploy-production"
fi

# C14 — verify-promotion.needs includes build (PROMOTE-01 regression guard)
# Without build in needs, needs.build.outputs.tag resolves to empty string
# and the promotion assertion silently fails on every real workflow run.
if python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
needs = jobs.get("verify-promotion", {}).get("needs", [])
needs = [needs] if isinstance(needs, str) else needs
sys.exit(0 if "build" in needs else 1)
PY
then
  pass "C14: verify-promotion.needs includes build — TAG resolves from needs.build.outputs.tag"
else
  fail "C14: verify-promotion.needs missing build — TAG will be empty string at runtime"
fi

# C15 — the weekly schedule never builds or deploys (only drift-check runs on it)
# Without this, the cron trigger rebuilt main and promoted it to production every week.
if python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
if "github.event_name == 'push'" not in str(jobs["build"].get("if", "")):
    sys.exit("build is not limited to push")
def reaches_build(name, seen=()):
    needs = jobs[name].get("needs", [])
    needs = [needs] if isinstance(needs, str) else needs
    return "build" in needs or any(reaches_build(n, seen + (name,)) for n in needs if n not in seen)
for name, job in jobs.items():
    if name in ("build", "drift-check"):
        continue
    cond = str(job.get("if", ""))
    if not reaches_build(name) or "always()" in cond or "cancelled()" in cond:
        sys.exit(f"{name} could run without build")
sys.exit(0)
PY
then
  pass "C15: build runs on push only and every other job but drift-check depends on it"
else
  fail "C15: a scheduled run could build or deploy"
fi

# ── G1: auto mode is unchanged (other repos) ──────────────────────────────────
# Generated the way provision.sh calls it (./coolify.yaml from the repo root), so the
# Source line is stable. The golden file was produced by the generator before
# promotion: manual existed.

mkdir -p "$WORK_DIR/auto"
cp "$WORK_DIR/coolify.yaml" "$WORK_DIR/auto/coolify.yaml"
(cd "$WORK_DIR/auto" && COOLIFY_REGISTRY="$WORK_DIR/coolify.json" \
  bash "$SKILL_DIR/scripts/generate-workflow.sh" ./coolify.yaml >/dev/null)
if diff -u "$SCRIPT_DIR/golden/deploy-auto.yml" "$WORK_DIR/auto/.github/workflows/deploy.yml"; then
  pass "G1: auto mode output is byte-for-byte test/golden/deploy-auto.yml"
else
  fail "G1: auto mode output changed (diff above)"
fi
if [ -e "$WORK_DIR/auto/.github/workflows/promote.yml" ] || [ -e "$WORK_DIR/auto/.github/workflows/rollback.yml" ]; then
  fail "G1b: auto mode wrote promote.yml or rollback.yml"
else
  pass "G1b: auto mode writes deploy.yml only"
fi

# ── promotion: manual ─────────────────────────────────────────────────────────

manual_fixture() {  # manual_fixture DIR [SMOKE_LINE]
  mkdir -p "$1"
  cp "$WORK_DIR/coolify.yaml" "$1/coolify.yaml"
  cat >> "$1/coolify.yaml" << 'EOF'
promotion: manual
ci_workflow: CI checks
release_owners:
  - owner-one
  - owner2
EOF
  if [ -n "${2:-}" ]; then echo "$2" >> "$1/coolify.yaml"; fi
}

manual_fixture "$WORK_DIR/manual" "smoke_command: make smoke URL={url}"
manual_fixture "$WORK_DIR/manual-nosmoke"
for d in manual manual-nosmoke; do
  if ! (cd "$WORK_DIR/$d" && COOLIFY_REGISTRY="$WORK_DIR/coolify.json" \
        bash "$SKILL_DIR/scripts/generate-workflow.sh" ./coolify.yaml >/dev/null); then
    echo "FATAL: generate-workflow.sh failed for promotion: manual ($d)" >&2
    exit 1
  fi
done
MWF="$WORK_DIR/manual/.github/workflows"
NWF="$WORK_DIR/manual-nosmoke/.github/workflows"

for f in deploy.yml promote.yml rollback.yml; do
  if bash "$SCRIPT_DIR/validate-workflow.sh" "$MWF/$f" >/dev/null 2>&1 \
     && bash "$SCRIPT_DIR/validate-workflow.sh" "$NWF/$f" >/dev/null 2>&1; then
    pass "M9: $f is valid YAML and its needs resolve"
  else
    fail "M9: $f failed validate-workflow.sh"
  fi
done

# Structural checks over the parsed workflows. Prints "ok|fail <message>" lines.
while IFS= read -r line; do
  case "$line" in
    ok\ *)   pass "${line#ok }" ;;
    fail\ *) fail "${line#fail }" ;;
    *)       fail "unexpected checker output: $line" ;;
  esac
done < <(python3 - "$MWF" "$NWF" "$SKILL_DIR/scripts/release-gate.sh" "$PRD_UUID" \
           contract.ci.example.com <<'PY'
import os, re, sys, yaml
mwf, nwf, gate_path, prd_uuid, prd_domain = sys.argv[1:6]

def check(ok, msg):
    print(("ok " if ok else "fail ") + msg)

def load(d, name):
    return yaml.safe_load(open(os.path.join(d, name)))

def text(d, name):
    return open(os.path.join(d, name)).read()

def on(wf):
    return wf.get("on", wf.get(True))   # PyYAML reads the key `on` as True

def needs(job):
    n = job.get("needs", [])
    return [n] if isinstance(n, str) else n

def steps(job):
    return job.get("steps", [])

def step_text(s):
    # name, uses and run, without the inlined gate library (which defines every function)
    run = re.sub(r"<<'RELEASE_GATE_EOF'\n.*?\nRELEASE_GATE_EOF\n", "", str(s.get("run", "")), flags=re.S)
    return "\n".join([str(s.get("name", "")), str(s.get("uses", "")), run])

def step_index(job, needle):
    for i, s in enumerate(steps(job)):
        if needle in step_text(s):
            return i
    return -1

dep, pro, rol = (load(mwf, n) for n in ("deploy.yml", "promote.yml", "rollback.yml"))
jobs = dep["jobs"]

# M1
trig = on(dep)
wr = trig.get("workflow_run", {}) if isinstance(trig, dict) else {}
check(isinstance(trig, dict) and set(trig) == {"workflow_run", "schedule"}
      and wr.get("workflows") == ["CI checks"] and wr.get("types") == ["completed"]
      and wr.get("branches") == ["main"],
      "M1: deploy.yml triggers only on workflow_run of ci_workflow (completed, main) and the schedule")

# M2
leaks = [name for name, job in jobs.items() if name != "drift-check"
         and (prd_uuid in yaml.safe_dump(job) or prd_domain in yaml.safe_dump(job))]
top = {k: v for k, v in dep.items() if k != "jobs"}
check(not leaks and prd_uuid not in yaml.safe_dump(top) and prd_domain not in yaml.safe_dump(top),
      f"M2: no production app UUID or domain in deploy.yml outside drift-check {leaks or ''}".rstrip())
check(prd_uuid in yaml.safe_dump(jobs.get("drift-check", {})),
      "M2b: drift-check still covers the production app")

# M3
names = list(jobs)
check(names[0] == "gate" and all("gate" in needs(jobs[n]) for n in names[1:]),
      "M3: gate is the first job and every other job needs it")
check(all("needs.gate.outputs.proceed == 'true'" in str(jobs[n].get("if", ""))
          for n in ("build", "deploy-staging")),
      "M3b: build and deploy-staging run only when the gate says proceed")
check(jobs["drift-check"].get("if") == "github.event_name == 'schedule'",
      "M3c: drift-check runs on the schedule only")

# M4
check(dep.get("concurrency") == {"group": "staging", "cancel-in-progress": False},
      "M4: deploy.yml concurrency group staging, cancel-in-progress false")

# M5
stg = jobs["deploy-staging"]
first = step_text(steps(stg)[0]) if steps(stg) else ""
set_tag = step_index(stg, "coolify_set_tag")
check("stage_begin" in first and "release_begin" not in first and set_tag > 0
      and "RELEASE_GATE_EOF" in str(steps(stg)[0].get("run", "")),
      "M5: deploy-staging re-checks the tip in its first step, before setting the image tag")

# M6
all_text = "".join(text(d, n) for d in (mwf, nwf) for n in ("deploy.yml", "promote.yml", "rollback.yml"))
check("github.sha" not in all_text, "M6: no workflow uses github.sha")
checkouts = [s for wf in (dep, pro, rol) for j in wf["jobs"].values() for s in steps(j)
             if str(s.get("uses", "")).startswith("actions/checkout")]
check(checkouts and all((s.get("with") or {}).get("ref") for s in checkouts),
      "M6b: every checkout names its ref")
head = "${{ github.event.workflow_run.head_sha }}"
dep_checkouts = [s for j in jobs.values() for s in steps(j)
                 if str(s.get("uses", "")).startswith("actions/checkout")]
check(all(s["with"]["ref"] == head for s in dep_checkouts)
      and jobs["gate"]["steps"][0]["env"]["HEAD_SHA"] == head
      and "needs.gate.outputs.tag" in yaml.safe_dump(jobs["build"]),
      "M6c: deploy.yml checks out and builds workflow_run.head_sha")

# M7
for name, wf in (("promote.yml", pro), ("rollback.yml", rol)):
    trig = on(wf)
    check(isinstance(trig, dict) and set(trig) == {"workflow_dispatch"},
          f"M7: {name} triggers only on workflow_dispatch")
    check(wf.get("concurrency") == {"group": "production", "cancel-in-progress": False},
          f"M7b: {name} concurrency group production, not cancelled")
check(on(pro)["workflow_dispatch"]["inputs"]["tag"]["required"] is False,
      "M7c: promote's tag input is optional (one tap promotes staging's image)")
check(on(rol)["workflow_dispatch"]["inputs"]["environment"]["default"] == "production",
      "M7d: rollback defaults to production")

# M8
smoke_jobs = [("deploy.yml", jobs["deploy-staging"]), ("promote.yml", pro["jobs"]["smoke-staging"]),
              ("promote.yml", pro["jobs"]["deploy-production"]), ("rollback.yml", rol["jobs"]["deploy"])]
ok = True
for name, job in smoke_jobs:
    i_smoke, i_version = step_index(job, "run_smoke"), step_index(job, "assert_version")
    i_record = next((i for i, s in enumerate(steps(job))
                     if str(s.get("name", "")).startswith("Record") and "success" in str(s.get("name", ""))), -1)
    if i_smoke < 0 or i_smoke < i_version or (i_record >= 0 and i_record < i_smoke):
        ok = False
    if (job.get("env") or {}).get("SMOKE_COMMAND") != "make smoke URL={url}":
        ok = False
check(ok, "M8: smoke_command runs after the health and version checks in every deploy job")
check("run_smoke \"" not in "".join(text(nwf, n) for n in ("deploy.yml", "promote.yml", "rollback.yml"))
      and "setup-uv" not in "".join(text(nwf, n) for n in ("deploy.yml", "promote.yml", "rollback.yml")),
      "M8b: without smoke_command there is no smoke step and no uv")

# M9
check(all(wf["jobs"]["gate"]["env"]["RELEASE_OWNERS"] == "owner-one owner2" for wf in (pro, rol)),
      "M9b: release_owners embedded in the promote and rollback gates")

# M10
gate = open(gate_path).read().rstrip("\n")
blocks = []
for wf in (dep, pro, rol):
    for job in wf["jobs"].values():
        for s in steps(job):
            run = s.get("run", "")
            m = re.search(r"<<'RELEASE_GATE_EOF'\n(.*?)\nRELEASE_GATE_EOF\n", run, re.S)
            if m:
                blocks.append(m.group(1))
check(len(blocks) >= 8 and all(b == gate for b in blocks),
      f"M10: the {len(blocks)} inlined copies are exactly scripts/release-gate.sh")

# M11
clean = pro["jobs"]["cleanup"]
dpv = [s for s in steps(clean) if str(s.get("uses", "")).startswith("actions/delete-package-versions")]
check("deploy-production" in needs(clean) and len(dpv) == 1
      and dpv[0]["with"].get("ignore-versions") == "${{ steps.keep.outputs.ignore }}"
      and str(dpv[0]["with"].get("min-versions-to-keep")) == "7"
      and dpv[0]["with"].get("package-name") == "contract-app",
      "M11: clean-up runs after deploy-production and ignores the kept digests")
check("delete-package-versions" not in text(mwf, "deploy.yml"),
      "M11b: deploy.yml never deletes images")
PY
)

# ── P: check-promotion (validate.sh and the generator both use it) ────────────

promo_case() {  # promo_case ID WANT_RC EXPECT_TEXT DESCRIPTION YAML_EXTRA
  local f="$WORK_DIR/promo-$1.yaml" rc=0 out
  cp "$WORK_DIR/coolify.yaml" "$f"
  printf '%s\n' "$5" >> "$f"
  out=$(python3 "$SKILL_DIR/scripts/lib-config.py" check-promotion "$f" 2>&1) || rc=$?
  if [ "$rc" -eq "$2" ] && grep -qF -- "$3" <<< "$out"; then
    pass "$1: $4"
  else
    fail "$1: $4 (rc=$rc, output: $out)"
  fi
}

promo_case P1 1 "release_owners is required" "manual without release_owners is refused" \
  "promotion: manual
ci_workflow: CI"
promo_case P2 1 "ci_workflow is required" "manual without ci_workflow is refused" \
  "promotion: manual
release_owners: [owner-one]"
promo_case P3 1 "promotion must be auto or manual" "an unknown promotion value is refused" \
  "promotion: Manual"
promo_case P4 1 "must be a string containing {url}" "smoke_command without {url} is refused" \
  "promotion: manual
ci_workflow: CI
release_owners: [owner-one]
smoke_command: make smoke"
promo_case P5 1 "is not a GitHub login" "a release owner that is not a GitHub login is refused" \
  "promotion: manual
ci_workflow: CI
release_owners: ['bad owner']"
promo_case P6 0 "WARN: smoke_command is ignored unless promotion: manual" \
  "keys for manual promotion only warn in auto mode" \
  "smoke_command: make smoke URL={url}"
promo_case P7 0 "" "a complete manual configuration passes" \
  "promotion: manual
ci_workflow: CI
release_owners: [owner-one]
smoke_command: make smoke URL={url}"

mkdir -p "$WORK_DIR/manual-bad"
cp "$WORK_DIR/coolify.yaml" "$WORK_DIR/manual-bad/coolify.yaml"
echo "promotion: manual" >> "$WORK_DIR/manual-bad/coolify.yaml"
if (cd "$WORK_DIR/manual-bad" && COOLIFY_REGISTRY="$WORK_DIR/coolify.json" \
      bash "$SKILL_DIR/scripts/generate-workflow.sh" ./coolify.yaml >/dev/null 2>&1); then
  fail "P8: generator wrote workflows for promotion: manual without its required keys"
elif [ -e "$WORK_DIR/manual-bad/.github" ]; then
  fail "P8: generator refused but left files behind"
else
  pass "P8: generator refuses promotion: manual without ci_workflow and release_owners"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo " workflow contract checks"
echo "═══════════════════════════════════"
echo "  Passed: $PASS  Failed: $FAIL"
echo "═══════════════════════════════════"

[ "$FAIL" -eq 0 ]
