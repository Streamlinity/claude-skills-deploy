---
phase: 07-runtime-identity
plan: "01"
subsystem: infra
tags: [github-actions, docker, coolify, smoke-test, build-args, oci-labels]

# Dependency graph
requires:
  - phase: 06-promotion-integrity-diagnostics
    provides: "verify-promotion job, DIGEST tracking, drift-check — generate-workflow.sh baseline"
  - phase: 05-deployment-polling
    provides: "Coolify deployment status polling, timed_out pattern — generate-workflow.sh baseline"
provides:
  - "GIT_SHA and BUILD_TIMESTAMP identity build-args baked into Docker image"
  - "Assert staging version step with graceful skip when version field absent"
  - "PROD_DOMAIN env var in deploy-production job"
  - "Smoke test production health loop (12x30s)"
  - "Assert production version step with graceful skip"
affects: [07-02-plan, any-repo-using-generate-workflow-sh]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Identity-only build-args exception: GIT_SHA/BUILD_TIMESTAMP do not break same-image promotion because they are identical across staging and production"
    - "Graceful-skip assertion: version field absent → SKIP log + exit 0; allows incremental adoption"
    - "Separate steps per concern: health loop step distinct from version assert step"

key-files:
  created: []
  modified:
    - "scripts/generate-workflow.sh"

key-decisions:
  - "GIT_SHA value source: steps.tag.outputs.short_sha — already computed, matches GHCR tag; OCI revision label equals image tag"
  - "BUILD_TIMESTAMP value source: github.event.head_commit.timestamp — commit creation time, stable and reproducible"
  - "Version assertion format: sha-$TAG (e.g. sha-abc1234) — matches ROADMAP success criteria"
  - "Graceful skip: empty version field exits 0 with SKIP log — blocks nothing, unblocks non-adopters"
  - "Production smoke test uses same 12x30s cadence as staging — container startup time equivalent"
  - "PROD_DOMAIN added to deploy-production job-level env block — same pattern as STAGING_DOMAIN in deploy-staging"

patterns-established:
  - "Pattern: SKIP version-assert — echo 'SKIP version-assert: health response has no version field' then exit 0"
  - "Pattern: version assert compares jq -r '.version // empty' against sha-$TAG"

requirements-completed: [LAYER3-01, SMOKE-01, SMOKE-02, SMOKE-03]

# Metrics
duration: 4min
completed: 2026-06-16
---

# Phase 07 Plan 01: Runtime Identity Summary

**Identity build-args (GIT_SHA, BUILD_TIMESTAMP) added to build job; version assertion steps with graceful skip added to staging and production; production smoke test added**

## Performance

- **Duration:** 4 min
- **Started:** 2026-06-16T21:42:25Z
- **Completed:** 2026-06-16T21:46:59Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Build job now passes `GIT_SHA=${{ steps.tag.outputs.short_sha }}` and `BUILD_TIMESTAMP=${{ github.event.head_commit.timestamp }}` as build-args, baking OCI revision/created labels into images
- `Assert staging version` step added after `Smoke test staging` — captures health response body and asserts `version == sha-$TAG`, exits 0 with SKIP log when field absent
- `PROD_DOMAIN` added to `deploy-production` job `env:` block — expands at generate-workflow.sh runtime from bash-scope variable
- `Smoke test production` step added (12x30s retry loop matching staging cadence)
- `Assert production version` step added mirroring staging assertion with identical graceful-skip pattern

## Task Commits

1. **Task 1: Add GIT_SHA and BUILD_TIMESTAMP build-args to build job** - `78114b7` (feat)
2. **Task 2: Add staging version assertion + production smoke test + production version assertion** - `e742fe8` (feat)

## Files Created/Modified

- `scripts/generate-workflow.sh` - Four edits: preamble comment, heredoc NOTE comment, build-args block replacing old no-build-args comment, new Assert/Smoke steps, PROD_DOMAIN env entry, echo summary update

## Decisions Made

- Identity-only exception to no-build-args policy: `GIT_SHA` and `BUILD_TIMESTAMP` are identical for staging and production (same commit, same timestamp), so they do not break same-image promotion
- Graceful skip pattern (exit 0 with SKIP log) rather than hard-fail when `version` field absent — allows incremental adoption without blocking CI

## Deviations from Plan

**Pre-task deviation: merged main into worktree branch**

The worktree branch was created before Phase 05 and 06 changes were merged to main. The plan's file references (generate-workflow.sh structure with polling and verify-promotion) assumed those changes were present. Merged `main` into the worktree branch via fast-forward before starting Task 1.

This is not a deviation from plan intent — it restored the expected baseline state.

Otherwise: None — plan executed exactly as written.

## Issues Encountered

None after baseline restoration.

## Next Phase Readiness

- Phase 07 Plan 02 (Dockerfile scaffold for OCI labels) can proceed immediately — no blocking issues
- `scripts/generate-workflow.sh` is the only file modified; no downstream script changes needed

---
*Phase: 07-runtime-identity*
*Completed: 2026-06-16*
