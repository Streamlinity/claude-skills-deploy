# Roadmap: claude-skills-deploy

## Milestones

- [x] **v1.0 MVP** - Phases 01-04 (shipped 2026-06-08)
- [ ] **v1.1 Deployment Correctness** - Phases 05-07 (in progress)

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

### v1.1 Deployment Correctness (In Progress)

**Milestone Goal:** Make same-image promotion verifiably correct by adding deployment polling, image digest tracking, a cross-environment promotion assertion, and runtime version verification to the generated deploy.yml.

#### Phase 05: Deployment Polling
**Goal**: Coolify deployment failures surface immediately rather than timing out on the health endpoint — a failed image pull exits the workflow within seconds, not minutes
**Depends on**: Phase 4
**Requirements**: POLL-01, POLL-02
**Success Criteria** (what must be TRUE):
  1. When Coolify returns `status=failed` on a deployment, the workflow job exits non-zero within one polling cycle with a message directing the operator to the Coolify UI — no 6-minute health-check timeout occurs
  2. Both `deploy-staging` and `deploy-production` wait for `status=finished` before running the health check — health checks never race against an in-progress container pull
  3. Deployment polling status is logged at each interval so the operator can see Coolify's progress without opening the UI
**Plans**: 1 plan
- [x] 05-01-PLAN.md — Add trigger+poll step to deploy-staging and deploy-production jobs in generate-workflow.sh (POLL-01, POLL-02)

**Status**: COMPLETE — executed 2026-06-13
**UI hint**: no

#### Phase 06: Promotion Integrity + Diagnostics
**Goal**: Same-image promotion is verifiably asserted in CI — staging and production are confirmed on the same image tag before GHCR cleanup runs, with full digest traceability from build through deploy
**Depends on**: Phase 05
**Requirements**: PROMOTE-01, PROMOTE-02, DIAG-01, DIAG-02, INV-04, INV-05
**Success Criteria** (what must be TRUE):
  1. The build job's full image digest (sha256) is captured as a job output and visible in the Actions log; each deploy step logs the expected digest and tag at the start of execution
  2. A `verify-promotion` job asserts that Coolify's application records confirm the same image tag on both staging and production apps
  3. `ghcr-cleanup` depends on `verify-promotion` and does not run if the promotion assertion fails — all tags are preserved in GHCR for debugging
  4. `docs/invariants.md` documents INV-04 (deployed tag must equal build SHA) and INV-05 (production smoke test must pass before workflow completes)
**Plans**: 2 plans
- [ ] 06-01-PLAN.md — generate-workflow.sh: digest capture in build job, DIGEST env in deploy jobs, verify-promotion job, ghcr-cleanup dependency update (DIAG-01, DIAG-02, PROMOTE-01, PROMOTE-02)
- [ ] 06-02-PLAN.md — docs/invariants.md: append INV-04 and INV-05 sections, update enforcement table (INV-04, INV-05)
**UI hint**: no

#### Phase 07: Runtime Identity
**Goal**: The deployed container's identity is verifiable at runtime through the health endpoint, with version assertions in both staging and production smoke tests that degrade gracefully for apps that have not yet adopted the convention
**Depends on**: Phase 06
**Requirements**: LAYER3-01, LAYER3-02, SMOKE-01, SMOKE-02, SMOKE-03
**Success Criteria** (what must be TRUE):
  1. Generated `deploy.yml` passes `GIT_SHA` and `BUILD_TIMESTAMP` as build-args; images built from it carry `org.opencontainers.image.revision` and `org.opencontainers.image.created` OCI labels
  2. The staging smoke test extracts `version` from the health response and asserts it equals `sha-<TAG>`; the job passes without error when the `version` field is absent
  3. `deploy-production` includes a post-deploy smoke test with the same version assertion (currently absent), also with graceful skip when the field is absent
  4. The `init.sh` Dockerfile template scaffold includes `ARG GIT_SHA`, `ARG BUILD_TIMESTAMP`, and corresponding OCI `LABEL` stanzas so new repos get identity baking out of the box
**Plans**: 2 plans
- [ ] 07-01-PLAN.md — generate-workflow.sh: GIT_SHA/BUILD_TIMESTAMP build-args, Assert staging version step, production smoke test, Assert production version step (LAYER3-01, SMOKE-01, SMOKE-02, SMOKE-03)
- [ ] 07-02-PLAN.md — init/templates/Dockerfile.doppler.snippet: prepend ARG GIT_SHA, ARG BUILD_TIMESTAMP, OCI LABEL stanzas (LAYER3-02)
**UI hint**: no

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Bug Fixes | v1.0 | 3/3 | Complete | 2026-05-22 |
| 2. Test Framework | v1.0 | 2/2 | Complete | 2026-05-22 |
| 02.1. new-user-onboarding | v1.0 | 4/4 | Complete | 2026-05-22 |
| 3. Cleanup Script | v1.0 | 1/1 | Complete | 2026-05-22 |
| 4. Multi-Server Deployment | v1.0 | 4/4 | Complete | 2026-06-07 |
| 5. Deployment Polling | v1.1 | 1/1 | Complete | 2026-06-13 |
| 6. Promotion Integrity + Diagnostics | v1.1 | 0/2 | Not started | - |
| 7. Runtime Identity | v1.1 | 0/2 | Not started | - |
