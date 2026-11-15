#!/usr/bin/env bash
# test-release-gate.sh — Offline tests for scripts/release-gate.sh (promotion: manual).
#
# Usage: bash test/test-release-gate.sh
#
# Runs fully offline. Stub gh, curl and docker on PATH answer from recorded API
# fixtures, so the gate functions run exactly as the generated workflows run them
# (generate-workflow.sh inlines the same file). Writes (POSTs to the Deployments API,
# image re-tags) are logged so tests can assert what was, and was not, created.
#
# Requires: bash, jq (preinstalled on GitHub-hosted runners).
#
# Exit 0: all tests pass. Exit 1: at least one failure (all failures printed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SKILL_DIR/scripts/release-gate.sh"

command -v jq >/dev/null || { echo "FATAL: jq is required (apt-get install jq)" >&2; exit 1; }

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

WORK_DIR=$(mktemp -d /tmp/csd-release-gate-XXXX)
trap 'rm -rf "$WORK_DIR"' EXIT
FX="$WORK_DIR/fixtures"
mkdir -p "$WORK_DIR/bin" "$FX"

export REPO="fixture-org/app"
export GH_TOKEN="fixture-token"
export COOLIFY_URL="https://coolify.fixture.example.com"
export COOLIFY_API_KEY="fixture-key"
export RUN_URL="https://github.com/fixture-org/app/actions/runs/1"
export FX GH_LOG="$WORK_DIR/gh.log" DOCKER_LOG="$WORK_DIR/docker.log"
export GITHUB_OUTPUT="$WORK_DIR/output"
export RG_NOW
RG_NOW=$(date -u -d '2026-11-14T12:00:00Z' +%s)
export PATH="$WORK_DIR/bin:$PATH"

# ── Stubs ──────────────────────────────────────────────────────────────────────
# gh api [-X METHOD] ENDPOINT [--input -]: answers from $FX/<key>, where the key is
# "METHOD endpoint" (endpoint without repos/fixture-org/app/) with / ? & = and spaces
# turned into _. A write is logged as "METHOD endpoint body" and answered with its
# fixture, or {"id":4242} for a new deployment record. A missing GET fixture is a 404.

cat > "$WORK_DIR/bin/gh" << 'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "gh stub: only 'gh api' is stubbed" >&2; exit 2; }
shift
method=GET; endpoint=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --input) body=$(cat); shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
ep="${endpoint#repos/fixture-org/app/}"
key=$(printf '%s %s' "$method" "$ep" | tr '/?&= ' '_____')
if [ "$method" != "GET" ]; then
  printf '%s %s %s\n' "$method" "$ep" "$(printf '%s' "$body" | tr -d '\n')" >> "$GH_LOG"
fi
if [ -f "$FX/$key" ]; then cat "$FX/$key"; exit 0; fi
if [ "$method" = "POST" ]; then
  case "$ep" in deployments) echo '{"id":4242}' ;; *) echo '{}' ;; esac
  exit 0
fi
echo "gh: HTTP 404: Not Found ($key)" >&2
exit 1
STUB

# curl: answers Coolify GET /applications/<uuid> from $FX/coolify_<uuid>.
cat > "$WORK_DIR/bin/curl" << 'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/v1/applications/*)
    f="$FX/coolify_${url##*/}"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi ;;
esac
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
STUB

# docker buildx imagetools inspect IMAGE:TAG -> $FX/manifest_<tag>; create -> logged.
cat > "$WORK_DIR/bin/docker" << 'STUB'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "buildx imagetools inspect" ]; then
  f="$FX/manifest_${4##*:}"
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo "ERROR: $4: not found" >&2; exit 1
fi
if [ "$1 $2 $3" = "buildx imagetools create" ]; then
  echo "$*" >> "$DOCKER_LOG"; exit 0
fi
echo "docker stub: unexpected: $*" >&2; exit 2
STUB
chmod +x "$WORK_DIR/bin/gh" "$WORK_DIR/bin/curl" "$WORK_DIR/bin/docker"

