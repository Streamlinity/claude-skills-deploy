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

## Adding a new invariant

1. Identify the rule clearly: what must always be true, and why.
2. Add a check to `validate.sh` (WARN for fixable violations, FAIL for unrecoverable ones).
3. Add a repair to `provision.sh` if the violation is automatically fixable.
4. Add a monitor step to `generate-workflow.sh`'s `drift-check` job for live detection.
5. Document the invariant here with: rule, why it matters, enforcement pointers.
6. Add `[ACTION REQUIRED]` to `CHANGELOG.md` for the release that introduces the invariant,
   so operators of existing deployments know to re-run `/setup-coolify`.
