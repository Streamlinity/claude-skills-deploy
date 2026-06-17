---
plan: 08-01
phase: 08-workflow-defect-fixes
status: complete
requirements_satisfied: [PROMOTE-01, INV-04]
gap_closure: GAP-1
self_check: PASSED
key-files:
  modified:
    - scripts/generate-workflow.sh
---

# Summary: 08-01 — GAP-1 verify-promotion needs fix

## What was built

One-line fix to `scripts/generate-workflow.sh` line 260: added `build` to the `verify-promotion` job's `needs` array.

**Before:** `needs: [deploy-staging, deploy-production]`
**After:** `needs: [deploy-staging, deploy-production, build]`

GitHub Actions only populates `needs.<job>.outputs.*` for jobs explicitly in the current job's `needs` array. Without `build` in the needs list, `TAG: ${{ needs.build.outputs.tag }}` resolved to empty string at runtime — the assertion `[ "$actual" = "$TAG" ]` always failed (actual SHA ≠ "").

## Commits

- `fix(08-01): add build to verify-promotion needs array` — surgical single-line edit

## Verification

Round-trip test (generate-workflow.sh → validate-workflow-contract.sh): all 12 contract checks passed. The generated deploy.yml now contains `needs: [deploy-staging, deploy-production, build]` for verify-promotion.

## Impact

- PROMOTE-01 machine enforcement restored (assertion can now pass)
- INV-04 machine enforcement restored (verify-promotion exits 0 on matching tags)
- verify-promotion → ghcr-cleanup flow unblocked (ghcr-cleanup was gated on verify-promotion always-failing)
- GAP-1 closed
