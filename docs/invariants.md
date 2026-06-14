# CSD Invariants

Invariants are rules that must hold in every deployed CSD-managed environment.
Unlike conventions (style choices in scripts) or optional features (opt-in blocks in coolify.yaml),
invariants are actively enforced by machine checks and repaired by provision.

## How invariants are enforced

| Layer | Tool | Behavior |
|-------|------|----------|
| **Check (advisory)** | `validate.sh` | Warns about violations — exits 0 so provision can fix them |
| **Enforce (fix)** | `provision.sh` | Removes or repairs violations on every run |
| **Monitor (continuous)** | `deploy.yml` drift-check job | Fails the weekly CI job if a violation is detected in a live app |
| **Assert (per-push)** | `deploy.yml` verify-promotion job | Fails CI if staging ≠ production image tag |

The weekly CI job in the generated `deploy.yml` (`drift-check`, schedule Monday 8am UTC)
provides the continuous monitoring layer — it detects drift between provision runs without
requiring an operator to manually re-run `/setup-coolify`.

---

## INV-01: Coolify apps hold exactly one env var — DOPPLER_TOKEN

**Rule**: Each Coolify application managed by CSD must have exactly one environment variable:
`DOPPLER_TOKEN`. All other secrets and config values flow through Doppler at container startup
via that token. No other env var is permitted in Coolify.

**Why this matters**: Coolify env vars take precedence over Doppler values at container start.
If an operator manually sets `OPENAI_API_KEY` in the Coolify UI (or an earlier provision method
did so), the running container sees that stale value instead of the current Doppler value.
The mismatch is silent and hard to diagnose — Doppler shows the correct value, but the app
uses the wrong one.

**Root cause of the pattern**: Discovered June 2026 after target repos migrated from a
provision model that set individual vars in Coolify. The stale vars survived because
`coolify_set_app_envs` used `/envs/bulk` PATCH (additive merge, not replace), so subsequent
provisions added DOPPLER_TOKEN without removing the old vars.

**Enforced by**:
- `validate.sh` → `coolify_list_stale_app_envs` WARN: lists any non-DOPPLER_TOKEN keys found
- `provision.sh` step 2f → `coolify_purge_stale_app_envs` deletes all stale vars before deployment
- `deploy.yml` drift-check job → queries `/applications/{uuid}/envs` weekly and fails CI if stale vars present

**To remediate manually**:
1. Run `/setup-coolify` in the target repo — provision will remove stale vars automatically
2. Or delete manually in Coolify UI → Application → Environment Variables

**Not affected by**: Doppler secret changes, app redeployments, GitHub Actions runs.
The DOPPLER_TOKEN itself is rotatable via `/setup-coolify --rotate-tokens`.

---

## INV-02: Same-image promotion — no env-specific build args

**Rule**: The Docker build step must not pass env-specific values (like `NEXT_PUBLIC_BASE_URL`)
as `--build-arg`. Staging and production must use byte-identical image layers.

**Why this matters**: If staging and production are built separately with different build args,
they are NOT the same image — the "same-image promotion" guarantee breaks. A build arg that
differs between environments means the image that passed staging tests is NOT the one deployed
to production.

**Enforced by**:
- `generate-workflow.sh` → emits no `build-args:` block; defensive check fails if `NEXT_PUBLIC_BASE_URL`
  appears outside a comment in the generated `deploy.yml`
- All env-specific values must flow through `DOPPLER_TOKEN` at container startup

---

## INV-03: Doppler holds all application secrets listed in coolify.yaml

**Rule**: Every key in `env_vars` in `coolify.yaml` must exist in each Doppler config
(staging + production + any extra environments) with a non-placeholder value.

**Why this matters**: An env var listed in `coolify.yaml` but absent from Doppler means the
container starts with an empty or missing value. This is often silent at startup but causes
runtime failures when the code actually tries to use the key.

**Enforced by**:
- `validate.sh` → calls `doppler_check_key` for each env var in each Doppler config; FAIL (blocking)
  if any key is absent or contains `TODO_REPLACE_BEFORE_DEPLOY`

---

---

## INV-04: Deployed image tag must equal the build SHA on every Coolify app

**Rule**: Both staging and production Coolify applications must have `docker_registry_image_tag`
set to the commit short SHA (`${GITHUB_SHA:0:7}`) produced by the current build job.
No app may hold a tag that differs from the one built and promoted in the same workflow run.

**Why this matters**: If either app's tag drifts from the build SHA — due to a manual update in
the Coolify UI, a failed PATCH step, or a partial workflow run — the same-image promotion guarantee
is broken silently. The operator would believe staging and production are on the same image when they
are not. This class of failure is hard to diagnose because Coolify shows what tag it was told to use,
not what is actually running in the container.

**Enforced by**:
- `deploy.yml` verify-promotion job → runs after both deploy-staging and deploy-production complete;
  queries Coolify `GET /api/v1/applications/{uuid}` for each app; compares `docker_registry_image_tag`
  against the build job's `$TAG` output; exits 1 with `FAIL verify-promotion: diverged tags detected`
  if either app does not match. Blocks ghcr-cleanup from running, preserving all GHCR tags for debugging.

**To remediate manually**:
1. Check the "Set image tag" step logs in the failed workflow run for Coolify API errors
2. Re-run the failed workflow from the GitHub Actions tab — the PATCH step is idempotent
3. Or set the tag manually in the Coolify UI: Application → Image → Tag field

**Not affected by**: Doppler secret changes, application config updates, drift-check schedule runs,
or redeployments that do not change the tag value.

---

## INV-05: Production smoke test must pass before the workflow completes

**Rule**: The workflow must not reach the `ghcr-cleanup` step unless the production deployment
has been verified as healthy by a smoke test. A failing production smoke test must block cleanup
so that GHCR tags are preserved for diagnosing and rolling back the failure.

**Why this matters**: Running GHCR cleanup after a failed production deploy removes the image tags
needed to diagnose or roll back. Retaining tags gives operators a full history of what ran and
allows redeployment of the last known-good tag without rebuilding. Cleanup is a permanent action —
once old tags are deleted they cannot be recovered from GHCR without a new build.

**Enforced by**:
- (planned: enforced by Phase 07 — production smoke test job added to deploy.yml)

**To remediate manually**:
1. Check the production deploy job logs in the Actions run for the failure cause
2. If the image is at fault, identify the last known-good short SHA from prior workflow runs
3. Manually set `docker_registry_image_tag` to the known-good SHA in Coolify UI and redeploy

**Not affected by**: Staging smoke test results, infrastructure changes, Doppler secret rotations,
or verify-promotion assertion status.

---

## Adding a new invariant

1. Identify the rule clearly: what must always be true, and why.
2. Add a check to `validate.sh` (WARN for fixable violations, FAIL for unrecoverable ones).
3. Add a repair to `provision.sh` if the violation is automatically fixable.
4. Add a monitor step to `generate-workflow.sh`'s `drift-check` job for live detection.
5. Document the invariant here with: rule, why it matters, enforcement pointers.
6. Add `[ACTION REQUIRED]` to `CHANGELOG.md` for the release that introduces the invariant,
   so operators of existing deployments know to re-run `/setup-coolify`.
