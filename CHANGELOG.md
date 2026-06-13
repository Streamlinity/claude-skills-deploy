# Changelog

Changes are tagged `[ACTION REQUIRED]` when existing target-repo deployments need
a `/setup-coolify` re-run to pick up the change. See `docs/upgrade-governance.md`
for the rationale behind this convention.

---

## [ACTION REQUIRED] 2026-06-13 — INV-01: stale Coolify env var enforcement

**Target repos**: all repos previously provisioned with CSD  
**Action**: run `/setup-coolify` in each target repo  
**Why**: provision.sh now enforces INV-01 — any Coolify env var other than `DOPPLER_TOKEN`
is deleted on each provision run. Without this re-run, stale vars (set manually or by earlier
provision methods) continue to silently override Doppler values at container start.

**What changed**:
- `scripts/lib-coolify-api.sh`: added `coolify_delete_app_env`, `coolify_purge_stale_app_envs`,
  `coolify_list_stale_app_envs`
- `scripts/validate.sh`: added INV-01 WARN check — queries live Coolify apps for non-DOPPLER_TOKEN vars
- `scripts/provision.sh`: added step 2f — removes all non-DOPPLER_TOKEN vars from each app after provisioning
- `scripts/provision.sh` plan mode: reports stale vars as `~ INV-01 stale env var` in plan diff
- `scripts/generate-workflow.sh`: generated `deploy.yml` now includes weekly `drift-check` job (Monday 8am UTC)
  that fails CI if stale vars are detected in any provisioned app
- `docs/invariants.md`: new — machine-enforced invariants reference with enforcement pointers
- `docs/upgrade-governance.md`: new — captures upgrade architecture, skills-vs-product tradeoffs,
  test strategy for upgrade scenarios
- `test/e2e.sh`: Step 5b added — exercises INV-01 detection and cleanup in every E2E run

**Symptoms of the bug this fixes**: app behaves as if a secret has an old value even though
Doppler shows the correct current value. Restart does not help. The old value is set directly
in Coolify env vars and overrides the Doppler-injected value.
