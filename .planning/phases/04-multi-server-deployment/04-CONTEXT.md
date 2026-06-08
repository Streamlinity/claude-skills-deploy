# Phase 4: Multi-Server Deployment - Context

**Gathered:** 2026-06-07
**Status:** Ready for execution

<domain>
## Phase Boundary

Extend `provision.sh`, `validate.sh`, and `lib-coolify-api.sh` to support deploying applications to a separately-registered Coolify server. This is controlled by an optional `deploy_server:` field in `coolify.yaml` and optional `deploy_ssh_host` / `deploy_vps_ip` fields in `coolify.json`. If these fields are absent, the code must default back to localhost deployment behavior, ensuring full backward compatibility.

</domain>

<decisions>
## Implementation Decisions

### Destination UUID Lookup
- **D-01:** Implement a three-strategy destination lookup in `coolify_get_destination_uuid()`:
  1. Scan existing apps via `GET /applications` for matching `destination.server.uuid` (primary).
  2. Query `GET /destinations` (fallback for older Coolify versions).
  3. Return empty string so Coolify auto-assigns at create time (implicit fallback).

### IP Resolution for DNS
- **D-02:** Resolve the deployment VPS public IP using the following multi-tier fallback chain:
  1. Read `deploy_vps_ip` from `coolify.json` server alias (explicit for deploy server).
  2. Query `GET /servers/{uuid}` IP field from Coolify API (skipping `host.docker.internal`).
  3. Read `vps_ip` from `coolify.json` (only in localhost case).
  4. Run SSH query `curl -s -4 ifconfig.me` on `DEPLOY_SSH_HOST`.

### Application Server Verification
- **D-03:** Post-creation verification: after application `CREATE` succeeds and returns `APP_UUID`, fetch `GET /applications/{uuid}` and verify that the destination server UUID matches `DEPLOY_SERVER_UUID`. Hard-fail with a descriptive error message on mismatch to prevent silent mis-routing.

### SSH Host Override
- **D-04:** Resolve `DEPLOY_SSH_HOST` by checking:
  1. `deploy_ssh_host` in `coolify.json` server alias (new optional field).
  2. `ssh_host` in `coolify.json` server alias (fallback).

### Validation and Verification Checks
- **D-05:** `validate.sh` must check `deploy_server` existence. If `deploy_server` is set in `coolify.yaml` but not registered in Coolify, `validate.sh` must print a list of registered Coolify servers and accumulate a failure. This check must run after API connectivity checks.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

- `scripts/lib-coolify-api.sh` — target for `coolify_get_destination_uuid` updates.
- `scripts/provision.sh` — target for `DEPLOY_SERVER_NAME`, `DEPLOY_SSH_HOST`, `DEPLOY_VPS_IP` resolution and app creation updates.
- `scripts/validate.sh` — target for validation updates check.
- `scripts/lib-dns-api.sh` — dns signature reference.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `coolify_get_server_uuid()`: fetches registered servers and matches by name.
- `coolify_curl()`: standard API client wrapper.
- `fail()` in `validate.sh`: standard validator helper to accumulate errors.

### Established Patterns
- Sourcing library files via relative paths resolved dynamically using `SCRIPT_DIR`.
- Parsing YAML via inline Python scripts executed within `eval "$(python3 -c ...)"`.
- Validating IPv4 format using `grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'`.

</code_context>

<specifics>
## Specific Ideas

- Ensure all variables introduced use clear prefix `DEPLOY_` (e.g., `DEPLOY_SERVER_NAME`, `DEPLOY_SERVER_UUID`, `DEPLOY_SSH_HOST`, `DEPLOY_VPS_IP`) to make separate server routing distinct from host server routing.
- Skip any `host.docker.internal` value retrieved from the `/servers/{uuid}` endpoint since it indicates an internal address rather than a public VPS IP.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 04-multi-server-deployment*
*Context gathered: 2026-06-07*
