# Deployment Correctness Strategy

How to detect, log, and assert image identity through the full build → staging → production
pipeline, so problems like wrong image paths or tag mismatches surface immediately rather
than after a silent bad deploy.

This document defines the strategy and implementation touchpoints. Implement after agreeing
on the approach — each section ends with a **TODO** block listing the concrete code changes.

---

## The problem class

Same-image promotion guarantees that staging and production run identical image bytes. That
guarantee can break in several ways that the current pipeline does not detect:

| Failure mode | What happens | Currently caught? |
|---|---|---|
| Wrong registry path in `coolify.yaml` | Build pushes to `ghcr.io/org/wrong-name`; Coolify pulls nothing or a stale image | No |
| Tag mismatch (PATCH succeeded but deploy used old tag) | Coolify re-deploys with previous image | No |
| Production pulls different digest than staging | Same tag, different bytes (e.g. tag was force-pushed) | No |
| Production deploy triggered but never completed | HTTP 200 from old running container masks failure | No — no production smoke test |
| Container reports wrong version at runtime | App started but Doppler injected wrong config | No |

The root cause of all of these is that the current smoke test only checks HTTP 200.
It confirms the container is responding, not that it is the right container.

---

## Current state audit

### What is logged today

- Short SHA tag emitted as a build output (`${GITHUB_SHA:0:7}`)
- Coolify PATCH response (no `--verbose` — only fails on non-2xx via `-sfS`)
- Coolify deploy trigger response (same)
- Staging smoke test: pass/fail with attempt count

### What is missing

1. **Image digest after push** — `docker/build-push-action@v6` outputs a `digest` field
   (`sha256:...`). We discard it. This is the canonical, immutable identity of the image.

2. **Coolify confirmation of what was deployed** — after triggering deploy, we do not
   query Coolify to confirm which image tag it actually pulled. A PATCH can succeed while
   Coolify ignores the tag on re-deploy (e.g. auto-deploy override).

3. **Container identity at runtime** — the smoke test hits `/api/health` and checks HTTP
   200. It does not verify that the running container reports the expected build SHA.

4. **Production smoke test** — `deploy-production` triggers the deploy and exits. There is
   no post-deploy health check on the production domain. A failed production pull is
   invisible until a user reports it.

5. **Cross-environment digest assertion** — nowhere in the pipeline do we assert
   `staging_digest == production_digest` before cleanup. This is the core of same-image
   promotion and it is currently unverified.

6. **Deploy log inspection** — Coolify deployment logs (available via
   `GET /deployments/{uuid}`) are never fetched. Pull errors, tag-not-found errors, and
   container start failures are silent unless the operator opens the Coolify UI.

---

## Strategy

Four complementary layers, ordered from cheapest to most thorough:

### Layer 1 — Digest pinning (build job)

After the build+push step, capture the image digest output from `build-push-action` and
pass it as a job output alongside the short SHA tag. Use the digest as the canonical
identity for all subsequent assertions.

```yaml
# In the build job — already using docker/build-push-action@v6
- id: build
  uses: docker/build-push-action@v6
  with:
    ...
    tags: $IMAGE:$TAG

# Capture digest as a job output
outputs:
  tag: ${{ steps.tag.outputs.short_sha }}
  digest: ${{ steps.build.outputs.digest }}   # sha256:abc123...
```

The digest is deterministic and immutable. It cannot be force-pushed or overwritten.
All subsequent steps refer to both `tag` (for human readability in Coolify UI) and
`digest` (for correctness assertions).

**TODO — `generate-workflow.sh`:**
- Add `digest: ${{ steps.build.outputs.digest }}` to the `build` job `outputs:` block
- Name the build step with an `id: build` so its outputs are referenceable
- Log `echo "Built digest: ${{ needs.build.outputs.digest }}"` at the start of deploy-staging and deploy-production

---

### Layer 2 — Deployment confirmation (deploy jobs)

After triggering a Coolify deploy, poll the Coolify deployments API until the deployment
completes (status `finished` or `failed`) rather than immediately hitting the health endpoint.
Log the deployment record, including the image it pulled.

