---
phase: 03-cleanup-script
plan: "01"
subsystem: test
tags: [cleanup, teardown, coolify, doppler, docker, bash]
dependency_graph:
  requires:
    - test/e2e.sh (writes report file that cleanup-deployment.sh reads)
    - scripts/lib-coolify-api.sh (coolify_load_server, coolify_curl)
    - scripts/lib-doppler-api.sh (doppler_load_account)
    - ~/.claude/coolify.json (server credentials, accessed via lib functions)
  provides:
    - test/cleanup-deployment.sh (operator teardown command for E2E deployments)
  affects:
    - test/e2e.sh (report schema updated to include coolify_project_uuid, ssh_host, doppler_project)
tech_stack:
  added: []
  patterns:
    - warn-and-continue DELETE (coolify_curl || echo warning)
    - eval "$(python3 -c ...)" for JSON field extraction with startup validation
    - SKILL_DIR resolution via BASH_SOURCE[0] for portable lib sourcing
key_files:
  created:
    - test/cleanup-deployment.sh
  modified:
    - test/e2e.sh (write_report() updated to emit required schema fields)
decisions:
  - "Followed D-02 deletion order: staging app → production app → Coolify project → Docker volumes → Doppler project"
  - "Used single eval python3 block to extract and validate all six required fields at startup before any DELETE"
  - "[Rule 1 deviation] Updated e2e.sh write_report() to emit coolify_project_uuid (was project_uuid), ssh_host, and doppler_project — these fields are required by the cleanup schema (D-03) but were missing from the existing report writer"
metrics:
  duration: "3 minutes"
  completed_date: "2026-05-22"
  tasks_completed: 2
  files_changed: 2
---

# Phase 03 Plan 01: Cleanup Script Summary

**One-liner:** Standalone teardown script `test/cleanup-deployment.sh` that reads a JSON E2E report file and deletes all five resource types (Coolify staging app, production app, project, Docker volumes, Doppler project) with warn-and-continue partial failure handling.

## What Was Built

One new file: `test/cleanup-deployment.sh` (~110 lines). Reads the `test/results/YYYYMMDDHHMMSS.json` report produced by `test/e2e.sh`, extracts all resource identifiers, and executes a five-step teardown with no flags or environment variables required from the operator.

## Deletion Sequence Implemented

Steps execute in this exact order (D-02):

1. `DELETE /applications/$STAGING_APP_UUID` — Coolify staging app
2. `DELETE /applications/$PRODUCTION_APP_UUID` — Coolify production app
3. `DELETE /projects/$COOLIFY_PROJECT_UUID` — Coolify project
4. `ssh $SSH_HOST "docker volume rm ${uuid}-doppler-cache"` for both app UUIDs — Docker volumes on VPS
5. `doppler projects delete $DOPPLER_PROJECT --yes` — Doppler project

Each step uses the `&& echo "✓ deleted ..." || echo "⚠ could not delete ..."` warn-and-continue pattern from `e2e.sh` — partial failures are logged but do not abort subsequent steps.

## Validation Behavior (Four Error Paths)

All validation occurs at startup via a single `eval "$(python3 -c ...)"` block — before any DELETE call:

| Error Path | Exit Code | Message |
|-----------|-----------|---------|
| No argument | non-zero | `ERROR: report file path required` |
| File not found | non-zero | `ERROR: report file not found: <path>` |
| Malformed JSON | non-zero | `ERROR: invalid JSON in report file: <detail>` |
| Missing required fields | non-zero | `ERROR: report file missing fields: <field-list>` |

Required fields validated: `server_alias`, `ssh_host`, `coolify_project_uuid`, `staging_app_uuid`, `production_app_uuid`, `doppler_project`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed e2e.sh write_report() report schema mismatch**
- **Found during:** Task 1 — reading the existing `write_report()` function in `test/e2e.sh`
- **Issue:** `write_report()` emitted `"project_uuid"` (not `"coolify_project_uuid"`), and omitted `"ssh_host"` and `"doppler_project"`. The cleanup script validates all six fields on startup; with the old schema it would always exit with `ERROR: report file missing fields: coolify_project_uuid, ssh_host, doppler_project`
- **Fix:** Updated `write_report()` to pass `SSH_HOST` and `TEST_PROJECT` as positional args to the Python heredoc; updated Python to emit `coolify_project_uuid`, `ssh_host`, `doppler_project` fields matching the D-03 schema in RESEARCH.md
- **Files modified:** `test/e2e.sh`
- **Commit:** 6e65612

## Open Follow-ups

- **Live integration depends on Phase 2 producing a compatible report:** The cleanup script cannot be exercised end-to-end until `test/e2e.sh` is run against a real Coolify server. The e2e.sh fix in this plan ensures the report schema is compatible when that run happens.
- **Volume removal fallback:** If the SSH host is unreachable, each `ssh` call will fail and print a warning. Docker volumes will linger on the VPS. Operator should verify volume removal manually if SSH was unavailable during cleanup.

## Self-Check: PASSED

- `test/cleanup-deployment.sh` exists: found
- `test -x test/cleanup-deployment.sh`: passes
- `bash -n test/cleanup-deployment.sh`: exits 0
- Task 1 commit (6e65612): verified via `git log --oneline`
- All four smoke tests: Passed 4 / Failed 0
- Deletion order (line numbers): staging-app=75, prod-app=79, project=85, volumes=93, doppler=100 — ascending order confirmed
