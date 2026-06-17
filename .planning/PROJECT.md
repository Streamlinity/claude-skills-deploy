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

## Requirements

### Validated

- ✓ Fix `generate-workflow.sh`: `needs: [deploy-staging, build]` + smoke URL `/api/health` — v1.0 Phase 01
- ✓ Fix `provision.sh`: Doppler `returncode` check, hard-fail with per-key error — v1.0 Phase 01
- ✓ Fix `provision.sh`: `server_name` read from `coolify.json` (default `localhost`) — v1.0 Phase 01
- ✓ `test/e2e.sh` fails fast with actionable error when `E2E_SERVER`/`E2E_BASE_DOMAIN` unset — v1.0 Phase 02.1
- ✓ `SKILL.md` accurately describes provision flow — v1.0 Phase 02.1
- ✓ `README.md` opens with 5-command Quick start above Prerequisites — v1.0 Phase 02.1
- ✓ `references/api-reference.md` uses placeholders — v1.0 Phase 02.1
- ✓ `test/cleanup-deployment.sh` report-driven teardown — v1.0 Phase 03
- ✓ Multi-server deployment via `deploy_server:` in coolify.yaml — v1.0 Phase 04
- ✓ Deployment polling (36×10s) — pull failures surface within 10s (POLL-01, POLL-02) — v1.1 Phase 05
- ✓ Image digest captured from build and logged in every deploy step (DIAG-01, DIAG-02) — v1.1 Phase 06
- ✓ `verify-promotion` job asserts same image tag on staging and production; gates ghcr-cleanup (PROMOTE-01, PROMOTE-02) — v1.1 Phase 06+08
- ✓ GIT_SHA/BUILD_TIMESTAMP build-args; OCI revision/created labels; version assertion with graceful skip (LAYER3-01, LAYER3-02, SMOKE-01, SMOKE-02, SMOKE-03) — v1.1 Phase 07
- ✓ `docs/invariants.md` documents INV-04 (tag=SHA) and INV-05 (production smoke prerequisite) — v1.1 Phase 06+08
- ✓ Contract test expanded to 16 checks (C11-C14 added: polling loop, version assert steps, verify-promotion needs) — v1.1 audit debt

### Active

- **HEALTH-01**: Apps expose `{"status":"ok","version":"sha-XXXXXXX","built_at":"..."}` for full version assertion coverage — next milestone

### Out of Scope

- Live GitHub Actions pipeline execution as part of test — static validation covers workflow correctness; live CI adds external dependency
- Per-env build mode (`build_time: true`) — reserved for future use; same-image promotion is the target model
- Multi-node Coolify support — single-node with `server_name`/`deploy_server` covers the target use case
- VPS-level docker inspect verification — Coolify API + health response covers same ground more portably
- Per-commit digest pinning in Coolify (by digest rather than tag) — short SHA tags are sufficiently unique; digest pinning requires non-standard Coolify API support

## Context

**Current state:** Milestone v1.1 complete (shipped 2026-06-17). Same-image promotion is now verifiably correct with a 4-layer enforcement chain: digest traceability → deployment polling → verify-promotion assertion → runtime identity. Contract test has 16 checks. E2E test validated against vultr-stream 2026-05-26 (v1.0); v1.1 changes are pure CI generator modifications (no infra changes).

- `scripts/generate-workflow.sh` is the primary artifact — generates a complete `deploy.yml` with deployment polling, verify-promotion, runtime identity build-args, and version assertions
- `test/validate-workflow-contract.sh` has 16 contract checks (C1-C14 + C1b/C8b) covering all invariants
- `docs/invariants.md` documents 5 invariants (INV-01 through INV-05) with 4-layer enforcement table
- Next milestone should address HEALTH-01 (health endpoint convention) to enable full version assertion coverage without graceful-skip fallback
- Test audience: new users onboarding to the skill, maintainers running CI on this repo, developers forking for a new domain (e.g., strategem.ai)

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

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Static workflow validation instead of live GitHub Actions run | Avoids external dependency, catches structural bugs fast | ✓ Validated — Phase 02 |
| No auto-cleanup in E2E test on success | New users need to see the deployed result | ✓ Validated — Phase 02 |
| `test/cleanup-deployment.sh` reads from JSON report file | Decouples teardown from e2e.sh | ✓ Validated — Phase 03 |
| Fix HIGH bugs before building test framework | E2E test would fail for the wrong reasons otherwise | ✓ Validated — Phase 01 |
| `E2E_BASE_DOMAIN` + `E2E_SERVER` env vars for portability | Domain fork developers run same test against their Coolify | ✓ Validated — Phase 02 |
| Test report written to `test/results/` | Persists state between run and cleanup | ✓ Validated — Phase 02 |
| `GHCR_TOKEN` stored in Doppler `claude-skills-deploy/stg` | Operator credential via Doppler for team sharing | ✓ Validated — Phase 02 |
| 36-retry polling (10s interval, 6 min max) | Matches existing smoke test window; failures surface in one cycle | ✓ Validated — Phase 05 |
| `timed_out=1` flag pattern for timeout detection | Compatible with `set -euo pipefail` in generated workflow | ✓ Validated — Phase 05 |
| GIT_SHA/BUILD_TIMESTAMP identity-only build-args exempted from C9 | These are identical across staging/production — do not break same-image promotion | ✓ Validated — Phase 07+08 |
| Graceful-skip version assertion (`exit 0` when `version` field absent) | Allows incremental adoption without blocking CI for apps that haven't adopted HEALTH-01 | ✓ Validated — Phase 07 |
| verify-promotion.needs must include `build` | GitHub Actions only populates `needs.<job>.outputs.*` for jobs in the current job's needs array | ✓ Validated — Phase 08 (fixed GAP-1) |

## Evolution

This document evolves at phase transitions and milestone boundaries.

---
*Last updated: 2026-06-17 — Milestone v1.1 Deployment Correctness shipped*
