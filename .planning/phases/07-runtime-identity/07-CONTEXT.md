# Phase 07: Runtime Identity - Context

**Gathered:** 2026-06-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Add runtime identity to the generated CI/CD pipeline and Dockerfile scaffold. Changes are confined to:
1. `scripts/generate-workflow.sh` — pass `GIT_SHA` and `BUILD_TIMESTAMP` build-args; add version assertion steps to staging and production smoke tests; add production smoke test (currently absent); add `PROD_DOMAIN` to deploy-production env block
2. `init/templates/Dockerfile.doppler.snippet` — add `ARG GIT_SHA`, `ARG BUILD_TIMESTAMP`, and OCI `LABEL org.opencontainers.image.*` stanzas so new repos get identity baking out of the box

Version assertions are graceful: if the health response has no `version` field the assertion step logs a warning and exits 0 — apps that haven't adopted the convention are unblocked.

</domain>

<decisions>
## Implementation Decisions

### Build Identity Inputs
- `GIT_SHA` build-arg value: `${{ steps.tag.outputs.short_sha }}` — already computed, matches the GHCR tag; OCI `revision` label will equal what appears in the image tag
- `BUILD_TIMESTAMP` build-arg value: `${{ github.event.head_commit.timestamp }}` — commit creation time; stable and reproducible
- Update the "No build-args" comment to clarify GIT_SHA/BUILD_TIMESTAMP are identity-only (not env-specific), preserving same-image promotion model

### Version Assertion & Graceful Skip
- When `version` field absent in health response: echo `"SKIP version-assert: health response has no 'version' field"` then exit 0 — operator sees the skip in CI logs
- Step structure: separate steps — `Assert staging version` and `Assert production version` — distinct from the health loop; health failure vs version failure are separate CI signals
- Expected version value: `sha-$TAG` (e.g. `sha-abc1234`) — as specified in ROADMAP success criteria

### Production Smoke Test
- Production smoke test retry loop: same 12×30s cadence as staging (6 min max) — container startup ≈ staging; deploy polling already gates on `status=finished`
- `PROD_DOMAIN` added to `deploy-production` job-level `env:` block — same pattern as `STAGING_DOMAIN` in `deploy-staging`
- Two steps: `Smoke test production` (health loop) + `Assert production version` (version check) — mirrors staging step structure exactly

### Claude's Discretion
- Exact jq expression for version extraction from health response body
- Bash variable names in the assertion steps
- Exact comment text for build-args block update

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `deploy-staging` smoke test step: `curl -sfS "https://$STAGING_DOMAIN$HEALTH_CHECK_PATH" -o /dev/null` loop (12×30s) — extend with body capture + jq version assertion in a new separate step
- `deploy-production` env block: `TAG`, `DIGEST`, `PROD_APP_UUID`, `COOLIFY_*` — add `PROD_DOMAIN: $PROD_DOMAIN` (already extracted by lib-config.py)
- `jq` confirmed available on ubuntu-latest (used in Phase 05 polling, Phase 06 verify-promotion)
- `HEALTH_CHECK_PATH` bash variable available in generate-workflow.sh scope — use in production smoke test curl

### Established Patterns
- `curl -sfS` for health checks and API calls
- `echo "SKIP ..." / exit 0` graceful degradation (matches timed_out=0 pattern from Phase 05)
- `jq -r '.field // empty'` or `jq -r '.field'` with empty-string check for optional field extraction
- Separate named steps per concern — cleaner Actions UI, easier to diagnose which step failed
- Job-level `env:` block for all variables — steps inherit without duplication

### Integration Points
- `build` job: add `build-args:` block to `docker/build-push-action@v6` step; update comment above
- `deploy-staging` job: add new `Assert staging version` step after existing `Smoke test staging` step; staging smoke test step captures body for assertion
- `deploy-production` job: add `PROD_DOMAIN` to env block; add `Smoke test production` + `Assert production version` steps after `Deploy production + wait for Coolify`
- `init/templates/Dockerfile.doppler.snippet`: prepend `ARG GIT_SHA`, `ARG BUILD_TIMESTAMP`, `LABEL org.opencontainers.image.revision=$GIT_SHA`, `LABEL org.opencontainers.image.created=$BUILD_TIMESTAMP` block above the existing Doppler install section

</code_context>

<specifics>
## Specific Ideas

ROADMAP success criteria explicitly state version equals `sha-<TAG>` (e.g. `sha-abc1234`). The assertion should compare the extracted `version` field against `"sha-$TAG"` where TAG is the short_sha.

The existing staging smoke test discards the body (`-o /dev/null`). The version assertion step needs a separate curl that captures the body: `HEALTH_BODY=$(curl -sfS "https://$STAGING_DOMAIN$HEALTH_CHECK_PATH")` then `jq -r '.version // empty'` to extract.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
