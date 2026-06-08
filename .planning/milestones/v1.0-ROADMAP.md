# Roadmap: claude-skills-deploy

## Overview

The core Coolify + Doppler deployment skill is built and working. This milestone
fixes three HIGH bugs that would prevent the E2E test from passing, then builds
the test framework (E2E runner + static workflow validator + cleanup script) that
lets a new user clone the repo, run one command, and see a working hello-world
deployment on their Coolify server.

## Phases

- [x] **Phase 1: Bug Fixes** - Patch three HIGH bugs in provision.sh and generate-workflow.sh that would cause the E2E test to fail for the wrong reasons
- [x] **Phase 2: Test Framework** - Build the E2E test runner, static workflow validator, and wire them together so a passing run proves the skill is correct
- [x] **Phase 02.1: new-user-onboarding (URGENT)** - Remove maintainer-specific defaults and stale docs that silently fail for new users (completed 2026-05-22)
- [x] **Phase 3: Cleanup Script** - Add the separate teardown script that lets an operator delete the hello-world deployment after inspecting it
- [x] **Phase 4: Multi-Server Deployment** - Deploy apps to a separate VPS registered as a Coolify server; backward-compatible with existing localhost deployments (completed 2026-06-07)

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
**Plans**: 2 plans
- [x] 02-01-PLAN.md — Modify test/e2e.sh: env var config (E2E_SERVER/E2E_BASE_DOMAIN), conditional cleanup, JSON report, completion summary (TEST-01..05)
- [x] 02-02-PLAN.md — Create test/validate-workflow.sh: YAML syntax + needs-reference resolution checks (VALID-01, VALID-02)

**Status**: COMPLETE — verified 2026-05-22. Live E2E confirmed: Coolify project `csd-e2e-2026-05-22-111012` (staging + production) present. E2E_SERVER override test skipped — no second server available; accepted risk, env var substitution verified statically.
**UI hint**: no

### Phase 02.1: new-user-onboarding (INSERTED)

**Goal**: A new user who clones this repo and runs `bash test/e2e.sh` without setting any environment variables gets a clear, actionable error pointing at `/setup-coolify init` instead of silently attempting to hit the maintainer's Coolify instance; SKILL.md accurately describes what `provision.sh` actually does (no dead-code function references, no false deploy-trigger claims); README.md opens with a 5-step happy path above the prerequisites; references/api-reference.md uses placeholders instead of maintainer-specific domains.
**Depends on**: Phase 2
**Requirements**: ONBOARD-01, ONBOARD-02, ONBOARD-03, ONBOARD-04, ONBOARD-05, ONBOARD-06, ONBOARD-07
**Success Criteria** (what must be TRUE):
  1. Running `env -u E2E_SERVER -u E2E_BASE_DOMAIN bash test/e2e.sh` exits 1 with stderr containing both `ERROR: E2E_SERVER is required` and `ERROR: E2E_BASE_DOMAIN is required`, each followed by an actionable next-step (alias-key explanation and `/setup-coolify init` reference for E2E_SERVER; base-domain semantics for E2E_BASE_DOMAIN)
  2. `grep -c 'streamlinity\|vultr-stream\|cicd' test/e2e.sh SKILL.md references/api-reference.md` returns 0 (no maintainer-specific strings in user-facing scripts and docs)
  3. SKILL.md execution-flow steps 2 and 6 accurately describe `provision.sh`: step 2 lists the actual functions called (`coolify_upsert_project`, `coolify_get_server_uuid`, `coolify_get_destination_uuid`) and the `server_name` + `ssh_host` lookups; step 6 states that no deploy is triggered and the first deploy happens via push-to-main + the generated workflow
  4. SKILL.md `See also` section links to `docs/schema.md` (which exists) — not the non-existent `.planning/codebase/COOLIFY_YAML_SCHEMA.md`
  5. README.md opens with a `## Quick start` section (positioned between `## What you get` and `## Prerequisites`) listing exactly 5 commands and linking to `docs/setup-guide.md` and `docs/fork-guide.md`
  6. references/api-reference.md begins with a placeholder convention note and uses `<your-coolify-domain>` / `<your-doppler-account>` / `<your-app-domain>` throughout
