# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — MVP

**Shipped:** 2026-06-08
**Phases:** 5 (01, 02, 02.1, 03, 04) | **Plans:** 14

### What Was Built
- End-to-end Coolify + Doppler deployment skill with idempotent provisioning
- E2E test harness (`test/e2e.sh`) with env-var portability and JSON report
- Static workflow validator (`test/validate-workflow.sh`)
- Cleanup script (`test/cleanup-deployment.sh`) driven from JSON report
- Multi-server deployment via `deploy_server:` in coolify.yaml

### What Worked
- Bug-first ordering: fixing the 3 HIGH bugs before building the test framework saved significant debugging time
- JSON report pattern (e2e.sh writes UUIDs → cleanup reads them) decoupled teardown from test execution cleanly
- `E2E_SERVER`/`E2E_BASE_DOMAIN` env var portability worked immediately for domain forking

### What Was Inefficient
- Phase 02.1 (onboarding) was inserted as an urgent fix after Phase 02 — could have been included in Phase 02 scope with better upfront review

### Patterns Established
- Report-driven teardown pattern (write JSON on run, pass file to cleanup)
- Env var portability for all operator-specific values (`E2E_SERVER`, `E2E_BASE_DOMAIN`)

### Key Lessons
1. Fix correctness bugs before writing tests that depend on correct behavior
2. Leave deployments running on test success — new users need to see it work

---

## Milestone: v1.1 — Deployment Correctness

**Shipped:** 2026-06-17
**Phases:** 4 (05-08) | **Plans:** 8 | **Timeline:** 2026-06-13 → 2026-06-17 (4 days)

### What Was Built
- Deployment polling: 36×10s loops in both deploy jobs; pull failures exit within 10s (Phase 05)
- Image digest traceability: sha256 captured as build output, logged at every deploy step (Phase 06)
- `verify-promotion` job: asserts staging and production are on the same image tag; gates ghcr-cleanup (Phase 06+08)
- Runtime identity: GIT_SHA/BUILD_TIMESTAMP build-args + OCI labels; version assertion steps with graceful skip (Phase 07)
- OCI label scaffold in Dockerfile.doppler.snippet for new repos via init.sh (Phase 07)
- Contract test expanded from 10 to 16 checks (C11-C14: polling loop, version asserts, verify-promotion needs) (audit debt)
- Phase 08 closed two integration defects found by mid-milestone audit: TAG resolution bug (GAP-1) and C9 scope (GAP-2)

### What Worked
- Mid-milestone audit catching GAP-1 early: running the audit after Phase 07 revealed the TAG="" bug before any real workflow runs failed in production
- Worktree-based execution for Phase 08: three independent fixes executed in parallel worktrees, merged cleanly
- Identity-only build-args (GIT_SHA/BUILD_TIMESTAMP) exception in C9: distinguishing env-specific from identity-only was the right policy — same-image promotion is preserved while runtime identity is gained
- Graceful-skip pattern for version assertion: allows incremental adoption without blocking CI

### What Was Inefficient
- Phase 06 VERIFICATION.md was not written at execution time, requiring retroactive audit work — adds noise to the audit process
- Contract test coverage gaps (polling, version asserts) were not noticed until the audit, requiring additional work to add C11-C14 after the fact
- The verify-promotion bug (GAP-1: missing `build` in needs) was a structural mistake that static analysis in C14 now catches — adding contract tests earlier would have caught it during Phase 06

### Patterns Established
- Always run VERIFICATION.md at plan execution time — retroactive verification is noisier and slower
- Contract tests should mirror every new workflow behavior added — add C-rule in same phase as behavior
- `verify-promotion.needs` must include `build` whenever TAG is read from `needs.build.outputs.tag` — C14 now enforces this
- Graceful-skip assertion pattern: `jq -r '.version // empty'` → exit 0 with SKIP log when empty

### Key Lessons
1. Write VERIFICATION.md at execution time, not retroactively — the verifier has context the auditor lacks
2. Contract tests should be co-located with the feature they guard — add C-rules in the same phase that adds the behavior
3. GitHub Actions `needs.<job>.outputs.*` only resolves for jobs explicitly listed in `needs:` — this is easy to miss and should be a first-class contract check (C14)
4. Mid-milestone audit is a high-value forcing function: running gsd:audit-milestone after Phase 07 surfaced two real defects before shipping

### Cost Observations
- All phases pure CI generator changes (`scripts/generate-workflow.sh`) — zero new dependencies, zero new runtimes
- 4 key files changed: generate-workflow.sh (+159 lines), validate-workflow-contract.sh (+53 lines), invariants.md (+56 lines), Dockerfile.doppler.snippet (+9 lines)

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 5 | 14 | Established: bug-first ordering, env-var portability, report-driven teardown |
| v1.1 | 4 | 8 | Added: mid-milestone audit, contract test expansion, worktree-based parallel execution |

### Cumulative Quality

| Milestone | Contract Checks | Invariants Documented | Phase Verifications |
|-----------|----------------|----------------------|---------------------|
| v1.0 | 10 (C1-C10) | 3 (INV-01 through INV-03) | All phases verified |
| v1.1 | 16 (C1-C14 + sub-checks) | 5 (INV-01 through INV-05) | 3/4 at execution time; 1 retroactive |

### Top Lessons (Cross-Milestone)

1. **Fix correctness first**: both milestones started with defect identification and correction before new capability work
2. **Contract tests guard regressions**: static contract checking caught structural workflow bugs faster than live CI would
3. **Temporal verification matters**: write VERIFICATION.md at execution, not post-audit — retroactive verification is always noisier
