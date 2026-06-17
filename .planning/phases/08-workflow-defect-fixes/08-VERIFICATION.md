---
phase: 08-workflow-defect-fixes
verified: 2026-06-16T00:00:00Z
status: passed
score: 8/8 must-haves verified
re_verification: false
human_verification:
  - test: "Run a full GitHub Actions workflow on a real repo after this fix"
    expected: "verify-promotion job passes (TAG resolves to the actual build SHA, not empty string); ghcr-cleanup runs after verify-promotion succeeds"
    why_human: "TAG resolution can only be confirmed in a live GitHub Actions run — static analysis confirms the structural fix (build in needs) but cannot observe runtime output variable expansion"
---

# Phase 08: Workflow Defect Fixes Verification Report

**Phase Goal:** Close the two active integration defects identified by the v1.1 milestone audit — the verify-promotion TAG resolution bug that makes every promotion assertion fail, and the contract test C9 rule that rejects valid identity build-args — restoring PROMOTE-01, INV-04, and LAYER3-01 to verified status
**Verified:** 2026-06-16
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | verify-promotion job `needs` array includes `build` | ✓ VERIFIED | `generate-workflow.sh` line 260: `needs: [deploy-staging, deploy-production, build]`; old form absent |
| 2 | Generated `deploy.yml` verify-promotion job has correct needs array | ✓ VERIFIED | Round-trip generate → contract validate: 12/12 pass (includes structural check C10) |
| 3 | TAG env var structurally wired to `needs.build.outputs.tag` | ✓ VERIFIED | Line 267: `TAG: \${{ needs.build.outputs.tag }}`; `build` is now in `needs`, so GitHub Actions will populate this |
| 4 | C9 check allows GIT_SHA and BUILD_TIMESTAMP (identity-only) | ✓ VERIFIED | `validate-workflow-contract.sh` line 172 filters out `GIT_SHA\|BUILD_TIMESTAMP`; direct logic test: 0 env_specific count for these args |
| 5 | C9 check still rejects env-specific build-args like NEXT_PUBLIC_BASE_URL | ✓ VERIFIED | Direct C9 logic test with `NEXT_PUBLIC_BASE_URL=...` → env_specific=1 → would fail C9 |
| 6 | `bash test/validate-workflow-contract.sh` exits 0 on Phase-07-generated workflow | ✓ VERIFIED | Standalone run: 12/12 pass, exit 0; C9 reports "build-args are identity-only" |
| 7 | INV-05 Enforced-by references actual implemented steps | ✓ VERIFIED | `docs/invariants.md` lines 127-128: `Smoke test production` and `Assert production version` |
| 8 | No `(planned:` markers remain in `docs/invariants.md` | ✓ VERIFIED | `grep '(planned:' docs/invariants.md` → 0 matches |

**Score:** 8/8 truths verified

---

### Required Artifacts

| Artifact | Provides | Level 1 Exists | Level 2 Substantive | Level 3 Wired | Status |
|----------|----------|----------------|---------------------|---------------|--------|
| `scripts/generate-workflow.sh` | verify-promotion with `needs: [deploy-staging, deploy-production, build]` | ✓ | ✓ | ✓ wired to GitHub Actions runtime via needs | ✓ VERIFIED |
| `test/validate-workflow-contract.sh` | C9 rule allowing GIT_SHA/BUILD_TIMESTAMP, rejecting env-specific | ✓ | ✓ | ✓ self-contained; generates fixture + validates | ✓ VERIFIED |
| `docs/invariants.md` | INV-05 Enforced-by references Smoke test production + Assert production version | ✓ | ✓ | ✓ documentation; references concrete generated steps | ✓ VERIFIED |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `verify-promotion` job | `build` job `outputs.tag` | `needs: [deploy-staging, deploy-production, build]` | ✓ WIRED | Line 260 confirmed; TAG defined as `${{ needs.build.outputs.tag }}` at line 267 |
| C9 check | generated `deploy.yml` build-args block | `grep -v 'GIT_SHA\|BUILD_TIMESTAMP'` filter | ✓ WIRED | Filter preserves identity-only args, counts remaining `=` occurrences |
| `ghcr-cleanup` job | `verify-promotion` exit status | `needs: verify-promotion` | ✓ WIRED | Line 290: `needs: verify-promotion` unchanged; now functional since verify-promotion can exit 0 |

---

### Data-Flow Trace (Level 4)

