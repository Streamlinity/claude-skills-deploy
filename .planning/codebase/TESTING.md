# Testing Patterns

**Analysis Date:** 2026-05-21

## Test Framework

**Runner:** Plain bash — no test framework dependency
- No Jest, Bats, or shunit2
- Tests are self-contained shell scripts that print `PASS:` / `FAIL:` / `✓` / `✗` lines and exit non-zero on failure

**Assertion approach:**
- Unit-style tests: `run_test "label" "$?"` pattern — capture exit code of a subshell and report
- E2E tests: `pass()` / `fail()` helper functions that accumulate counts into `PASS`, `FAIL`, `RESULTS[]`

**Run commands:**
```bash
# Unit tests for init.sh
bash init/test_init.sh

# E2E integration test (requires live Coolify + Doppler)
bash test/e2e.sh

# E2E against a specific server
bash test/e2e.sh --server hetzner-strategem

# E2E skip cleanup on failure (inspect state)
bash test/e2e.sh --keep
```

## Test File Organization

**Location:** Tests are NOT co-located with the scripts they test. Two directories:
- `init/test_init.sh` — unit-style behavioral tests for `init/init.sh`
- `test/e2e.sh` — full integration test for the entire provisioning flow
- `test/push-hello-world.sh` — prerequisite setup script (not a test runner)
- `test/hello-world/` — E2E test fixture (nginx container image)

**Naming:**
- Unit test files: `test_noun.sh` (`test_init.sh`) — underscore, noun matches the script under test
- Integration test files: `e2e.sh` — conventional name in a `test/` directory

## Test Structure

**Unit test pattern (`init/test_init.sh`):**

```bash
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

# Each test creates an isolated temp directory
T1_DIR=$(mktemp -d)
# ... setup ...
if (cd "$T1_DIR" && bash "$INIT_SH" > /dev/null 2>&1); then
  run_test "Test 1: description" "1"   # unexpected success = fail
else
  run_test "Test 1: description" "0"   # expected failure = pass
fi
rm -rf "$T1_DIR"
```

**E2E test pattern (`test/e2e.sh`):**

```bash
pass() { PASS=$((PASS+1)); RESULTS+=("  ✓ $*"); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL+1)); RESULTS+=("  ✗ $*"); echo "  ✗ $*" >&2; }
step() { echo ""; echo "=== $* ==="; }

# ... test body calls pass/fail ...

# Results printed and cleanup executed via trap on EXIT
trap cleanup EXIT
```

## Test Isolation

**Unit tests:** Each test case uses `mktemp -d` for a fresh temporary directory and `rm -rf` cleanup after the assertion — isolated filesystem, no shared state between test cases.

**E2E tests:** Use a timestamped project name (`csd-e2e-${TIMESTAMP}`) to avoid collisions. Unconditional cleanup via `trap cleanup EXIT` — runs even on non-zero exit. The `--keep` flag skips cleanup to preserve state for debugging.

## E2E Test Flow

The E2E test in `test/e2e.sh` covers the full provision-deploy-verify cycle in 9 sequential steps:

1. **Prerequisites check** — `python3`, `pyyaml`, `doppler`, `curl`, `ssh`, `~/.claude/coolify.json`
2. **Preflight** — verify the test Docker image is pullable from GHCR
3. **Doppler project setup** — creates a throwaway Doppler project with `staging` + `production` configs and dummy secrets (`HELLO=world`, `E2E_TEST=true`)
4. **Generate coolify.yaml** — builds a valid `coolify.yaml` in a temp `$WORK_DIR` using Python/PyYAML directly
5. **validate.sh** — runs `scripts/validate.sh` against the generated config (dry-run)
6. **provision.sh** — runs `scripts/provision.sh` to create Coolify apps and inject Doppler tokens
7. **Trigger staging deploy** — calls `coolify_deploy_app`, gets a `deployment_uuid`
8. **Poll deployment status** — polls `GET /deployments/$DEPLOYMENT_UUID` every 10s, timeout 180s
9. **HTTP smoke test** — polls `https://{staging_domain}/api/health` for HTTP 200 every 10s, timeout 120s; also verifies body contains `claude-skills-deploy-e2e-ok`

## Test Fixture

**`test/hello-world/`** — minimal nginx container used as the E2E test image:
- `Dockerfile` — `FROM nginx:alpine`, listens on port 3000
- `nginx.conf` — serves `GET /api/health → 200 "ok\n"` and static `index.html`
- `index.html` — contains the string `claude-skills-deploy-e2e-ok` (body-check anchor for smoke test)

**Fixture image location:** `ghcr.io/Streamlinity/claude-skills-deploy/hello-world:latest`

**Rebuilding the fixture:**
```bash
export GHCR_TOKEN=ghp_...   # PAT with write:packages scope
bash test/push-hello-world.sh
```

## Unit Test Coverage (`init/test_init.sh`)

7 tests covering `init/init.sh` behavior:

| Test | What it verifies |
|------|-----------------|
| Test 1 | Idempotency guard: refuses to overwrite existing `coolify.yaml` |
| Test 2 | Piped input produces a valid YAML `coolify.yaml` |
| Test 3 | No unsubstituted `{{` tokens remain in generated output |
| Test 4 | `build.context` defaults to `.`, `build.dockerfile` defaults to `./Dockerfile` |
| Test 5 | `env_vars` field renders as a proper YAML list |
| Test 6 | `init.sh` also generates `.github/workflows/deploy.yml` as valid YAML |
| Test 7 | Idempotency guard: refuses to overwrite existing `deploy.yml` |

Tests use piped stdin (`printf '...' | bash "$INIT_SH"`) to drive the interactive prompts non-interactively.

## CI/CD Test Configuration

**No CI pipeline is defined for this repo itself.** There is no `.github/workflows/` directory at the repo root.

The skill *generates* CI workflows for target repos (via `scripts/generate-workflow.sh`), but is not itself tested in CI. The generated workflow pattern for target repos is:

```yaml
# build → deploy-staging (with smoke test) → deploy-production → ghcr-cleanup
on:
  push:
    branches: [main]
```

The staging smoke test in generated workflows (`deploy-staging` job) polls `https://{staging_domain}/` every 30s for up to 6 minutes (12 retries). Production deploy only runs if `smoke-staging` succeeds — staging is the gate.

## Test Coverage Gaps

**No unit tests for:**
- `scripts/provision.sh` — complex script with SSH, Coolify API calls, Doppler token creation; only covered by E2E
- `scripts/validate.sh` — no isolated unit tests; covered as a step within E2E
- `scripts/generate-workflow.sh` — no tests for the generated workflow YAML structure or correctness of placeholder substitution
- `scripts/lib-coolify-api.sh` — API wrapper functions have no mock-based unit tests
- `scripts/lib-doppler-api.sh` — same gap

**E2E test prerequisites make CI impractical:**
- Requires live Coolify server reachable via `~/.claude/coolify.json`
- Requires authenticated `doppler` CLI
- Requires `ssh` access to the Coolify VPS
- Requires pre-pushed GHCR image (`test/push-hello-world.sh` run separately)

The E2E test is designed for manual execution against a real environment, not for automated CI on pull requests.

**Missing:**
- No static analysis (shellcheck) configured or enforced
- No pre-commit hooks for YAML validation
- No automated test run on commit

---

*Testing analysis: 2026-05-21*
