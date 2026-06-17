# Roadmap: claude-skills-deploy

## Milestones

- [x] **v1.0 MVP** — Phases 01-04 (shipped 2026-06-08)
- [x] **v1.1 Deployment Correctness** — Phases 05-08 (shipped 2026-06-17)

## Phases

<details>
<summary>v1.0 MVP (Phases 01-04) — SHIPPED 2026-06-08</summary>

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

**Status**: COMPLETE — verified 2026-05-22.
**UI hint**: no

### Phase 02.1: new-user-onboarding (INSERTED)
**Goal**: A new user who clones this repo and runs `bash test/e2e.sh` without setting any environment variables gets a clear, actionable error pointing at `/setup-coolify init` instead of silently attempting to hit the maintainer's Coolify instance; SKILL.md accurately describes what `provision.sh` actually does; README.md opens with a 5-step happy path above the prerequisites; references/api-reference.md uses placeholders instead of maintainer-specific domains.
**Depends on**: Phase 2
**Requirements**: ONBOARD-01, ONBOARD-02, ONBOARD-03, ONBOARD-04, ONBOARD-05, ONBOARD-06, ONBOARD-07
**Success Criteria** (what must be TRUE):
  1. Running `env -u E2E_SERVER -u E2E_BASE_DOMAIN bash test/e2e.sh` exits 1 with stderr containing both `ERROR: E2E_SERVER is required` and `ERROR: E2E_BASE_DOMAIN is required`
  2. `grep -c 'streamlinity\|vultr-stream\|cicd' test/e2e.sh SKILL.md references/api-reference.md` returns 0
  3. SKILL.md execution-flow steps 2 and 6 accurately describe `provision.sh` and state no deploy is triggered
  4. SKILL.md `See also` section links to `docs/schema.md`
  5. README.md opens with a `## Quick start` section listing exactly 5 commands
  6. references/api-reference.md begins with a placeholder convention note and uses `<your-coolify-domain>` throughout
**Plans**: 4 plans
- [x] 02.1-01-PLAN.md — test/e2e.sh: replace silent defaults with actionable missing-var guards (ONBOARD-01, ONBOARD-02)
- [x] 02.1-02-PLAN.md — SKILL.md: rewrite provision-flow steps 2 and 6; fix broken schema link (ONBOARD-03, ONBOARD-04, ONBOARD-05)
- [x] 02.1-03-PLAN.md — README.md: add 5-command Quick start section (ONBOARD-06)
- [x] 02.1-04-PLAN.md — references/api-reference.md: replace all maintainer-specific values with placeholders (ONBOARD-07)

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
**Goal**: Operators can deploy apps to a separately-registered Coolify server by setting `deploy_server:` in `coolify.yaml`, while all existing repos without this field continue to work unchanged
**Depends on**: Phase 3
**Requirements**: MSRV-01, MSRV-02, MSRV-03, MSRV-04, MSRV-05, MSRV-06, MSRV-07, MSRV-08
**Success Criteria** (what must be TRUE):
  1. A `coolify.yaml` with `deploy_server: "my-app-vps"` causes `provision.sh` to create Coolify apps on the server named `my-app-vps`, not `localhost`
  2. A `coolify.yaml` without `deploy_server:` provisions apps on the `localhost` server exactly as before
  3. `validate.sh` exits non-zero with a named-server error when `deploy_server:` references a server not registered in Coolify
  4. DNS A records created by `provision.sh` resolve to the deployment VPS IP when `deploy_ssh_host` is set
  5. `docs/schema.md` documents `deploy_server:` and `deploy_ssh_host` with examples
**Plans**: 4 plans
- [x] 04-01-PLAN.md — provision.sh + validate.sh + lib-coolify-api.sh: DEPLOY_SERVER_NAME/DEPLOY_SSH_HOST/DEPLOY_VPS_IP resolution chains (MSRV-01..06)
- [x] 04-02-PLAN.md — init.sh + coolify.yaml.tmpl: optional deploy_server prompt (MSRV-01)
- [x] 04-03-PLAN.md — docs/schema.md + docs/setup-guide.md + new docs/multi-server-migration.md (MSRV-07, MSRV-08)
- [x] 04-04-PLAN.md — test/validate-deploy-server.sh: MSRV-03 regression test (MSRV-03)

