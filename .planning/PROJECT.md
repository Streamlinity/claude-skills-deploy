# claude-skills-deploy

## What This Is

A Claude Code skills repo that provides a standardized, domain-agnostic way to deploy any application onto a Coolify + Doppler managed CI/CD environment running on a VPS. The skill provisions staging and production apps, wires in Doppler secrets, and generates a same-image-promotion GitHub Actions pipeline — all from a single `coolify.yaml` manifest committed to the target repo. It is designed to be forked to support additional domains (e.g., `strategem.ai` alongside `streamlinity.com`) with zero script changes.

## Core Value

A developer can clone this repo, run one command, see a working hello-world deployment on their Coolify server, and trust the skill is correct before using it for a real application.

## Requirements

### Validated

- ✓ Fix `generate-workflow.sh`: `needs: [deploy-staging, build]` + smoke URL `/api/health` — Validated in Phase 01: bug-fixes
- ✓ Fix `provision.sh`: Doppler `returncode` check, hard-fail with per-key error — Validated in Phase 01: bug-fixes
- ✓ Fix `provision.sh`: `server_name` read from `coolify.json` (default `localhost`) — Validated in Phase 01: bug-fixes
- ✓ `test/e2e.sh` fails fast with actionable error when `E2E_SERVER`/`E2E_BASE_DOMAIN` unset (ONBOARD-01, ONBOARD-02) — Validated in Phase 02.1: new-user-onboarding
- ✓ `SKILL.md` accurately describes provision flow (no dead-code refs, no false deploy claims, generic examples) (ONBOARD-03, ONBOARD-04, ONBOARD-05) — Validated in Phase 02.1: new-user-onboarding
- ✓ `README.md` opens with 5-command Quick start above Prerequisites (ONBOARD-06) — Validated in Phase 02.1: new-user-onboarding
- ✓ `references/api-reference.md` uses placeholders, no maintainer-specific domains (ONBOARD-07) — Validated in Phase 02.1: new-user-onboarding
- ✓ `test/cleanup-deployment.sh` — report-driven teardown of Coolify apps + project + Docker volumes + Doppler project (CLEAN-01, CLEAN-02) — Validated in Phase 03: cleanup-script
- ✓ Idempotent Coolify provisioning via `/setup-coolify` — existing
- ✓ Dry-run pre-flight validation via `/setup-coolify validate` — existing
- ✓ Interactive repo bootstrap via `bash init/init.sh` (writes `coolify.yaml` + `deploy.yml`) — existing
- ✓ Multi-server support via `coolify.json` server alias lookup — existing
- ✓ Domain-agnostic deployment config — zero script changes between domains — existing
- ✓ Coolify app creation + bulk env var injection — existing
- ✓ Doppler service token creation and rotation per environment — existing
- ✓ Docker volume creation via SSH for Doppler fallback cache — existing
- ✓ Same-image promotion CI/CD pipeline (build once → staging → production) — existing
- ✓ Generated `.github/workflows/deploy.yml` — existing

## Current Milestone: v1.1 Deployment Correctness

**Goal:** Make same-image promotion verifiably correct by adding image digest tracking, deployment polling, a production smoke test, and a cross-environment assertion gate to the generated deploy.yml.

**Target features:**
- Image digest capture and logging from build step (Layer 1)
- ✓ Coolify deployment API polling — pull failures surface immediately (Layer 2) — Validated in Phase 05: deployment-polling
- Enhanced smoke test with runtime version/SHA assertion (Layer 3)
- `verify-promotion` job asserting tag match before ghcr-cleanup (Layer 4)
- Production smoke test (currently absent)
- INV-04 and INV-05 in docs/invariants.md

### Active

