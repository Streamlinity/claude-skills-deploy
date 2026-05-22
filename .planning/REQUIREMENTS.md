# Requirements: claude-skills-deploy

**Defined:** 2026-05-21
**Core Value:** A developer can clone this repo, run one command, see a working hello-world deployment on their Coolify server, and trust the skill is correct before using it for a real application.

## v1 Requirements

### Bug Fixes

- [x] **BUG-01**: Running `/setup-coolify` on a repo generates a `deploy.yml` where the `deploy-production` job's `needs:` list references only jobs that exist in the same workflow file (currently references non-existent `smoke-staging` job)
- [x] **BUG-02**: When `provision.sh` calls `doppler secrets get` and the subprocess fails (network error, revoked token, wrong project), the script exits with a clear error message identifying the specific key and failure reason — does not silently inject an empty value into Coolify
- [x] **BUG-03**: `provision.sh` resolves the Coolify server UUID using a configurable server name read from `coolify.json` (with default `localhost`) — not a hardcoded string literal

### E2E Test Framework

- [ ] **TEST-01**: Operator can run `bash test/e2e.sh` against a real Coolify server to provision a hello-world staging app and verify it responds to an HTTPS smoke test at `/api/health`
- [ ] **TEST-02**: E2E test writes a machine-readable test report to `test/results/YYYYMMDD-HHMMSS.json` containing: staging URL, Coolify project UUID, staging app UUID, per-step pass/fail results, and run timestamp
- [ ] **TEST-03**: E2E test does not auto-teardown the deployment on completion — staging app remains running so the operator can browse to the URL and verify the deployment visually
- [ ] **TEST-04**: E2E test target is fully configurable via env vars: `E2E_SERVER` (default: `vultr-stream`) and `E2E_BASE_DOMAIN` (default: `cicd.streamlinity.com`) — defaults are clearly documented as "change for other domains" in the script header
- [ ] **TEST-05**: E2E test script prints a completion summary: staging URL, test report path, and next step (`bash test/cleanup-deployment.sh <report-file>`)

### Workflow Validation

- [x] **VALID-01**: Running `bash test/validate-workflow.sh <path-to-deploy.yml>` reports YAML syntax validity (parses without error)
- [x] **VALID-02**: `validate-workflow.sh` checks that every job name referenced in a `needs:` list exists as a defined job in the same workflow — exits non-zero and prints the offending reference if not

### Cleanup

- [ ] **CLEAN-01**: Operator can run `bash test/cleanup-deployment.sh <report-file>` to delete the Coolify project and apps created by an E2E test run, using the app IDs recorded in the specified test report file
- [ ] **CLEAN-02**: `cleanup-deployment.sh` prints a confirmation of what it deleted (project name, app names, UUIDs) and exits 0 on success

## v2 Requirements

### Reliability

- **REL-01**: `coolify_curl` retries transient failures (HTTP 5xx, connection reset) up to 3 times with backoff before failing
- **REL-02**: `provision.sh` uses create-new-then-revoke-old token rotation to avoid a window with no valid service token
- **REL-03**: `coolify.yaml` write-back uses atomic file replacement (write to temp, then rename) to prevent truncation on interrupt

### Test Coverage

- **TCOV-01**: Unit tests for `lib-coolify-api.sh` functions (URL construction, JSON parsing, UUID extraction) that run without a live Coolify instance
- **TCOV-02**: E2E test base domain and server alias are configurable via `E2E_BASE_DOMAIN` and `E2E_SERVER` env vars (covered in v1 by TEST-04)

### Maintainability

- **MAINT-01**: YAML parsing logic extracted into a shared `lib-yaml.sh` function (currently duplicated across `provision.sh`, `validate.sh`, `generate-workflow.sh`, `test/e2e.sh`)
- **MAINT-02**: Stale env var cleanup — `provision.sh` removes Coolify env vars that are no longer in `env_vars` list in `coolify.yaml`

## Out of Scope

| Feature | Reason |
|---------|--------|
| Live GitHub Actions pipeline execution as test | Adds GitHub API dependency, requires push to real repo; static validation catches structural bugs |
| Production deployment validation in E2E test | Staging smoke test is sufficient trust signal; production path is identical code |
| Multi-node Coolify support | Target architecture is single-node; `server_name` default covers the common case |
| Per-env build mode (`build_time: true`) | Reserved for future breaking change; current same-image promotion model is the design |
| Private GHCR registry auth provisioning | Scope for a separate phase; document requirement in setup guide for now |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUG-01 | Phase 1 | Complete |
| BUG-02 | Phase 1 | Complete |
| BUG-03 | Phase 1 | Complete |
| TEST-01 | Phase 2 | Pending |
| TEST-02 | Phase 2 | Pending |
| TEST-03 | Phase 2 | Pending |
| TEST-04 | Phase 2 | Pending |
| TEST-05 | Phase 2 | Pending |
| VALID-01 | Phase 2 | Complete |
| VALID-02 | Phase 2 | Complete |
| CLEAN-01 | Phase 3 | Pending |
| CLEAN-02 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0 ✓

---
*Requirements defined: 2026-05-21*
*Last updated: 2026-05-21 — phase assignments added after roadmap creation*