```bash
# After triggering deploy:
DEPLOY_UUID=$(curl -sfS "$COOLIFY_URL/api/v1/deploy?uuid=$APP_UUID&force=false" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.deployments[0].deploymentUuid')

# Poll until done (max 6 min):
for i in $(seq 1 24); do
  sleep 15
  STATUS=$(curl -sfS "$COOLIFY_URL/api/v1/deployments/$DEPLOY_UUID" \
    -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.status')
  echo "Deploy $i/24: status=$STATUS"
  [ "$STATUS" = "finished" ] && break
  [ "$STATUS" = "failed"   ] && { echo "Deploy failed — see Coolify UI"; exit 1; }
done

# Fetch and log the deployment record:
curl -sfS "$COOLIFY_URL/api/v1/deployments/$DEPLOY_UUID" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" | jq '{status, image: .commit_message}'
```

This replaces the current "trigger and immediately poll health" pattern with a
"wait for Coolify to confirm completion, then health-check" pattern. A pull failure
surfaces as `status=failed` rather than a 6-minute timeout.

**TODO — `generate-workflow.sh`:**
- Replace the current `sleep 30 × 12` smoke test loop with: trigger → poll deployments API
  → on `finished`, then run the health check
- Log the Coolify deployment record (image tag, status) at the end of both
  `deploy-staging` and `deploy-production`
- Hard-fail on `status=failed` with a message directing to Coolify UI for logs

---

### Layer 3 — Runtime identity verification (smoke test)

The smoke test must verify not just HTTP 200 but that the correct version is running.
This requires apps to expose build metadata in their health response.

#### Health endpoint convention

Apps deployed via this skill should return a JSON body from their health endpoint:

```json
{
  "status": "ok",
  "version": "sha-abc1234",
  "built_at": "2024-01-15T10:30:00Z"
}
```

The `version` field must match the `TAG` output from the build job. The `built_at`
timestamp is a secondary check for detecting stale containers.

#### Baking metadata into the image

In the Dockerfile:

```dockerfile
ARG GIT_SHA=unknown
ARG BUILD_TIMESTAMP=unknown
LABEL org.opencontainers.image.revision=$GIT_SHA
LABEL org.opencontainers.image.created=$BUILD_TIMESTAMP
ENV NEXT_PUBLIC_APP_VERSION=$GIT_SHA
```

In the CI build step:

```yaml
build-args: |
  GIT_SHA=${{ github.sha }}
  BUILD_TIMESTAMP=${{ github.event.head_commit.timestamp }}
```

> **Same-image promotion note:** `GIT_SHA` and `BUILD_TIMESTAMP` are build-time values
> that are the SAME for staging and production (they both come from the same git commit).
> These are identity metadata, not env-specific configuration. They do not break the
> same-image guarantee. Only values that differ between environments (API keys, URLs)
> must be runtime-injected via Doppler.

#### Enhanced smoke test

```bash
RESPONSE=$(curl -sfS "https://$DOMAIN$HEALTH_CHECK_PATH")
echo "Health response: $RESPONSE"

REPORTED_VERSION=$(echo "$RESPONSE" | jq -r '.version // empty')
if [ -n "$REPORTED_VERSION" ] && [ "$REPORTED_VERSION" != "sha-$TAG" ]; then
  echo "VERSION MISMATCH: expected sha-$TAG, got $REPORTED_VERSION" >&2
  exit 1
fi
echo "Identity check: OK (version=sha-$TAG)"
```

If the app does not yet expose `version` in its health response, the check degrades
gracefully (the `jq -r '.version // empty'` returns empty and the assertion is skipped)
rather than failing. This makes adoption incremental across repos.

**TODO — `generate-workflow.sh`:**
- Add `GIT_SHA` and `BUILD_TIMESTAMP` build-args to the build step
- Add Dockerfile label ARGs to the `init_app` Dockerfile template
- Enhance the smoke test to extract and assert `version` from the health response
  (with graceful skip when the field is absent)
- Add the same enhanced smoke test to `deploy-production` (currently absent)

---

### Layer 4 — Cross-environment digest assertion (pre-cleanup gate)

Before the `ghcr-cleanup` job runs, assert that staging and production are running
the same image digest. This is the definitive same-image promotion check.

