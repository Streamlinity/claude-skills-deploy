---
plan: 08-02
phase: 08-workflow-defect-fixes
status: complete
requirements_satisfied: [LAYER3-01]
gap_closure: GAP-2
self_check: PASSED
key-files:
  modified:
    - test/validate-workflow-contract.sh
---

# Summary: 08-02 — GAP-2 C9 contract rule narrowed

## What was built

Refined the C9 check in `test/validate-workflow-contract.sh` from a blanket `build-args` rejection to a targeted env-specific detection:

**Before (blanket rejection):**
```bash
if grep -qE '^\s*build-args:' "$WF"; then
  fail "C9: build-args present — env-specific builds break same-image promotion"
```

**After (targeted rejection):**
```bash
if grep -qE '^\s*build-args:' "$WF"; then
  env_specific=$(grep -A5 'build-args:' "$WF" | grep -v 'GIT_SHA\|BUILD_TIMESTAMP' | grep -c '=') || true
  if [ "$env_specific" -gt 0 ]; then
    fail "C9: env-specific build-args present — breaks same-image promotion"
  else
    pass "C9: build-args are identity-only (GIT_SHA/BUILD_TIMESTAMP) — same-image promotion preserved"
  fi
```

## Commits

- `fix(08-02): narrow C9 check to allow identity-only build-args` — surgical 9-line replacement

## Verification

Round-trip test: generated workflow with GIT_SHA/BUILD_TIMESTAMP build-args (from Phase 07) passes C9. The contract test exits 0 on Phase-07-generated workflows. NEXT_PUBLIC_BASE_URL would still be rejected by the refined check.

## Impact

- `bash test/validate-workflow-contract.sh` exits 0 on any workflow generated after Phase 07
- LAYER3-01 fully satisfied (implementation correct; contract self-verification now unblocked)
- GAP-2 closed
