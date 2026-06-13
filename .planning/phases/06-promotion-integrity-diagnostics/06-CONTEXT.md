# Phase 06: Promotion Integrity + Diagnostics - Context

**Gathered:** 2026-06-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Add image digest traceability and a `verify-promotion` job to the generated `deploy.yml`. Changes are confined to `scripts/generate-workflow.sh` (workflow template) and `docs/invariants.md` (documentation).

Specifically:
1. Build job: capture `digest` from `docker/build-push-action@v6` and expose as a second job output alongside `tag`
2. Deploy steps: log expected `TAG` and `DIGEST` at the start of each deploy job's "Set image tag" step
3. New `verify-promotion` job: runs after both deploy jobs complete; queries Coolify API to assert both apps hold the same image tag; hard-fails if they diverge
4. `ghcr-cleanup` dependency: changed from `needs: deploy-production` to `needs: verify-promotion` — cleanup skips if promotion assertion fails
5. `docs/invariants.md`: add INV-04 (deployed tag must equal build SHA, enforced by verify-promotion) and INV-05 (production smoke test must pass — documented now, enforcement added in Phase 07)

</domain>

<decisions>
## Implementation Decisions

### Image Digest Capture
- Capture via `id: build` on the `docker/build-push-action@v6` step; reference `${{ steps.build.outputs.digest }}`
- Build job exposes two outputs: `tag` (existing short_sha) + `digest` (sha256 from build action)
- Deploy steps log at start of "Set image tag" step: `echo "Deploying tag=$TAG digest=$DIGEST"` — correct semantic boundary (before touching Coolify)
- Pass `DIGEST: ${{ needs.build.outputs.digest }}` in both deploy jobs' `env:` blocks — consistent with how `TAG` is already threaded

### verify-promotion Job
- Assert by querying Coolify `GET /api/v1/applications/{uuid}` for both apps; check `docker_registry_image_tag == TAG`
- `needs: [deploy-staging, deploy-production]` — both must complete before asserting
- Hard failure: exit 1 with `FAIL verify-promotion: staging=X, production=Y (expected $TAG)` — ghcr-cleanup is blocked
- Single step loops over both `$STAGING_APP_UUID` and `$PROD_APP_UUID` — compact, matches drift-check pattern

### Invariants Documentation
- INV-04 and INV-05 added to `docs/invariants.md` following the existing INV-01 format (rule, why, enforced-by, remediate)
- INV-05 documented now with `(planned: enforced by Phase 07)` note on the enforcement row — ROADMAP assigns it to Phase 06
- INV-04 `Enforced by` section explicitly names the `verify-promotion` CI job
- Add a new `per-push` row to the enforcement table: `verify-promotion` / "Fails CI if staging ≠ production image tag"

### Claude's Discretion
- Exact bash loop/variable names in verify-promotion step
- Field extraction from Coolify application API response (may need `jq -r '.docker_registry_image_tag'` or equivalent)
- Whether to add `STAGING_APP_UUID` and `PROD_APP_UUID` to verify-promotion job env block (reuse pattern from drift-check job)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `build` job outputs block: currently `tag: ${{ steps.tag.outputs.short_sha }}` — extend to add `digest`
- `docker/build-push-action@v6` at line 93 — add `id: build` and reference `steps.build.outputs.digest`
- Both `deploy-staging` and `deploy-production` already have `TAG: ${{ needs.build.outputs.tag }}` in env — same pattern for `DIGEST`
- `drift-check` job: single step looping over `$STAGING_APP_UUID` and `$PROD_APP_UUID` with `curl -sfS` + `jq` — identical structure to verify-promotion
- `ghcr-cleanup: needs: deploy-production` at line 199 — change to `needs: verify-promotion`

### Established Patterns
- `curl -sfS ... -H "Authorization: Bearer $COOLIFY_API_KEY"` — Coolify API auth pattern
- `jq -r '.field'` for response parsing — jq confirmed available on ubuntu-latest (used in Phase 05)
- `echo "FAIL ... " >&2; exit 1` for hard failures; `failed=0` + `exit $failed` for accumulated failures
- `echo "OK ..." / "FAIL ..."` prefix pattern from drift-check
- Job-level `env:` block inherits to all steps without duplication

### Integration Points
- `build` job: add `id: build` and second output `digest`
- Both deploy job `env:` blocks: add `DIGEST: ${{ needs.build.outputs.digest }}`
- Both deploy job "Set image tag" steps: prepend digest log line
- Insert `verify-promotion` job between `deploy-production` and `ghcr-cleanup`
- `ghcr-cleanup.needs`: update to `verify-promotion`
- `docs/invariants.md`: append INV-04 and INV-05 sections; update enforcement table

</code_context>

<specifics>
## Specific Ideas

Coolify `GET /api/v1/applications/{uuid}` returns the application record — the `docker_registry_image_tag` field holds the currently configured tag (same value that was PATCH'd in the "Set image tag" step). This is the correct field to assert rather than querying the deployment history.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
