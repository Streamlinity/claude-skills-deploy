# Phase 05: Deployment Polling - Context

**Gathered:** 2026-06-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace the current fire-and-poll-health-endpoint pattern with a Coolify deployment status polling loop in both `deploy-staging` and `deploy-production` jobs. After triggering a Coolify deploy, capture the `deployment_uuid` from the trigger response and poll `/api/v1/deployments/{uuid}` until `status=finished` or `status=failed` (max 6 min). A `status=failed` result exits the job immediately with a clear error message (UUID + Coolify UI URL) rather than timing out on the health check. Progress is logged at each poll interval. Only then does the existing health check run.

Changes are confined to `scripts/generate-workflow.sh` (the generated deploy.yml template).

</domain>

<decisions>
## Implementation Decisions

### Polling Mechanism
- Polling interval: 10 seconds (36 retries × 10s = 6 min max — matches ROADMAP spec)
- Extract `deployment_uuid` from trigger response using `jq -r '.deployments[0].deployment_uuid'` (jq is available on `ubuntu-latest`)
- Max retries hardcoded at 36 — no env var; keeps generated template simple and self-documenting
- Polling logic inlined as a bash loop within each deploy step's `run: |` block (no cross-step function sharing in GitHub Actions; composite actions would require separate repo files)

### Log & Error Format
- Progress log: compact `[N/36] status=STATUS` per poll iteration (readable without noise)
- On `status=failed`: emit both the `deployment_uuid` and the Coolify UI URL (`https://$COOLIFY_URL`) so operators can navigate directly to the failed deployment
- Merge trigger + poll into one combined step per deploy job: `Deploy staging + wait for Coolify` — reduces step noise in the Actions UI

### Scope
- Both `deploy-staging` AND `deploy-production` jobs get polling (matches POLL-01 SC #2: "Both deploy-staging and deploy-production wait for status=finished before running health checks")
- Same 6 min timeout for both environments (same container pull/start time; no reason to differ)
- `Set image tag` step remains a separate step from the combined trigger+poll step

### Claude's Discretion
- Exact bash loop structure (while vs for, variable names)
- Handling of Coolify API errors during polling (curl failures mid-poll — treat as transient, retry)
- Whether to add a brief initial `sleep 5` before first poll to avoid hitting an empty queue state immediately

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `deploy-staging` step "Trigger staging deploy" and "Smoke test staging (max 6 min)" — to be merged into one step with polling inserted between trigger and health check
- `deploy-production` "Trigger production deploy" — same pattern, add polling after trigger
- Coolify API auth pattern: `curl -sfS ... -H "Authorization: Bearer $COOLIFY_API_KEY"` — reuse exactly
- `COOLIFY_URL`, `STAGING_APP_UUID`, `PROD_APP_UUID`, `TAG` — all in scope as env vars in each job

### Established Patterns
- `curl -sfS` used throughout; continue with same flags for polling calls
- `echo "..." >&2; exit 1` pattern for hard failures
- Job-level `env:` block sets API credentials — polling steps inherit without duplication
- Inline `jq` already used in the `drift-check` job — confirms `jq` dependency is acceptable

### Integration Points
- `deploy-staging` job in the generated YAML (the `run: |` block in the smoke test step and trigger step)
- `deploy-production` job trigger step
- The polling must gate the existing `Smoke test staging` curl loop — polling runs first, health check runs after `status=finished`

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond POLL-01 and POLL-02 — open to standard approaches for bash polling loops.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
