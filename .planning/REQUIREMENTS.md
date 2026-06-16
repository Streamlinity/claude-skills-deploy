# Requirements: claude-skills-deploy

**Defined:** 2026-05-21
**Core Value:** A developer can clone this repo, run one command, see a working hello-world deployment on their Coolify server, and trust the skill is correct before using it for a real application.

## v1.1 Requirements

Requirements for milestone v1.1: Deployment Correctness. Each maps to roadmap phases.

### DIAG — Deployment Diagnostics

- [x] **DIAG-01**: The build job captures the full image digest (sha256) from `build-push-action` output and passes it as a job output alongside the short SHA tag
- [x] **DIAG-02**: The deploy-staging and deploy-production steps log the expected digest and tag at the start of each step

### POLL — Deployment Polling

- [x] **POLL-01**: After triggering a Coolify deploy, the workflow polls the Coolify deployments API until `status=finished` or `status=failed` (max 6 min) before proceeding to health checks
- [x] **POLL-02**: A `status=failed` Coolify deployment exits the workflow immediately with a clear error message directing the operator to the Coolify UI, rather than timing out on the health endpoint

### SMOKE — Smoke Tests

- [x] **SMOKE-01**: The staging smoke test extracts `version` from the health response body and asserts it matches the expected SHA tag; gracefully skips the assertion when the field is absent
- [x] **SMOKE-02**: The production deployment job includes a post-deploy smoke test (currently absent)
- [x] **SMOKE-03**: The production smoke test performs the same version assertion as staging (graceful skip when field absent)

### PROMOTE — Promotion Integrity

- [x] **PROMOTE-01**: A `verify-promotion` CI job runs after both deploys complete and asserts that Coolify's application record confirms the same image tag on both staging and production apps
- [x] **PROMOTE-02**: The `ghcr-cleanup` job depends on `verify-promotion`; cleanup does not run if the promotion assertion fails, preserving all tags in GHCR for debugging

### LAYER3 — Runtime Identity (app-side scaffolding)

- [x] **LAYER3-01**: `generate-workflow.sh` passes `GIT_SHA` and `BUILD_TIMESTAMP` as build-args so images carry OCI `revision` and `created` labels
- [x] **LAYER3-02**: The `init.sh` Dockerfile template includes `ARG GIT_SHA`, `ARG BUILD_TIMESTAMP`, and corresponding `LABEL org.opencontainers.image.*` stanzas

### INV — Invariants Documentation

- [x] **INV-04**: `docs/invariants.md` documents INV-04: deployed image tag on each Coolify app must equal the build SHA (verified by `verify-promotion` job)
- [x] **INV-05**: `docs/invariants.md` documents INV-05: production smoke test must pass before the workflow completes

## v1.0 Requirements (Completed)

- ✓ Fix `generate-workflow.sh`: `needs: [deploy-staging, build]` + smoke URL `/api/health` — Phase 01
- ✓ Fix `provision.sh`: Doppler `returncode` check, hard-fail with per-key error — Phase 01
- ✓ Fix `provision.sh`: `server_name` read from `coolify.json` (default `localhost`) — Phase 01
- ✓ E2E test fails fast with actionable error when `E2E_SERVER`/`E2E_BASE_DOMAIN` unset — Phase 02.1
- ✓ `SKILL.md` accurately describes provision flow — Phase 02.1
- ✓ `README.md` Quick start section — Phase 02.1
- ✓ `references/api-reference.md` uses placeholders — Phase 02.1
- ✓ `test/cleanup-deployment.sh` — report-driven teardown — Phase 03
- ✓ Idempotent Coolify provisioning via `/setup-coolify`
- ✓ Same-image promotion CI/CD pipeline (build once → staging → production)

## Future Requirements

### Health endpoint convention

- **HEALTH-01**: Apps expose `{"status":"ok","version":"sha-XXXXXXX","built_at":"..."}` from their health endpoint for full version assertion coverage

## Out of Scope

| Feature | Reason |
|---------|--------|
| VPS-level docker inspect verification | SSH round-trip adds latency and VPS dependency; Coolify API confirmation + health response covers the same ground more portably |
| Coolify deployment log streaming | Log fetching is advisory; status polling catches failures; full log scraping adds complexity without proportionate value |
| Per-commit digest pinning in Coolify (by digest rather than tag) | Short SHA tags are sufficiently unique in practice; digest pinning requires non-standard Coolify API support |
| Live GitHub Actions pipeline execution as part of test | Static validation covers workflow correctness; live CI adds external dependency |
| Production deployment validation beyond smoke test | Staging smoke test is sufficient trust signal for same-image promotion |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| DIAG-01 | Phase 06 | Complete |
| DIAG-02 | Phase 06 | Complete |
| POLL-01 | Phase 05 | Complete |
| POLL-02 | Phase 05 | Complete |
| SMOKE-01 | Phase 07 | Complete |
| SMOKE-02 | Phase 07 | Complete |
| SMOKE-03 | Phase 07 | Complete |
| PROMOTE-01 | Phase 06 | Complete |
| PROMOTE-02 | Phase 06 | Complete |
| LAYER3-01 | Phase 07 | Complete |
| LAYER3-02 | Phase 07 | Complete |
| INV-04 | Phase 06 | Complete |
| INV-05 | Phase 06 | Complete |

**Coverage:**
- v1.1 requirements: 13 total
- Mapped to phases: 13
- Unmapped: 0 ✓

---
*Requirements defined: 2026-05-21*
*Last updated: 2026-06-13 — milestone v1.1 traceability filled in*