**Plans**: 4 plans
- [x] 02.1-01-PLAN.md — test/e2e.sh: replace silent E2E_SERVER/E2E_BASE_DOMAIN defaults with actionable missing-var guards; annotate E2E_IMAGE default with origin + custom-image pointer (ONBOARD-01, ONBOARD-02)
- [x] 02.1-02-PLAN.md — SKILL.md: rewrite provision-flow steps 2 and 6 to match actual behaviour; replace maintainer init examples with generic placeholders; fix broken See also schema link (ONBOARD-03, ONBOARD-04, ONBOARD-05)
- [x] 02.1-03-PLAN.md — README.md: add 5-command Quick start section above Prerequisites with links to setup-guide.md and fork-guide.md (ONBOARD-06)
- [x] 02.1-04-PLAN.md — references/api-reference.md: add top-of-file placeholder convention note; replace all `streamlinity` / `coolify.cicd` values with `<your-coolify-domain>` / `<your-doppler-account>` / `<your-app-domain>` (ONBOARD-07)

**UI hint**: no

### Phase 3: Cleanup Script
**Goal**: Operators can delete the hello-world Coolify project and apps created by an E2E run by passing the test report file to a cleanup script — completing the full provision → verify → teardown loop
**Depends on**: Phase 2
**Requirements**: CLEAN-01, CLEAN-02
**Success Criteria** (what must be TRUE):
  1. `bash test/cleanup-deployment.sh <report-file>` deletes the Coolify project and staging app whose UUIDs are recorded in the specified report file
  2. The script prints a confirmation listing each deleted resource (project name, app names, UUIDs) and exits 0
**Plans**: 1 plan
- [x] 03-01-PLAN.md — Create test/cleanup-deployment.sh: report-file-driven teardown of Coolify apps + project + Docker volumes + Doppler project (CLEAN-01, CLEAN-02)

**UI hint**: no

### Phase 4: Multi-Server Deployment
**Goal**: Operators can deploy apps to a separately-registered Coolify server (a VPS distinct from the Coolify host) by setting `deploy_server:` in `coolify.yaml`, while all existing repos without this field continue to work unchanged. DNS provisioning, Docker volume creation, and VPS IP resolution all target the correct server. A migration guide covers converting existing localhost-deployed apps.
**Depends on**: Phase 3
**Requirements**: MSRV-01, MSRV-02, MSRV-03, MSRV-04, MSRV-05, MSRV-06, MSRV-07, MSRV-08
**Success Criteria** (what must be TRUE):
  1. A `coolify.yaml` with `deploy_server: "my-app-vps"` causes `provision.sh` to create Coolify apps on the server named `my-app-vps`, not `localhost`
  2. A `coolify.yaml` without `deploy_server:` provisions apps on the `localhost` server exactly as before (backward compatible)
  3. `validate.sh` exits non-zero with a named-server error when `deploy_server:` references a server not registered in Coolify
  4. DNS A records created by `provision.sh` resolve to the deployment VPS IP (not the Coolify host IP) when `deploy_ssh_host` is set
  5. `docs/schema.md` documents `deploy_server:` and `deploy_ssh_host` with examples; `docs/setup-guide.md` has a "Deploy to a separate VPS" how-to section
**Plans**: 4 plans
- [x] 04-01-PLAN.md — provision.sh + validate.sh + lib-coolify-api.sh: DEPLOY_SERVER_NAME/DEPLOY_SSH_HOST/DEPLOY_VPS_IP resolution chains, deploy_server existence check, improved destination-uuid lookup (MSRV-01..06)
- [x] 04-02-PLAN.md — init.sh + coolify.yaml.tmpl: optional deploy_server prompt with commented-out template default (MSRV-01)
- [x] 04-03-PLAN.md — docs/schema.md + docs/setup-guide.md + new docs/multi-server-migration.md: field references, 'Deploy to a separate VPS' how-to, migration guide (MSRV-07, MSRV-08)
- [x] 04-04-PLAN.md — test/validate-deploy-server.sh: MSRV-03 regression test against live Coolify (autonomous: false; depends on 04-01)
**UI hint**: no

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Bug Fixes | 3/3 | Complete | 2026-05-22 |
| 2. Test Framework | 2/2 | Complete | 2026-05-22 |
| 02.1. new-user-onboarding | 4/4 | Complete    | 2026-05-22 |
| 3. Cleanup Script | 1/1 | Complete | 2026-05-22 |
| 4. Multi-Server Deployment | 4/4 | Complete   | 2026-06-07 |