- DIAG-01, DIAG-02: Image digest capture + logging (Phase 06)
- PROMOTE-01, PROMOTE-02: verify-promotion job + ghcr-cleanup gate (Phase 06)
- INV-04, INV-05: invariants documentation (Phase 06)
- SMOKE-01, SMOKE-02, SMOKE-03: version assertion in staging + production smoke tests (Phase 07)
- LAYER3-01, LAYER3-02: GIT_SHA/BUILD_TIMESTAMP build-args + OCI labels (Phase 07)

### Out of Scope

- Live GitHub Actions pipeline execution as part of test — static validation covers workflow correctness; live CI adds external dependency and slow feedback
- Production deployment validation — staging smoke test is sufficient for trust signal
- Multi-node Coolify support — target architecture is single-node; `server_name` default of `localhost` covers the common case
- Per-env build mode (`build_time: true`) — field is reserved for future use; current same-image promotion model is the target behavior

## Context

- The core skill was developed and validated through the deployment of `git@github.com:anatesan-stream/ai-upskilling.git` — that work proved out the Coolify + Doppler approach
- Work is continuing in this repo after a `/clear` interrupted a previous session in a different working directory; `test/e2e.sh` exists but has not been run against real infrastructure
- The codebase audit (`CONCERNS.md`) identified 3 HIGH bugs that would cause the E2E test to fail — fixing them is the first phase of work
- Test audience: new users onboarding to the skill, maintainers running CI on this repo, developers forking for a new domain (e.g., strategem.ai)
- The hello-world test container (`test/hello-world/`) is a minimal nginx image serving `/api/health` → 200 and `index.html` with a known sentinel string
- The test should leave the hello-world deployment running so a new user can browse to the staging URL and see proof of a working deployment before running cleanup

## Constraints

- **No auto-cleanup**: E2E test must not tear down the deployment — new users need to see the result
- **Domain portability**: Any hardcoded `streamlinity.com` references in the test harness must become env vars — the test must run on any Coolify server
- **No GitHub API dependency**: Test framework must not require a live GitHub push or Actions run — runs standalone on the operator's machine
- **Bash + Python3 only**: No new language runtimes or package managers — the skill is pure shell + python3 (pyyaml); test tooling must stay in this stack

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Static workflow validation instead of live GitHub Actions run | Avoids external dependency, catches structural bugs fast (like the `smoke-staging` job name bug) | Validated — Phase 02 complete (`test/validate-workflow.sh`) |
| No auto-cleanup in E2E test on success | New users need to see the deployed result to build trust in the skill | Validated — Phase 02 complete (cleanup skipped when exit_code=0) |
| `test/cleanup-deployment.sh` reads from JSON report file | Decouples teardown from e2e.sh; operator can inspect deployment first then run cleanup explicitly | Validated — Phase 03 complete |
| Fix HIGH bugs before building test framework | E2E test would fail for the wrong reasons if workflow generation is broken | Validated — Phase 01 complete |
| `E2E_BASE_DOMAIN` + `E2E_SERVER` env vars for portability | Allows domain fork developers to run the same test against their Coolify server without editing the script | Validated — Phase 02 complete |
| Test report written to `test/results/` | Persists pass/fail state and URLs between test run and cleanup; enables maintainer CI assertions | Validated — Phase 02 complete (JSON report, written on pass and fail) |
| `GHCR_TOKEN` stored in Doppler `claude-skills-deploy/stg` | Operator credential for pushing test image; Doppler ensures any team member can run E2E tests without out-of-band secret sharing; teardown never touches this project | Validated — Phase 02 setup |
| `workflow_dispatch` CI job (`push-test-image.yml`) for test image | Zero-PAT path for forkers — uses `GITHUB_TOKEN` with `packages: write`; no separate credential needed | Validated — Phase 02 setup |

## Evolution

**Current state:** Milestone v1.0 complete. All requirements validated. Live E2E + cleanup verified 2026-05-26 against vultr-stream. Post-verification: 3 bugs fixed in cleanup-deployment.sh; docs expanded (DNS setup, test-environment.md, architecture diagrams).

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-13 — Milestone v1.1: Deployment Correctness started*
