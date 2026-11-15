# Changelog

Changes are tagged `[ACTION REQUIRED]` when existing target-repo deployments need
a `/setup-coolify` re-run to pick up the change. See `docs/upgrade-governance.md`
for the rationale behind this convention.

---

## 2026-11-14 — `promotion: manual`: staging on merge, production by hand

**Target repos**: none need action. Repos without `promotion: manual` get a byte-for-byte
identical `deploy.yml` (checked against `test/golden/deploy-auto.yml` in CI).
**Opt in**: add `promotion: manual`, `ci_workflow` and `release_owners` (and optionally
`smoke_command`) to `coolify.yaml`, then run `/setup-coolify`.

**What changed**:
- `scripts/lib-config.py`: reads `promotion` (`auto` default, or `manual`), `ci_workflow`
  (default `CI`), `release_owners`, `smoke_command`; new `check-promotion` command refuses
  `promotion: manual` without `ci_workflow` and `release_owners` and warns about manual-only
  keys in auto mode. Used by `validate.sh` and `generate-workflow.sh`.
- `scripts/generate-workflow.sh`: with `promotion: manual`, renders `deploy.yml` (gate on
  `workflow_run` of CI: tip of main, CI success, merged PR; build; staging only; staging
  deployment record; drift check), `promote.yml` and `rollback.yml` from `scripts/templates/`
  via `scripts/render-workflows.py`.
- `scripts/release-gate.sh` (new): the gate checks, deployment records, Coolify deploy and
  smoke steps, image re-tag and the clean-up keep list (digests and child manifests). Inlined
  into the generated workflows.
- `docs/schema.md`, `docs/invariants.md` (INV-04 under manual promotion),
  `docs/deployment-correctness.md` (manual promotion and rollback).
- Tests: `test/test-release-gate.sh` (new; stub gh, curl and docker),
  `test/validate-workflow-contract.sh` (G1 auto golden, M1-M11 manual contract, P1-P8
  option checks).

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
