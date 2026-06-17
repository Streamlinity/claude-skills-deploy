---
phase: 06-promotion-integrity-diagnostics
verified: 2026-06-17T00:00:00Z
status: passed
score: 5/5 must-haves verified
re_verification: true
re_verification_reason: "Retroactive verification — formal gsd-verifier not run at phase execution time; this report provides the missing VERIFICATION.md based on direct code inspection"
---

# Phase 06: Promotion Integrity + Diagnostics Verification Report

**Phase Goal:** Same-image promotion is verifiably asserted in CI — staging and production are confirmed on the same image tag before GHCR cleanup runs, with full digest traceability from build through deploy
**Verified:** 2026-06-17 (retroactive)
**Status:** passed
**Re-verification:** Yes — retroactive audit; VERIFICATION.md was absent from original execution

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Build job exposes sha256 digest as a job output alongside the SHA tag | VERIFIED | `scripts/generate-workflow.sh` line 90: `digest: \${{ steps.build.outputs.digest }}` in build job outputs block; `id: build` at line 100 on `docker/build-push-action@v6` makes the output accessible |
| 2 | Both deploy-staging and deploy-production env blocks include DIGEST from the build job | VERIFIED | Line 122: `DIGEST: \${{ needs.build.outputs.digest }}` in deploy-staging env block; line 193: same in deploy-production env block |
| 3 | Both Set-image-tag steps log tag and digest before the Coolify PATCH call | VERIFIED | Line 127: `echo "Deploying tag=\$TAG digest=\$DIGEST"` in deploy-staging; line 198: same in deploy-production |
| 4 | verify-promotion job runs after both deploys and asserts same image tag on staging and production | VERIFIED | Job at line 256; `needs: [deploy-staging, deploy-production, build]` at line 260 (build added by Phase 08 08-01 to fix TAG resolution); queries `GET /api/v1/applications/$uuid` and compares `docker_registry_image_tag` against `$TAG`; exits 1 on divergence |
| 5 | ghcr-cleanup depends on verify-promotion (not deploy-production) | VERIFIED | Line 290: `needs: verify-promotion`; `grep 'needs: deploy-production' scripts/generate-workflow.sh` returns 0 matches |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/generate-workflow.sh` | Digest capture in build job (id: build, digest output) | VERIFIED | Lines 90 (digest output), 100 (id: build) — both present |
| `scripts/generate-workflow.sh` | DIGEST env in both deploy jobs, echo log in both Set-image-tag steps | VERIFIED | Lines 122, 193 (DIGEST env); lines 127, 198 (echo logs) |
| `scripts/generate-workflow.sh` | verify-promotion job between deploy-production and ghcr-cleanup | VERIFIED | Job at line 256; full step with Coolify API query and tag comparison |
| `scripts/generate-workflow.sh` | ghcr-cleanup depends on verify-promotion | VERIFIED | Line 290: `needs: verify-promotion` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `docker/build-push-action@v6` step | `build` job `outputs.digest` | `id: build` on the step + `outputs: digest:` block | WIRED | Lines 90 and 100; `steps.build.outputs.digest` accessible to downstream jobs |
| `build` job `outputs.digest` | DIGEST env in both deploy jobs | `needs.build.outputs.digest` in env blocks | WIRED | Lines 122 and 193 |
| DIGEST env var | deploy step log output | `echo "Deploying tag=$TAG digest=$DIGEST"` | WIRED | Lines 127 and 198 |
| `build` job `outputs.tag` | TAG env in verify-promotion | `needs: [deploy-staging, deploy-production, build]` + `TAG: ${{ needs.build.outputs.tag }}` | WIRED | Line 260 (needs) + line 267 (TAG env); Phase 08 08-01 added `build` to the needs array to fix runtime TAG resolution |
| verify-promotion exit status | ghcr-cleanup gate | `needs: verify-promotion` on ghcr-cleanup | WIRED | Line 290 |

### Data-Flow Trace (Level 4)

Not applicable — artifacts are workflow generator templates, not components rendering dynamic runtime data. The critical data flow (TAG variable resolution) is structural: build job output → needs chain → verify-promotion TAG env.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| generate-workflow.sh bash syntax valid | `bash -n scripts/generate-workflow.sh` | exit 0 | PASS |
| digest output present in build job | `grep -c 'digest:.*steps.build.outputs.digest' scripts/generate-workflow.sh` | 1 | PASS |
| DIGEST env in both deploy jobs | `grep -c 'DIGEST:.*needs.build.outputs.digest' scripts/generate-workflow.sh` | 2 | PASS |
| echo log in both deploy steps | `grep -c 'Deploying tag=.*digest=' scripts/generate-workflow.sh` | 2 | PASS |
| verify-promotion job present | `grep -c 'verify-promotion' scripts/generate-workflow.sh` | 6 | PASS |
| verify-promotion needs includes build | `grep 'needs: \[deploy-staging, deploy-production, build\]' scripts/generate-workflow.sh` | 1 match | PASS |
| ghcr-cleanup gated on verify-promotion | `grep 'needs: verify-promotion' scripts/generate-workflow.sh` | 1 match | PASS |
| old ghcr-cleanup dependency absent | `grep 'needs: deploy-production' scripts/generate-workflow.sh` | 0 matches | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| DIAG-01 | 06-01-PLAN.md | Build job captures sha256 digest as job output alongside short SHA tag | SATISFIED | `id: build` on docker/build-push-action@v6; `digest: \${{ steps.build.outputs.digest }}` in build outputs block |
| DIAG-02 | 06-01-PLAN.md | deploy-staging and deploy-production steps log tag and digest at start | SATISFIED | `echo "Deploying tag=\$TAG digest=\$DIGEST"` first line in both Set-image-tag steps |
| PROMOTE-01 | 06-01-PLAN.md + 08-01-PLAN.md | verify-promotion CI job asserts same image tag on staging and production | SATISFIED | Job exists at line 256; `needs: [deploy-staging, deploy-production, build]` (build added by Phase 08 08-01); queries Coolify API and exits 1 on divergence. Note: Phase 06 delivered the job structure; Phase 08 fixed TAG resolution by adding build to needs. |
| PROMOTE-02 | 06-01-PLAN.md | ghcr-cleanup depends on verify-promotion; cleanup does not run if promotion assertion fails | SATISFIED | `needs: verify-promotion` at line 290; `needs: deploy-production` absent |

**Orphaned requirements:** None — all four requirements are covered. PROMOTE-01 is jointly satisfied by Phase 06 (job structure) and Phase 08 (TAG resolution fix). REQUIREMENTS.md traceability records PROMOTE-01 under Phase 08 reflecting the completing phase.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None | — | — | — | — |

No TODOs, FIXMEs, stubs, or placeholders in the modified files.

### Human Verification Required

None. All Phase 06 acceptance criteria are verifiable programmatically. The verify-promotion job's runtime behavior (actual TAG value propagation in GitHub Actions) is deferred to Phase 08's human verification note.

### Gaps Summary

No gaps. All 5 observable truths verified, all 4 key links wired, all 4 requirements satisfied, bash syntax clean.

**Retroactive note:** This VERIFICATION.md was produced during the v1.1 milestone audit rather than at phase execution time. All evidence was confirmed by direct code inspection of the current codebase state, which includes Phase 08 fixes. The code is correct; the process artifact was the only missing item.

---

_Verified: 2026-06-17 (retroactive)_
_Verifier: Claude (gsd-audit-milestone — retroactive)_
