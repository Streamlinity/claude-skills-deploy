# Phase 3: Cleanup Script - Context

**Gathered:** 2026-05-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Add `test/cleanup-deployment.sh` — a standalone teardown script that reads a machine-readable test report file (written by Phase 2's E2E test) and deletes every resource the test created: Coolify apps, Coolify project, Docker volumes on the VPS via SSH, and the Doppler project.

</domain>

<decisions>
## Implementation Decisions

### Cleanup Scope
- **D-01:** Full teardown — mirror the full `e2e.sh` cleanup() function exactly: staging app → production app → Coolify project → Docker volumes via SSH → Doppler project. Everything the E2E test created gets removed.
- **D-02:** Deletion order matches e2e.sh: apps first, then project, then volumes, then Doppler project. This is the safe order (project delete can cascade to apps in some Coolify versions, so apps first avoids ambiguity).

### Report File Schema
- **D-03:** Phase 2's E2E test writes a **full teardown record** to `test/results/YYYYMMDD-HHMMSS.json`. The report must include all fields needed for self-contained cleanup — no flags required at cleanup time:
  - `staging_url` — HTTPS staging URL
  - `coolify_project_uuid` — Coolify project UUID
  - `staging_app_uuid` — staging app UUID
  - `production_app_uuid` — production app UUID
  - `doppler_project` — Doppler project name (e.g. `csd-e2e-20260522123456`)
  - `server_alias` — Coolify server alias from coolify.json (e.g. `vultr-stream`)
  - `ssh_host` — VPS SSH host alias (for Docker volume removal)
  - `steps` — array of `{name, passed, timestamp}` per-step results
  - `timestamp` — ISO run timestamp
- **D-04:** `cleanup-deployment.sh` reads ALL credentials from the report file — operator only passes the report file path, nothing else.

### Partial Failure Handling
- **D-05:** Warn-and-continue — print ⚠ warning for each already-deleted or unreachable resource, continue to the next step. Matches e2e.sh's existing `|| echo "⚠ could not delete..."` pattern.
- **D-06:** Exit 0 if all attempted deletes either succeeded or returned a 404 (already gone). Exit non-zero only if a DELETE returned an unexpected error (5xx, auth failure, etc.).
- **D-07:** Print a final confirmation block listing each deleted resource (name, UUID), matching CLEAN-02.

### Server Credentials
- **D-08:** Read `server_alias` from the report file, then call `coolify_load_server "$server_alias"` — same pattern used in e2e.sh and provision.sh. No `--server` flag needed.
- **D-09:** If `coolify.json` is missing or the alias is not found, exit non-zero with a clear error: `ERROR: server alias '<alias>' not found in ~/.claude/coolify.json`.

### Claude's Discretion
- Exact wording of the printed confirmation block (beyond listing name + UUID per resource)
- Whether to print a dry-run preview before deleting or delete immediately
- Whether to accept an optional `--dry-run` flag (not required by CLEAN-01/CLEAN-02)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Source for cleanup logic (extract and adapt)
- `test/e2e.sh` lines 70-149 — `cleanup()` function; this is the model to extract into `cleanup-deployment.sh`; the new script reads the same values from a JSON report file instead of live variables

### Library functions to source
- `scripts/lib-coolify-api.sh` — `coolify_load_server`, `coolify_curl` DELETE calls; source this at the top of `cleanup-deployment.sh`
- `scripts/lib-doppler-api.sh` — `doppler_load_account`; may be needed if Doppler cleanup uses the account field

### Requirements being implemented
- `CLEAN-01` and `CLEAN-02` in `.planning/REQUIREMENTS.md` — full acceptance criteria

### Report file (written by Phase 2, read by Phase 3)
- `test/results/` — directory where E2E test writes reports; cleanup script reads from here
- Phase 2 plan (when written) will define the exact report schema — D-03 above defines the required fields

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `test/e2e.sh` `cleanup()` function (lines 70-149): contains all five deletion steps with exact curl/ssh/doppler commands — extract and adapt rather than rewrite
- `coolify_curl DELETE "/applications/$UUID"` and `coolify_curl DELETE "/projects/$UUID"`: already used in e2e.sh cleanup; same calls go into cleanup-deployment.sh
- `coolify_load_server "$SERVER_ALIAS"`: sets `COOLIFY_URL` and `COOLIFY_API_KEY` — call this after reading server_alias from the report

### Established Patterns
- Source lib files at the top: `source "$SKILL_DIR/scripts/lib-coolify-api.sh"` and `lib-doppler-api.sh`
- SSH volume removal: `ssh "$SSH_HOST" "docker volume rm ${uuid}-doppler-cache 2>/dev/null || true"` (e2e.sh line 129)
- Doppler project delete: `doppler projects delete "$PROJECT_NAME" --yes` (e2e.sh line 137)
- Warn-and-continue for partial failures: `coolify_curl DELETE "..." >/dev/null 2>&1 && echo "✓ deleted ..." || echo "⚠ could not delete ..."` (e2e.sh lines 110-121)
- Python JSON parsing for report file: `python3 -c "import json; d=json.load(open('$REPORT_FILE')); ..."` — same inline pattern used throughout the codebase

### Integration Points
- `test/results/` directory: cleanup-deployment.sh reads from here; Phase 2 writes to here
- `~/.claude/coolify.json`: cleanup-deployment.sh calls `coolify_load_server` which reads this file
- No changes needed to existing scripts — cleanup-deployment.sh is a new standalone file

</code_context>

<specifics>
## Specific Ideas

- The script should be self-contained: an operator who ran the E2E test a week ago can come back, find the report file in `test/results/`, and run cleanup without needing to remember any flags or server aliases.
- The confirmation block (CLEAN-02) should list: project name, staging app UUID, production app UUID, and Doppler project name — matching what the operator saw when they ran the E2E test.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 03-cleanup-script*
*Context gathered: 2026-05-22*