**UI hint**: no

</details>

<details>
<summary>v1.1 Deployment Correctness (Phases 05-08) — SHIPPED 2026-06-17</summary>

- [x] Phase 05: Deployment Polling (1/1 plans) — completed 2026-06-13
- [x] Phase 06: Promotion Integrity + Diagnostics (2/2 plans) — completed 2026-06-13
- [x] Phase 07: Runtime Identity (2/2 plans) — completed 2026-06-16
- [x] Phase 08: Workflow Defect Fixes (3/3 plans) — completed 2026-06-17

See `.planning/milestones/v1.1-ROADMAP.md` for full phase details.

</details>

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Bug Fixes | v1.0 | 3/3 | Complete | 2026-05-22 |
| 2. Test Framework | v1.0 | 2/2 | Complete | 2026-05-22 |
| 02.1. new-user-onboarding | v1.0 | 4/4 | Complete | 2026-05-22 |
| 3. Cleanup Script | v1.0 | 1/1 | Complete | 2026-05-22 |
| 4. Multi-Server Deployment | v1.0 | 4/4 | Complete | 2026-06-07 |
| 5. Deployment Polling | v1.1 | 1/1 | Complete | 2026-06-13 |
| 6. Promotion Integrity + Diagnostics | v1.1 | 2/2 | Complete | 2026-06-13 |
| 7. Runtime Identity | v1.1 | 2/2 | Complete | 2026-06-16 |
| 8. Workflow Defect Fixes | v1.1 | 3/3 | Complete | 2026-06-17 |

## Backlog

### Phase 999.1: coolify.json Schema Enforcement (BACKLOG)

**Goal:** Harden schema enforcement, clean up the subcommand surface, and bring docs + tests into sync.

**Scope:**

*Schema enforcement (validate.sh):*
- Promote `doppler_token` to Tier 1 required (hard fail)
- Add Tier 2 cross-checks: `cloudflare_api_token` required when `dns.credential_source: coolify_json`; `deploy_ssh_host` / `deploy_vps_ip` required when `deploy_server:` set in coolify.yaml
- Add `env_vars` grep scan: flag declared vars absent from codebase + vars found in code missing from coolify.yaml
- Support opt-in `.coolify/validate.sh` hook in target repo for stack-specific dynamic patterns grep misses
- Make `validate` strictly read-only — strip Doppler gap-fill side-effect out entirely

*New subcommands:*
- `seed` — explicit Doppler gap-fill from `.env.local` / `.env.production`; logs every key set
- `provision` — explicit subcommand alias for blank (current default behavior unchanged); makes subcommand table complete

*Examples + docs:*
- Add `examples/coolify.json.example` with `REPLACE_THIS` placeholders for Tier 1 fields, annotated optional sections
- Update `docs/schema.md` with explicit 3-tier model (hard required / feature-gated / truly optional)
- Update `SKILL.md` subcommand table with `seed`, `provision`, updated `validate` (read-only), updated `plan` descriptions
- Update `docs/setup-guide.md` and any other docs referencing `validate` side-effects or subcommand names

*Tests:*
- Update `test/e2e.sh` for any validate/seed/provision invocation changes
- Add contract checks or unit tests for new Tier 2 cross-checks and grep scan behavior
- Verify `.coolify/validate.sh` hook is called when present (fixture test)

**Requirements:** SCHEMA-01 through SCHEMA-14
**Plans:** 4/4 plans complete

Plans:
- [x] 999.1-01-PLAN.md — validate.sh surgery: remove gap-fill, promote doppler_token to Tier 1, add Tier 2 cross-checks, env_vars grep scan, .coolify/validate.sh hook (SCHEMA-01..05)
- [x] 999.1-02-PLAN.md — New subcommands: seed.sh extraction, provision alias in provision.sh, SKILL.md subcommand table update (SCHEMA-06..08)
- [x] 999.1-03-PLAN.md — Examples + docs: examples/coolify.json.example, docs/schema.md 3-tier model, docs/setup-guide.md cleanup (SCHEMA-09..11)
- [x] 999.1-04-PLAN.md — Tests + E2E: validate-schema-contract.sh offline tests (V1-V6), e2e.sh compatibility check, E2E run (SCHEMA-12..14)
