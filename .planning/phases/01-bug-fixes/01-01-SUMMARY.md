---
phase: 01-bug-fixes
plan: "01"
subsystem: scripts/generate-workflow.sh
tags: [bug-fix, workflow-generation, github-actions]
dependency_graph:
  requires: []
  provides: [BUG-01-fixed]
  affects: [scripts/generate-workflow.sh]
tech_stack:
  added: []
  patterns: [heredoc-yaml-generation, bash-surgery]
key_files:
  created: []
  modified:
    - scripts/generate-workflow.sh
decisions:
  - "D-01: needs: [smoke-staging, build] → needs: [deploy-staging, build] — smoke test is a step inside deploy-staging, not a separate job"
  - "D-02: smoke test URL / → /api/health — aligns with Coolify health_check_path set in provision.sh and e2e.sh polling pattern"
metrics:
  duration: "~2 minutes"
  completed: "2026-05-22"
  tasks_completed: 2
  files_changed: 1
---

# Phase 01 Plan 01: Fix generate-workflow.sh heredoc bugs (BUG-01) Summary

Two surgical single-line edits to the `cat > "$OUT_PATH" << YAML` heredoc in `scripts/generate-workflow.sh` — correcting a non-existent job reference (`smoke-staging` → `deploy-staging`) and aligning the smoke test URL (`/` → `/api/health`).

## What Was Done

### Task 1: Fix non-existent job reference and smoke test URL

**Edit 1 — Line 138:** Smoke test curl target.

```diff
-            if curl -sfS "https://\$STAGING_DOMAIN/" -o /dev/null; then
+            if curl -sfS "https://\$STAGING_DOMAIN/api/health" -o /dev/null; then
```

Rationale: `provision.sh` PATCHes the Coolify app with `health_check_path: /api/health`, and `test/e2e.sh` polls `/api/health`. The generated workflow must use the same endpoint.

**Edit 2 — Line 146:** `deploy-production` job dependency.

```diff
-    needs: [smoke-staging, build]
+    needs: [deploy-staging, build]
```

Rationale: There is no job named `smoke-staging` in the generated file. The smoke test is a step inside the `deploy-staging` job. GitHub Actions rejects a workflow that references a non-existent job in a `needs:` list.

### Task 2: End-to-end validation

Generated a minimal `coolify.yaml` in `/tmp` and ran `generate-workflow.sh` against it. Confirmed:

- Output parses as valid YAML (`python3 yaml.safe_load`)
- `needs: [deploy-staging, build]` present in `deploy-production` job
- `https://$STAGING_DOMAIN/api/health` present in smoke test step
- `smoke-staging` absent from entire file
- Every job referenced in any `needs:` list exists as a defined job (Python dependency graph check)

## Verification Results

```
146:    needs: [deploy-staging, build]          ✓
138:    if curl -sfS "https://\$STAGING_DOMAIN/api/health"   ✓
smoke-staging: not found                       ✓
bash -n scripts/generate-workflow.sh: exit 0   ✓
YAML parse of generated deploy.yml: PASS       ✓
OK: all needs references resolve to defined jobs ✓
```

## Deviations from Plan

None — plan executed exactly as written. Both edits were single-line changes; no surrounding lines were modified.

## Known Stubs

None.

## Self-Check: PASSED

- `scripts/generate-workflow.sh` exists and contains both fixes
- Commit `1ef43d7` confirmed in git log
