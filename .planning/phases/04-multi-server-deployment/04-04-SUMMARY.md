---
phase: 04-multi-server-deployment
plan: 04
subsystem: testing
tags: [testing, bash, coolify, regression]

requires:
  - phase: 04-multi-server-deployment
    provides: "validate.sh core implementation (Plan 1)"
provides:
  - "test/validate-deploy-server.sh MSRV-03 regression test"
affects: [infra, testing]

tech-stack:
  added: []
  patterns: [Unit-style integration test runner for scripts/validate.sh]

key-files:
  created:
    - test/validate-deploy-server.sh
  modified: []

key-decisions:
  - "Ran the test against the live 'vultr-stream' Coolify instance without mocking the HTTP responses to ensure validation checks align with real API behavior."

patterns-established: []

requirements-completed:
  - MSRV-03

duration: 10min
completed: 2026-06-07
---

# Phase 4 Plan 4: validate-deploy-server.sh Regression Test — Summary

**Created a unit-style bash regression test that verifies scripts/validate.sh rejects unregistered deploy_server targets and baseline backward-compatible deployments run successfully.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-06-07T16:05:40-07:00
- **Completed:** 2026-06-07T16:06:20-07:00
- **Tasks:** 3
- **Files modified:** 1 (created)

## Accomplishments
- Implemented [test/validate-deploy-server.sh](./test/validate-deploy-server.sh) to test `validate.sh` against the live Coolify instance.
- Verified that specifying an unregistered `deploy_server` exits non-zero, names the unregistered server, and lists registered servers.
- Verified that omitting `deploy_server` skips the validation check entirely to preserve backward compatibility.
- Ensured automated cleanup of test fixtures using bash trap handlers on exit.

## Task Commits

1. **Task 1: Confirm test runs against real Coolify (env precondition)** - Confirmed `vultr-stream` reachability.
2. **Task 2: Create test/validate-deploy-server.sh** - Created script and verified syntax/traceability.
3. **Task 3: Run the test against real Coolify and confirm green** - Test run completed successfully against real backend.

## Files Created/Modified
- [test/validate-deploy-server.sh](file:///home/cnut/development/claude-skills-deploy/test/validate-deploy-server.sh) — regression test runner (121 lines, executable).

## Decisions Made
- None - followed plan as specified.

## Deviations from Plan
- None - plan executed exactly as written.

## Issues Encountered
- None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All Phase 4 plans are now completed and verified.
- The milestone v1.0 has been fully updated and tested.

## Test Run Output (Task 3)

```
── Case 1: deploy_server=csd-validate-test-nonexistent-1780873564-1877416 (nonexistent) → expect non-zero exit + named-server error ──
  PASS: validate.sh exited non-zero (rc=1)
  PASS: stderr names the offending deploy_server value (csd-validate-test-nonexistent-1780873564-1877416)
  PASS: stderr includes 'not registered in Coolify' phrase
  PASS: stderr lists available servers ('available:' marker present)

── Case 2: deploy_server absent (baseline) → MSRV-03 check skipped ──
  PASS: stderr does NOT contain a deploy_server fail line (MSRV-06 backward compat)
  PASS: stderr does NOT contain the deploy_server success log (check fully skipped)

── Summary ──
  PASS: 6
  FAIL: 0

RESULT: validate-deploy-server PASSED (6 checks)
```

- **Server alias used:** `vultr-stream`
- **Total line count of test/validate-deploy-server.sh:** 121 lines
