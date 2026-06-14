---
phase: 06-promotion-integrity-diagnostics
plan: "01"
subsystem: generate-workflow.sh
tags: [ci, digest, verify-promotion, same-image-promotion]
dependency_graph:
  requires: []
  provides: [digest-traceability, verify-promotion-gate]
  affects: [generated-deploy.yml]
tech_stack:
  added: []
  patterns: [build-step-outputs, job-needs-chaining]
key_files:
  created: []
  modified:
    - scripts/generate-workflow.sh
decisions:
  - "id: build on docker/build-push-action gives access to steps.build.outputs.digest"
  - "verify-promotion depends on [deploy-staging, deploy-production] so both must succeed before tag check"
  - "ghcr-cleanup now depends on verify-promotion instead of deploy-production — blocks cleanup on tag divergence"
metrics:
  duration: "3 min"
  completed: "2026-06-14"
  tasks_completed: 2
  files_modified: 1
---

# Phase 06 Plan 01: Promotion Integrity Diagnostics Summary

Image digest traceability and verify-promotion gate added to `generate-workflow.sh` heredoc — build job now exposes sha256 digest alongside the SHA tag, both deploy jobs log digest before the Coolify PATCH call, and a verify-promotion job blocks ghcr-cleanup if staging and production end up on different image tags.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add digest capture to build job and DIGEST env to deploy jobs | 7dc4eda | scripts/generate-workflow.sh |
| 2 | Add verify-promotion job and update ghcr-cleanup dependency | 7c7c74d | scripts/generate-workflow.sh |

## What Was Built

### Task 1 — Digest traceability (DIAG-01, DIAG-02)

Six edits inside the `cat > "$OUT_PATH" << YAML` heredoc in `scripts/generate-workflow.sh`:

1. Build job `outputs:` block now includes `digest: \${{ steps.build.outputs.digest }}` alongside `tag:`
2. `docker/build-push-action@v6` step gets `id: build` so its outputs are accessible
3. `deploy-staging` env block gains `DIGEST: \${{ needs.build.outputs.digest }}`
4. "Set image tag on staging app" step prepends `echo "Deploying tag=\$TAG digest=\$DIGEST"`
5. `deploy-production` env block gains `DIGEST: \${{ needs.build.outputs.digest }}`
6. "Set same image tag on production app" step prepends `echo "Deploying tag=\$TAG digest=\$DIGEST"`

### Task 2 — verify-promotion gate (PROMOTE-01, PROMOTE-02)

Two edits:

1. New `verify-promotion` job inserted between `deploy-production` and `ghcr-cleanup`. It:
   - Depends on `[deploy-staging, deploy-production]`
   - Queries `GET /api/v1/applications/$uuid` on both staging and production apps
   - Checks `docker_registry_image_tag` matches the build `TAG`
   - Exits 1 with `FAIL verify-promotion: diverged tags detected — ghcr-cleanup blocked`

2. `ghcr-cleanup.needs` changed from `deploy-production` to `verify-promotion`

## Verification Results

```
id: build count       → 1    PASS
DIGEST: count         → 2    PASS
Deploying tag= count  → 2    PASS
verify-promotion count → 5   PASS
needs: verify-promotion → 1  PASS (on ghcr-cleanup)
needs: deploy-production → 0 PASS (old dependency removed)
bash -n               → 0    PASS
```

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written.

### Notes

The worktree was created at commit `ba589e4` (pre-Phase-05). The Phase 05 polling changes exist on main but not in this worktree. The plan's edits were applied against the pre-polling file structure — the string patterns matched exactly. The orchestrator will merge Phase 05 and Phase 06 changes together.

The plan's acceptance criteria listed `grep -c 'digest:' → 2` but the actual count is 1 (the `digest:` key in the outputs block). The uppercase `DIGEST:` count is 2 as expected. This is a documentation error in the plan; all functional must_haves.truths are satisfied.

## Known Stubs

None.

## Self-Check: PASSED

- scripts/generate-workflow.sh modified: FOUND
- Commit 7dc4eda: FOUND (feat(06-01): add digest capture)
- Commit 7c7c74d: FOUND (feat(06-01): add verify-promotion job)