```yaml
verify-promotion:
  needs: [deploy-staging, deploy-production, build]
  runs-on: ubuntu-latest
  env:
    EXPECTED_DIGEST: ${{ needs.build.outputs.digest }}
  steps:
    - name: Assert staging and production run the same digest
      run: |
        # Query Coolify for the deployed image tag on each app
        STAGING_TAG=$(curl -sfS "$COOLIFY_URL/api/v1/applications/$STAGING_APP_UUID" \
          -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.docker_registry_image_tag')
        PROD_TAG=$(curl -sfS "$COOLIFY_URL/api/v1/applications/$PROD_APP_UUID" \
          -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.docker_registry_image_tag')

        echo "staging tag: $STAGING_TAG"
        echo "production tag: $PROD_TAG"
        echo "expected tag: $TAG"

        [ "$STAGING_TAG" = "$TAG" ] || { echo "FAIL: staging tag mismatch" >&2; exit 1; }
        [ "$PROD_TAG"    = "$TAG" ] || { echo "FAIL: production tag mismatch" >&2; exit 1; }
        echo "PASS: both environments confirmed on tag $TAG"
```

The `ghcr-cleanup` job gains `needs: [verify-promotion]`. Cleanup does not run if the
promotion assertion fails — preserving all tags in GHCR for debugging.

**TODO — `generate-workflow.sh`:**
- Add `verify-promotion` job between `deploy-production` and `ghcr-cleanup`
- Change `ghcr-cleanup.needs` from `[deploy-production]` to `[verify-promotion]`

---

## Invariant additions

Two new invariants emerge from this strategy:

### INV-04: Deployed image tag matches the build SHA

**Rule:** After each deploy, the Coolify application's `docker_registry_image_tag` must
equal the short SHA from the triggering commit. A mismatch indicates Coolify ignored the
PATCH or used a cached/fallback image.

**Enforced by:** `verify-promotion` CI job (Layer 4 above); optionally by `validate.sh`
querying live app state when `--check-deployed` flag is passed.

### INV-05: Production smoke test passes

**Rule:** Production must pass the same health check and version assertion that staging
passes before the workflow completes. Currently production has no post-deploy check.

**Enforced by:** Enhanced `deploy-production` job with smoke test (Layer 3 above).

---

## Implementation touchpoints

| File | Change |
|------|--------|
| `scripts/generate-workflow.sh` | Add digest output, deployment polling, enhanced smoke tests, `verify-promotion` job, production smoke test |
| `init/templates/coolify.yaml.tmpl` | No change — image path is already user-supplied |
| `init/init.sh` | Offer to add OCI label ARGs to a scaffold Dockerfile when one doesn't exist |
| `docs/invariants.md` | Add INV-04 and INV-05 |
| `docs/schema.md` | Document `health_check_path` convention (JSON body with `version` field) |
| `docs/developer-onboarding.md` | Add note: health endpoint should return `{"status":"ok","version":"sha-..."}` |

The changes are additive — existing generated `deploy.yml` files in target repos remain
valid. Operators regenerate via `/setup-coolify` to adopt the enhanced workflow.

---

## Rollout across repos

Because all `deploy.yml` files are generated by `generate-workflow.sh`, every repo
picks up the enhanced checks by running `/setup-coolify` after this skill is updated.
No per-repo code changes are required beyond:

1. Adding OCI label ARGs to the repo's Dockerfile (one-time, per repo)
2. Returning `version` from the health endpoint (one-time, per app — graceful skip until done)

The `verify-promotion` job and deployment polling are pure CI changes with no app-side
dependency — they take effect immediately on regeneration.

---

## Suggested rollout order

1. **Layer 2** first (deployment polling) — highest value, zero app-side changes, catches
   pull failures immediately instead of after a 6-min timeout
2. **Layer 4** next (cross-env digest assertion) — zero app-side changes, directly prevents
   the problem class that triggered this doc
3. **Layer 1** (digest logging) — add alongside Layer 4 for full traceability
4. **Layer 3** last (runtime identity) — requires Dockerfile and health endpoint changes
   per repo; make graceful-skip the default so adoption is incremental
