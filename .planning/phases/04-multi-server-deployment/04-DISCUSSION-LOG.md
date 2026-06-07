# Phase 4: Multi-Server Deployment - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-07
**Phase:** 04-multi-server-deployment
**Areas discussed:** Destination UUID Lookup, VPS IP Resolution, MSRV-02 post-create verification, deploy_ssh_host fallback

---

## Destination UUID Lookup

| Option | Description | Selected |
|--------|-------------|----------|
| Scan GET /applications + GET /destinations + empty fallback | Try to scan existing apps on the server via `GET /applications`, fall back to `GET /destinations`, and finally fall back to an empty string (allowing Coolify to auto-assign). | ✓ |
| Strict lookup | Fail provisioning immediately if a valid destination UUID is not found on the server. | |

**User's choice:** Scan applications first with fallback.
**Notes:** Better behavior for remote servers (scan finds UUID from any existing app on that server, or returns empty and lets Coolify auto-assign).

---

## VPS IP Resolution

| Option | Description | Selected |
|--------|-------------|----------|
| Multi-tier fallback | Multi-tier fallback: `deploy_vps_ip` (config) -> `GET /servers/{uuid}` IP field (skipping internal host IP) -> `vps_ip` (localhost only) -> SSH `ifconfig.me` on the deployment VPS. | ✓ |
| Strict config | Require `deploy_vps_ip` to be defined in `coolify.json` when `deploy_server` is set; do not fall back to SSH `ifconfig.me` or the API. | |

**User's choice:** Multi-tier fallback.
**Notes:** Robust and flexible, leverages the Coolify API and fallback SSH checks automatically if configurations are incomplete.

---

## MSRV-02 Post-Create Verification

| Option | Description | Selected |
|--------|-------------|----------|
| Verify server UUID match | Query `GET /applications/{app_uuid}` post-creation and verify that the destination server UUID matches the target server. Hard-fail if there is a mismatch. | ✓ |
| Skip verification | Assume Coolify routes it correctly based on the payload and skip post-creation server validation. | |

**User's choice:** Verify server UUID match post-creation.
**Notes:** Safety guard to prevent silent mis-routing of deployments to the wrong host.

---

## Claude's Discretion

- Exact formatting of validate.sh error list.
- Template comments and user prompts style.

## Deferred Ideas

None.
