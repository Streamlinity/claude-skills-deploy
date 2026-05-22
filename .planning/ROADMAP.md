# Roadmap: claude-skills-deploy

## Overview

The core Coolify + Doppler deployment skill is built and working. This milestone
fixes three HIGH bugs that would prevent the E2E test from passing, then builds
the test framework (E2E runner + static workflow validator + cleanup script) that
lets a new user clone the repo, run one command, and see a working hello-world
deployment on their Coolify server.

## Phases

- [ ] **Phase 1: Bug Fixes** - Patch three HIGH bugs in provision.sh and generate-workflow.sh that would cause the E2E test to fail for the wrong reasons
- [ ] **Phase 2: Test Framework** - Build the E2E test runner, static workflow validator, and wire them together so a passing run proves the skill is correct
- [ ] **Phase 3: Cleanup Script** - Add the separate teardown script that lets an operator delete the hello-world deployment after inspecting it

## Phase Details

### Phase 1: Bug Fixes
**Goal**: All three HIGH bugs in the provisioning and workflow generation scripts are fixed so that a provisioned Coolify app works correctly and the generated deploy.yml is accepted by GitHub Actions
**Depends on**: Nothing (first phase)
**Requirements**: BUG-01, BUG-02, BUG-03
**Success Criteria** (what must be TRUE):
  1. Running `/setup-coolify` on a repo generates a `deploy.yml` where `deploy-production.needs` references only jobs that exist in the file (`deploy-staging`, not `smoke-staging`)
  2. When `doppler secrets get` fails during provision, the script exits non-zero and prints the specific key name and error — no empty values are injected into Coolify
  3. `provision.sh` looks up the Coolify server UUID using `server_name` from `coolify.json` (defaulting to `localhost`), not a hardcoded string literal
**Plans**: 3 plans
- [x] 01-01-PLAN.md — Fix BUG-01: generate-workflow.sh emits invalid `needs: [smoke-staging, build]` and polls `/` instead of `/api/health`
- [x] 01-02-PLAN.md — Fix BUG-02: provision.sh silently injects empty Doppler values when `doppler secrets get` fails
- [x] 01-03-PLAN.md — Fix BUG-03: provision.sh hardcodes server lookup as "localhost"; make it configurable via `server_name` in coolify.json

**UI hint**: no

### Phase 2: Test Framework
**Goal**: A single `bash test/e2e.sh` command fully provisions a hello-world staging app on a real Coolify server, verifies it responds at `/api/health`, writes a machine-readable test report, and the generated workflow can be statically validated for structural correctness — all without requiring a GitHub push
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, VALID-01, VALID-02
**Success Criteria** (what must be TRUE):
  1. `bash test/e2e.sh` completes and the hello-world staging app remains running at the HTTPS staging URL after the script exits
  2. A JSON report file exists at `test/results/YYYYMMDD-HHMMSS.json` containing staging URL, project UUID, staging app UUID, per-step pass/fail, and run timestamp
  3. The script prints a completion summary showing the staging URL, report path, and the cleanup command to run next
  4. Re-running the test against a different Coolify server works by setting `E2E_SERVER` and `E2E_BASE_DOMAIN` env vars — no edits to the script required
  5. `bash test/validate-workflow.sh <path-to-deploy.yml>` exits non-zero and prints the offending reference when a `needs:` list contains a job name that does not exist in the workflow
**Plans**: TBD

**UI hint**: no

### Phase 3: Cleanup Script
**Goal**: Operators can delete the hello-world Coolify project and apps created by an E2E run by passing the test report file to a cleanup script — completing the full provision → verify → teardown loop
**Depends on**: Phase 2
**Requirements**: CLEAN-01, CLEAN-02
**Success Criteria** (what must be TRUE):
  1. `bash test/cleanup-deployment.sh <report-file>` deletes the Coolify project and staging app whose UUIDs are recorded in the specified report file
  2. The script prints a confirmation listing each deleted resource (project name, app names, UUIDs) and exits 0
**Plans**: TBD

**UI hint**: no

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Bug Fixes | 2/3 | In Progress|  |
| 2. Test Framework | 0/TBD | Not started | - |
| 3. Cleanup Script | 0/TBD | Not started | - |