Not applicable — no dynamic data rendering components. All artifacts are shell scripts and documentation. The critical data flow (TAG variable resolution at runtime) requires a live GitHub Actions run and is flagged for human verification.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Contract validator exits 0 on current generated workflow | `bash test/validate-workflow-contract.sh` | 12/12 pass, exit 0 | ✓ PASS |
| C9 correctly counts NEXT_PUBLIC_BASE_URL as env-specific | Direct grep pipe test against fixture file | env_specific=1 | ✓ PASS |
| C9 correctly passes GIT_SHA/BUILD_TIMESTAMP as identity-only | Direct grep pipe test against fixture file | env_specific=0 | ✓ PASS |
| `generate-workflow.sh` bash syntax valid | `bash -n scripts/generate-workflow.sh` | exit 0 | ✓ PASS |
| `validate-workflow-contract.sh` bash syntax valid | `bash -n test/validate-workflow-contract.sh` | exit 0 | ✓ PASS |
| TAG runtime resolution produces correct value | Live GitHub Actions run | Cannot test offline | ? SKIP (human required) |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| PROMOTE-01 | 08-01-PLAN.md | verify-promotion CI job asserts same image tag on staging and production | ✓ SATISFIED | Job exists at line 256; needs array now includes `build`; TAG references `needs.build.outputs.tag` |
| INV-04 | 08-01-PLAN.md | `docs/invariants.md` documents INV-04: deployed tag must equal build SHA | ✓ SATISFIED | INV-04 section present at line 87; enforcement references verify-promotion job |
| LAYER3-01 | 08-02-PLAN.md | `generate-workflow.sh` passes GIT_SHA/BUILD_TIMESTAMP as build-args | ✓ SATISFIED | Lines 111-112 emit GIT_SHA and BUILD_TIMESTAMP; C9 no longer rejects them; contract test 12/12 |

**Orphaned requirements:** None — all three IDs declared in plan frontmatter and mapped in REQUIREMENTS.md Traceability table.

**Documentation gap (warning, not blocker):** REQUIREMENTS.md still shows `[ ]` for PROMOTE-01, INV-04, and LAYER3-01 — the checkbox markers and Traceability table status ("Pending") were not updated by any of the three plans. The implementations are complete and verified; the tracking document is stale.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `docs/invariants.md` | 73, 81 | word "placeholder" / "TODO_REPLACE_BEFORE_DEPLOY" | ℹ️ Info | Legitimate usage — refers to placeholder Doppler token values in INV-02 documentation, not stub code |
| `test/validate-workflow-contract.sh` | 40 | `mktemp -d` temp dir creation | ℹ️ Info | Intended behavior — script is self-contained and creates its own fixture environment |

No blockers or warnings found.

**Notable behavior:** `validate-workflow-contract.sh` silently ignores any file path passed as its argument and always operates on its own internally generated fixture workflow. This is by design (documented in the script header) but was confirmed during verification. The argument position in the CLI signature is effectively unused; the script is invoked with no arguments in normal practice.

---

### Human Verification Required

#### 1. TAG Runtime Resolution in GitHub Actions

**Test:** Push a commit to a repo using a workflow generated by the patched `generate-workflow.sh`. Observe the `verify-promotion` job in the Actions run.
**Expected:** The `Assert same image tag on staging and production` step shows `OK verify-promotion uuid=<uuid> tag=sha-<7char>` for both apps and the job exits 0; `ghcr-cleanup` runs after.
**Why human:** GitHub Actions output variable expansion (`needs.build.outputs.tag`) cannot be verified offline. The structural fix (adding `build` to the needs array) is the correct prerequisite, but actual TAG value propagation can only be observed in a live Actions run.

---

### Commits Confirmed

All phase 08 commits verified on `main`:

| Commit | Description |
|--------|-------------|
| `4e2da5a` | `fix(08-01): add build to verify-promotion needs array` — GAP-1 |
| `f164252` | `fix(08-02): narrow C9 check to allow identity-only build-args` — GAP-2 |
| `fbcfeb6` | `docs(08-03): update INV-05 Enforced-by — replace planning placeholder with implemented steps` — DEBT-2 |
| `d1503be` | `chore(08): merge 08-01 worktree` |
| `08a108b` | `chore(08): merge 08-02 worktree` |
| `1011b39` | `chore(08): merge 08-03 worktree` |

---

### Gaps Summary

No gaps. All three success criteria from the Phase 08 roadmap entry are met:

1. `generate-workflow.sh` emits `verify-promotion` with `needs: [deploy-staging, deploy-production, build]` — ✓
2. `test/validate-workflow-contract.sh` exits 0 on Phase-07-generated workflows; C9 correctly scopes to env-specific args — ✓
3. `docs/invariants.md` INV-05 Enforced-by references `Smoke test production` and `Assert production version` — ✓

One documentation inconsistency: REQUIREMENTS.md checkbox markers for PROMOTE-01, INV-04, and LAYER3-01 remain `[ ]` (not updated to `[x]`). The Traceability table still reads "Pending" for all three. This does not block goal achievement but should be corrected in the REQUIREMENTS.md before the v1.1 milestone is declared complete.

---

_Verified: 2026-06-16_
_Verifier: Claude (gsd-verifier)_
