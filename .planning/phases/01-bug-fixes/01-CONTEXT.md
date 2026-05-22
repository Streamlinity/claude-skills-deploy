# Phase 1: Bug Fixes - Context

**Gathered:** 2026-05-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Patch three confirmed HIGH bugs in `provision.sh` and `generate-workflow.sh` that would cause the E2E test to fail for the wrong reasons. No new features — targeted code surgery only on the named files plus the schema doc update for BUG-03.

</domain>

<decisions>
## Implementation Decisions

### BUG-01: generate-workflow.sh job reference
- **D-01:** Fix `needs: [smoke-staging, build]` → `needs: [deploy-staging, build]` on line 146 (the `deploy-production` job)
- **D-02:** Also fix the smoke test URL in the same heredoc (line 138): change `"https://$STAGING_DOMAIN/"` → `"https://$STAGING_DOMAIN/api/health"`. Both changes are in the same heredoc — fix them together.

### BUG-02: doppler secrets get failure handling
- **D-03:** Loop through ALL env var keys first; accumulate failures; then exit non-zero with the full list. Do NOT fail fast on the first bad key.
- **D-04:** Error format per failed key: `ERROR: doppler secrets get KEY_NAME failed: <subprocess stderr text>` — include the actual Doppler error so the operator can diagnose (wrong project, revoked token, etc.) without re-running manually.
- **D-05:** The Python inline script (provision.sh:147-160 heredoc) must check `result.returncode != 0` for each key and collect `(key, stderr)` pairs, then `raise SystemExit` after the loop if any failures accumulated.

### BUG-03: server_name in coolify.json
- **D-06:** Add optional `server_name` field to `coolify.json` server entries (default: `"localhost"`). Read it in `provision.sh` using the same pattern already used for `ssh_host`.
- **D-07:** Update `docs/schema.md` to document `server_name` as an optional field — follow the same pattern as the existing `ssh_host` migration note in that file.

### Claude's Discretion
- Exact Python error message wording beyond the required structure
- Whether to print a summary header ("N key(s) failed:") before the per-key errors
- How `server_name` is extracted from `coolify.json` (Python inline or `coolify_load_server` extension)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Bug locations
- `scripts/generate-workflow.sh` — BUG-01: line 146 (`needs:`), line 138 (smoke URL); both in the same `cat > "$OUT_PATH"` heredoc
- `scripts/provision.sh` — BUG-02: lines 147-160 (Python heredoc that fetches Doppler secrets); BUG-03: line 47 (hardcoded `"localhost"`)

### Supporting files
- `scripts/lib-coolify-api.sh` — `coolify_load_server` function (pattern for reading coolify.json fields; replicate for `server_name`)
- `scripts/lib-doppler-api.sh` — `doppler_cmd` wrapper (context for Doppler subprocess pattern)
- `docs/schema.md` — update with `server_name` field; see existing `ssh_host` migration note as the model

### Codebase audit (read to understand severity and fix approach)
- `.planning/codebase/CONCERNS.md` — canonical descriptions of all three bugs with exact line numbers and fix approaches

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `coolify_load_server` in `lib-coolify-api.sh`: extracts fields from `coolify.json` via inline Python — replicate this pattern to extract `server_name` for BUG-03
- Python `sys.argv` heredoc pattern (used at provision.sh:147): already the safe pattern for multi-line Python in this codebase — use it for BUG-02 fix too

### Established Patterns
- Fail-fast with named field: `echo "ERROR: <field> ..." >&2; exit 1` — BUG-02 collected errors must follow the same naming convention before the final exit
- `set -euo pipefail` in all scripts — the Python heredoc runs inside this context; `raise SystemExit` from the Python block causes the shell `exit 1`
- `docs/schema.md` migration note pattern: already documents `ssh_host` as a field added post-initial release — same structure for `server_name`

### Integration Points
- `generate-workflow.sh` heredoc outputs to `$OUT_PATH` — changes are inside the `cat << 'EOF'` block; no function boundary to cross
- `provision.sh:47` feeds `SERVER_UUID` to subsequent app create payloads — the fix only changes how the lookup name is sourced, not the downstream usage

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond the decisions above — open to standard approaches for the mechanical parts.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-bug-fixes*
*Context gathered: 2026-05-22*