# ── Helpers ────────────────────────────────────────────────────────────────────

reset() { rm -f "$FX"/* "$GH_LOG" "$DOCKER_LOG" "$GITHUB_OUTPUT"; touch "$GH_LOG" "$DOCKER_LOG" "$GITHUB_OUTPUT"; }

fxapi() {  # fxapi METHOD ENDPOINT JSON
  printf '%s' "$3" > "$FX/$(printf '%s %s' "$1" "$2" | tr '/?&= ' '_____')"
}

# run FUNCTION ARGS... — runs a gate function in a fresh shell that sourced the gate
# file, like a workflow step. Sets RC and OUT (stdout and stderr).
run() {
  RC=0
  OUT=$( ( source "$SKILL_DIR/scripts/release-gate.sh"; "$@" ) 2>&1 ) || RC=$?
}

outv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n 1 | cut -d= -f2-; }

expect_rc() {  # expect_rc NAME RC
  if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 (rc=$RC, want $2): $OUT"; fi
}
expect_out() {  # expect_out NAME TEXT — OUT contains TEXT
  if grep -qF -- "$2" <<< "$OUT"; then pass "$1"; else fail "$1 (no '$2' in: $OUT)"; fi
}
expect_eq() {  # expect_eq NAME WANT GOT
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}
writes() { grep -c "${1:-.}" "$GH_LOG" || true; }

SHA_A=aaaaaaa1111111111111111111111111111111111
SHA_A=${SHA_A:0:40}
SHA_B=bbbbbbb2222222222222222222222222222222222
SHA_B=${SHA_B:0:40}
SHA_C=ccccccc3333333333333333333333333333333333
SHA_C=${SHA_C:0:40}
D1="sha256:$(printf '1%.0s' {1..64})"
D2="sha256:$(printf '2%.0s' {1..64})"
D3="sha256:$(printf '3%.0s' {1..64})"
D4="sha256:$(printf '4%.0s' {1..64})"
D5="sha256:$(printf '5%.0s' {1..64})"

merge_env() {  # merge_env CONCLUSION [EVENT] — a workflow_run of CI for SHA_B on main
  export EVENT_NAME=workflow_run HEAD_SHA="$SHA_B" CI_EVENT="${2:-push}" CI_HEAD_BRANCH=main \
    CI_CONCLUSION="$1" CI_URL="https://github.com/fixture-org/app/actions/runs/9"
}
tip_is() { fxapi GET branches/main "{\"commit\":{\"sha\":\"$1\"}}"; }
pr_merged() { fxapi GET "commits/$SHA_B/pulls" "[{\"number\":7,\"merged_at\":\"2026-11-14T10:00:00Z\",\"merge_commit_sha\":\"$1\"}]"; }

echo "=== deploy.yml gate: tip of main, CI result, merged pull request ==="

reset; merge_env success; tip_is "$SHA_B"; pr_merged "$SHA_B"
run gate_merge main
expect_rc "CI success, tip, merged PR: gate passes" 0
expect_eq "  proceed=true" true "$(outv proceed)"
expect_eq "  tag is the 7-character commit" bbbbbbb "$(outv tag)"
expect_eq "  sha is workflow_run.head_sha" "$SHA_B" "$(outv sha)"

reset; merge_env failure; tip_is "$SHA_B"; pr_merged "$SHA_B"
run gate_merge main
expect_rc "CI failure: refused" 1
expect_out "  message names the conclusion and says nothing deployed" "CI concluded 'failure' for bbbbbbb"
expect_eq "  no proceed output" "" "$(outv proceed)"

reset; merge_env cancelled; tip_is "$SHA_B"; pr_merged "$SHA_B"
run gate_merge main
expect_rc "CI cancelled on the tip: refused" 1
expect_out "  message names the conclusion" "CI concluded 'cancelled'"

reset; merge_env cancelled; tip_is "$SHA_C"
run gate_merge main
expect_rc "CI cancelled, newer commit on main: superseded, success" 0
expect_eq "  proceed=false" false "$(outv proceed)"
expect_out "  says superseded by the new tip" "Superseded by ccccccc"

reset; merge_env success; tip_is "$SHA_C"; pr_merged "$SHA_B"
run gate_merge main
expect_rc "CI success but superseded: stop, success" 0
expect_eq "  proceed=false" false "$(outv proceed)"
expect_eq "  nothing written" 0 "$(writes)"

reset; merge_env success pull_request; tip_is "$SHA_B"; pr_merged "$SHA_B"
run gate_merge main
expect_rc "CI run from a pull_request event: refused" 1
expect_out "  says it was not a push" "not a push to main"

reset; merge_env success; tip_is "$SHA_B"; fxapi GET "commits/$SHA_B/pulls" '[]'
run gate_merge main
expect_rc "no pull request for the commit (direct push): refused" 1
expect_out "  revert-or-PR message" "was pushed to main directly, not merged from a pull request"

reset; merge_env success; tip_is "$SHA_B"; pr_merged "$SHA_A"
run gate_merge main
expect_rc "merged PR whose merge commit differs: refused" 1
expect_out "  revert-or-PR message" "was pushed to main directly"

reset; merge_env success; tip_is "$SHA_B"
fxapi GET "commits/$SHA_B/pulls" "[{\"number\":8,\"merged_at\":null,\"merge_commit_sha\":\"$SHA_B\"}]"
run gate_merge main
expect_rc "PR found but not merged: refused" 1

reset; merge_env success; pr_merged "$SHA_B"
run gate_merge main
expect_rc "tip of main unreadable: fails closed" 1
expect_out "  says re-run later" "could not read the tip of main"

reset; merge_env success; tip_is "$SHA_B"
run gate_merge main
expect_rc "pull request lookup fails: fails closed" 1

reset; export EVENT_NAME=schedule
run gate_merge main
expect_rc "schedule: drift check only, success" 0
expect_eq "  proceed=false (nothing built)" false "$(outv proceed)"

echo ""
echo "=== deploy-staging: tip re-check, then the staging record ==="

reset; tip_is "$SHA_C"
run stage_begin "$SHA_B" main bbbbbbb "$D1" aaaaaaa merger
expect_rc "head moved between gate and deploy: stop, success" 0
expect_eq "  proceed=false" false "$(outv proceed)"
expect_eq "  no deployment record created" 0 "$(writes)"

reset; tip_is "$SHA_B"
run stage_begin "$SHA_B" main bbbbbbb "$D1" aaaaaaa merger
expect_rc "head still the tip: record created" 0
expect_eq "  proceed=true" true "$(outv proceed)"
expect_eq "  record_id output" 4242 "$(outv record_id)"
REC=$(grep '^POST deployments ' "$GH_LOG" | head -n 1 | cut -d' ' -f3-)
expect_eq "  record environment staging, ref is the commit" "staging $SHA_B false" \
  "$(jq -r '"\(.environment) \(.ref) \(.production_environment)"' <<< "$REC")"
expect_eq "  payload: tag, digest, kind, started_by, replaced_tag, run_url" \
  "bbbbbbb $D1 merge merger aaaaaaa $RUN_URL" \
  "$(jq -r '.payload | "\(.image_tag) \(.digest) \(.kind) \(.started_by) \(.replaced_tag) \(.run_url)"' <<< "$REC")"
STATUS=$(grep '^POST deployments/4242/statuses ' "$GH_LOG" | head -n 1 | cut -d' ' -f3-)
expect_eq "  status in_progress, older records stay active" "in_progress false" \
  "$(jq -r '"\(.state) \(.auto_inactive)"' <<< "$STATUS")"

reset
run record_status 4242 success "done"
STATUS=$(grep '^POST deployments/4242/statuses ' "$GH_LOG" | cut -d' ' -f3-)
expect_eq "record_status success keeps auto_inactive false and links the run" "success false $RUN_URL" \
  "$(jq -r '"\(.state) \(.auto_inactive) \(.log_url)"' <<< "$STATUS")"

echo ""
echo "=== promote.yml gate: release owner, image staging runs, staging record ==="

run gate_actor anatesan-stream "someone anatesan-stream"
expect_rc "actor on the release-owner list: allowed" 0
run gate_actor intruder "someone anatesan-stream"
expect_rc "actor not on the list: refused" 1
expect_out "  says who may" "intruder is not a release owner"

staging_records() {  # staging_records STATE SUCCESS_AT — staging record 21 for bbbbbbb
  fxapi GET "deployments?environment=staging&per_page=100" \
    "[{\"id\":21,\"sha\":\"$SHA_B\",\"payload\":{\"image_tag\":\"bbbbbbb\",\"digest\":\"$D1\",\"kind\":\"merge\",\"replaced_tag\":\"aaaaaaa\"}},
      {\"id\":20,\"sha\":\"$SHA_A\",\"payload\":{\"image_tag\":\"aaaaaaa\",\"digest\":\"$D2\",\"kind\":\"merge\",\"replaced_tag\":\"\"}}]"
  fxapi GET "deployments/21/statuses?per_page=100" \
    "[{\"state\":\"$1\",\"created_at\":\"$2\"},{\"state\":\"in_progress\",\"created_at\":\"2026-11-01T00:00:00Z\"}]"
}

reset; staging_records success 2026-11-14T10:00:00Z
run gate_promote bbbbbbb "" aaaaaaa
expect_rc "no input, staging record success: promote staging's image" 0
expect_eq "  tag" bbbbbbb "$(outv tag)"
expect_eq "  sha from the record" "$SHA_B" "$(outv sha)"
expect_eq "  digest from the record" "$D1" "$(outv digest)"
expect_eq "  replaced_tag is production's tag" aaaaaaa "$(outv replaced_tag)"
expect_eq "  staging checked 2 hours ago: no staging re-smoke" false "$(outv smoke_staging)"

reset; staging_records success 2026-11-12T10:00:00Z
run gate_promote bbbbbbb bbbbbbb aaaaaaa
expect_rc "input tag equal to staging's: allowed" 0
expect_eq "  staging checked over 24 hours ago: re-smoke staging" true "$(outv smoke_staging)"

reset; staging_records success 2026-11-14T10:00:00Z
run gate_promote bbbbbbb ccccccc aaaaaaa
expect_rc "input tag different from staging's: refused" 1
expect_out "  points to Roll back" "is not the image staging runs now (bbbbbbb)"

reset; staging_records success 2026-11-14T10:00:00Z
run gate_promote bbbbbbb 'x; rm' aaaaaaa
expect_rc "input that is not a 7-character tag: refused" 1

reset; staging_records success 2026-11-14T10:00:00Z
run gate_promote bbbbbbb "" bbbbbbb
expect_rc "production already runs staging's image: refused" 1

reset; staging_records success 2026-11-14T10:00:00Z
run gate_promote ccccccc "" aaaaaaa
expect_rc "staging image with no staging record: refused" 1
expect_out "  says no staging record" "ccccccc has no staging deployment record"

reset; staging_records failure 2026-11-14T10:00:00Z
run gate_promote bbbbbbb "" aaaaaaa
expect_rc "staging record failure: refused" 1
expect_out "  names the state" "is 'failure', not success"

reset; staging_records success 2026-11-14T10:00:00Z
fxapi GET "deployments/21/statuses?per_page=100" '[{"state":"in_progress","created_at":"2026-11-14T10:00:00Z"}]'
run gate_promote bbbbbbb "" aaaaaaa
expect_rc "staging record still in_progress: refused" 1

reset; staging_records success 2026-11-14T10:00:00Z
fxapi GET "deployments/21/statuses?per_page=100" \
  '[{"state":"inactive","created_at":"2026-11-14T11:00:00Z"},{"state":"success","created_at":"2026-11-14T10:00:00Z"}]'
run gate_promote bbbbbbb "" aaaaaaa
expect_rc "a success later marked inactive still counts as success" 0

echo ""
echo "=== rollback.yml gate: an image the environment ran before ==="

prod_records() {  # production: 31 = bbbbbbb (replaced aaaaaaa), 30 = aaaaaaa (replaced 9999999)
  fxapi GET "deployments?environment=production&per_page=100" \
    "[{\"id\":32,\"sha\":\"$SHA_C\",\"payload\":{\"image_tag\":\"ccccccc\",\"kind\":\"promote\",\"replaced_tag\":\"bbbbbbb\"}},
      {\"id\":31,\"sha\":\"$SHA_B\",\"payload\":{\"image_tag\":\"bbbbbbb\",\"kind\":\"promote\",\"replaced_tag\":\"aaaaaaa\"}},
      {\"id\":30,\"sha\":\"$SHA_A\",\"payload\":\"{\\\"image_tag\\\":\\\"aaaaaaa\\\",\\\"kind\\\":\\\"promote\\\",\\\"replaced_tag\\\":\\\"9999999\\\"}\"}]"
  fxapi GET "deployments/32/statuses?per_page=100" '[{"state":"failure","created_at":"2026-11-14T11:00:00Z"}]'
  fxapi GET "deployments/31/statuses?per_page=100" '[{"state":"success","created_at":"2026-11-13T11:00:00Z"}]'
  fxapi GET "deployments/30/statuses?per_page=100" '[{"state":"success","created_at":"2026-11-12T11:00:00Z"}]'
  fxapi GET commits/aaaaaaa "{\"sha\":\"$SHA_A\"}"
  fxapi GET commits/bbbbbbb "{\"sha\":\"$SHA_B\"}"
  fxapi GET commits/9999999 '{"sha":"9999999000000000000000000000000000000000"}'
}

reset; prod_records
run gate_rollback production bbbbbbb ""
expect_rc "default: current record's replaced_tag" 0
expect_eq "  target is the image bbbbbbb replaced" aaaaaaa "$(outv tag)"
expect_eq "  sha resolved from the tag" "$SHA_A" "$(outv sha)"
expect_eq "  replaced_tag is what runs now" bbbbbbb "$(outv replaced_tag)"
expect_eq "  nothing written by the gate" 0 "$(writes)"

reset; prod_records
run gate_rollback production ccccccc ""
expect_rc "default after a failed release (ccccccc): back to the last success" 0
expect_eq "  target is the newest successful release" bbbbbbb "$(outv tag)"

reset; prod_records
run gate_rollback production bbbbbbb 9999999
expect_rc "chosen tag that a successful record replaced (payload as a JSON string): allowed" 0
expect_eq "  target" 9999999 "$(outv tag)"

reset; prod_records
run gate_rollback production ccccccc aaaaaaa
expect_rc "chosen tag with a successful record: allowed" 0

reset; prod_records
run gate_rollback production bbbbbbb 1234567
expect_rc "chosen tag that never ran there: refused" 1
expect_out "  says it never ran" "1234567 never ran on production"

reset; prod_records
run gate_rollback production bbbbbbb bbbbbbb
expect_rc "chosen tag already running: refused" 1

reset; fxapi GET "deployments?environment=production&per_page=100" '[]'
run gate_rollback production bbbbbbb ""
expect_rc "no production record yet: refused" 1
expect_out "  says nothing recorded" "no successful production release is recorded"

reset; prod_records
run gate_rollback qa bbbbbbb ""
expect_rc "unknown environment: refused" 1

echo ""
echo "=== weekly drift check: production runs its newest successful release ==="

reset; prod_records
run drift_production bbbbbbb
expect_rc "production on the newest successful release: ok" 0
run drift_production aaaaaaa
expect_rc "production changed by hand: fails" 1
expect_out "  says outside promote and rollback" "outside promote.yml and rollback.yml"
reset; fxapi GET "deployments?environment=production&per_page=100" '[]'
run drift_production aaaaaaa
expect_rc "no production record yet: skipped" 0

echo ""
echo "=== clean-up keep list: digests of kept tags and their child manifests ==="

reset
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","manifests":[{"digest":"%s","platform":{"architecture":"amd64","os":"linux"}},{"digest":"%s","platform":{"architecture":"unknown","os":"unknown"}}]}' \
  "$D1" "$D2" "$D3" > "$FX/manifest_production"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s"}' "$D4" > "$FX/manifest_production-previous"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","manifests":[{"digest":"%s"}]}' \
  "$D5" "$D2" > "$FX/manifest_ccccccc"
run keep_regex ghcr.io/fixture-org/app production production-previous ccccccc
expect_rc "keep list built" 0
RE=$(tail -n 1 <<< "$OUT")
for d in "$D1" "$D2" "$D3" "$D4" "$D5"; do
  if grep -qE "$RE" <<< "$d"; then pass "  keeps ${d:0:12}…"; else fail "  does not keep $d (regex $RE)"; fi
done
OTHER="sha256:$(printf '6%.0s' {1..64})"
if grep -qE "$RE" <<< "$OTHER"; then fail "  keeps an unrelated digest"; else pass "  does not keep an unrelated digest"; fi
if grep -qE "$RE" <<< "x$D1"; then fail "  regex is not anchored"; else pass "  regex is anchored"; fi

run keep_regex ghcr.io/fixture-org/app production gone1234
expect_rc "a kept tag missing from the registry: refused, nothing deleted" 1

run image_digest ghcr.io/fixture-org/app production
expect_eq "image_digest reads the index digest" "$D1" "$OUT"
run image_digest ghcr.io/fixture-org/app 0000000
expect_rc "image_digest of a deleted image: refused" 1

echo ""
echo "=== Coolify read and smoke command ==="

reset; printf '{"uuid":"stg","docker_registry_image_tag":"bbbbbbb"}' > "$FX/coolify_stg"
run coolify_app_tag stg
expect_eq "coolify_app_tag reads docker_registry_image_tag" bbbbbbb "$OUT"
run coolify_app_tag missing
expect_rc "coolify_app_tag of an unreadable app: refused" 1

RC=0; OUT=$( ( source "$SKILL_DIR/scripts/release-gate.sh"; SMOKE_COMMAND='echo smoke-ran URL={url}' run_smoke https://stg.example.com ) 2>&1 ) || RC=$?
expect_out "run_smoke replaces {url}" "smoke-ran URL=https://stg.example.com"
RC=0; OUT=$( ( source "$SKILL_DIR/scripts/release-gate.sh"; SMOKE_COMMAND='exit 3 # {url}' run_smoke https://stg.example.com ) 2>&1 ) || RC=$?
expect_rc "run_smoke fails when the smoke command fails" 3
RC=0; OUT=$( ( source "$SKILL_DIR/scripts/release-gate.sh"; SMOKE_COMMAND='' run_smoke https://stg.example.com ) 2>&1 ) || RC=$?
expect_out "run_smoke without smoke_command is skipped" "SKIP smoke"

echo ""
echo "=== release-gate.sh is safe to inline into a workflow ==="
if grep -qF '${{' "$GATE"; then fail "contains a GitHub Actions expression opener"; else pass "no GitHub Actions expression opener"; fi
if grep -qP '^\t' "$GATE"; then fail "indents with tabs"; else pass "indents with spaces only"; fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo " release gate tests"
echo "═══════════════════════════════════"
echo "  Passed: $PASS  Failed: $FAIL"
echo "═══════════════════════════════════"

[ "$FAIL" -eq 0 ]
