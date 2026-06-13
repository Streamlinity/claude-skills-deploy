---
phase: 05-deployment-polling
plan: 01
subsystem: infra
tags: [coolify, github-actions, deployment-polling, ci-cd, bash]

# Dependency graph
requires: []
provides:
  - Coolify deployment status polling in generated deploy.yml for both staging and production jobs
  - deployment_uuid extraction from Coolify trigger response via jq
  - 36-iteration polling loop (10s interval, 6 min max) with [N/36] status=STATUS log output
  - Immediate exit on status=failed or cancelled with deployment_uuid and Coolify UI URL on stderr
  - Timeout exit after 6 minutes with deployment_uuid and Coolify UI URL on stderr
affects: [06-diag-promote-inv, any phase regenerating deploy.yml via generate-workflow.sh]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "trigger → capture deployment_uuid via jq → poll /api/v1/deployments/{uuid} → gate on status=finished"
    - "timed_out=1 flag pattern for post-loop timeout detection without subshell"

key-files:
  created: []
  modified:
    - scripts/generate-workflow.sh

key-decisions:
  - "36 retries x 10s = 6 min max poll window — matches existing smoke test duration; failure surfaces within one cycle instead of after full 6-min health timeout"
  - "timed_out=1 flag (not subshell or pipeline) for timeout detection — keeps bash set -euo pipefail compatibility"
  - "cancelled status treated same as failed — both are terminal non-success states from Coolify API"
  - "5s initial sleep before first poll — gives Coolify a moment to record the deployment before first query"

patterns-established:
  - "Poll pattern: trigger → jq extract deployment_uuid → seq 1 36 loop → status=finished break → timed_out gate"
  - "Error messages always include deployment_uuid and Coolify UI URL on stderr for operator debugging"

requirements-completed:
  - POLL-01
  - POLL-02

# Metrics
duration: 2min
completed: 2026-06-13
---

# Phase 05 Plan 01: Deployment Polling Summary

**Coolify deployment API polling added to both deploy-staging and deploy-production jobs — pull failures surface within 10s instead of timing out on health endpoint after 6 minutes**

## Performance

- **Duration:** 2 min
- **Started:** 2026-06-13T20:54:22Z
- **Completed:** 2026-06-13T20:56:15Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Replaced fire-and-forget staging trigger with combined trigger+poll step that captures `deployment_uuid` via jq and polls `/api/v1/deployments/{uuid}` up to 36 times at 10s intervals
- Replaced fire-and-forget production trigger with identical polling pattern using `PROD_APP_UUID`
- Both deploy jobs now log `[N/36] status=STATUS` on every poll and exit non-zero immediately on `status=failed`, `status=cancelled`, or 6-minute timeout — with `deployment_uuid` and Coolify UI URL on stderr
- Generated `deploy.yml` passes `python3 yaml.safe_load` validation; `bash -n` syntax check passes on `generate-workflow.sh`

## Task Commits

Each task was committed atomically:

1. **Task 1: Add trigger+poll step to deploy-staging job** - `dec5c4b` (feat)
2. **Task 2: Add trigger+poll step to deploy-production job and validate** - `a9fedac` (feat)

**Plan metadata:** _(docs commit to follow)_

## Files Created/Modified

- `scripts/generate-workflow.sh` - Heredoc template updated: both deploy-staging and deploy-production steps now trigger + poll Coolify deployment status before proceeding

## Decisions Made

- **36 retries x 10s = 6 min window** — matches the existing smoke test max duration; operator waits the same total time but gets a meaningful failure message immediately instead of ambiguous health timeout
- **`timed_out=1` flag** (not subshell/pipeline) — compatible with `set -euo pipefail` inside the generated workflow run step
- **`cancelled` treated as failure** — both `failed` and `cancelled` are terminal non-success states from the Coolify API; both exit non-zero
- **5s initial sleep** before first poll — gives Coolify time to register the deployment record before querying it

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. Both edits applied cleanly. Generated YAML valid. Bash syntax check passed.

## User Setup Required

None - no external service configuration required. Changes are to the workflow generator; deployed repos will receive updated `deploy.yml` on next `/setup-coolify` run.

## Next Phase Readiness

- Phase 05 complete. `generate-workflow.sh` now generates polling-enabled `deploy.yml` for all new and re-provisioned repos.
- Ready for Phase 06 (DIAG + PROMOTE + INV layer) which also modifies `generate-workflow.sh` heredoc.

---
*Phase: 05-deployment-polling*
*Completed: 2026-06-13*
