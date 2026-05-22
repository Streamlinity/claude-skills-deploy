# Phase 3: Cleanup Script - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-22
**Phase:** 03-cleanup-script
**Areas discussed:** Cleanup scope, Report file schema, Partial failure handling, Server credentials

---

## Cleanup Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Full teardown | Mirror e2e.sh cleanup() exactly: staging app, production app, Coolify project, Docker volumes via SSH, Doppler project | ✓ |
| Coolify-only | Delete apps and project; leave Docker volumes and Doppler for operator | |
| Coolify + Doppler, skip volumes | Delete apps, project, Doppler; skip SSH-based volume removal | |

**User's choice:** Full teardown
**Notes:** Mirror the existing e2e.sh cleanup() function exactly — everything the test created gets removed.

---

## Report File Schema

| Option | Description | Selected |
|--------|-------------|----------|
| Full teardown record | staging URL, project UUID, staging/production app UUIDs, Doppler project name, server alias, SSH host, per-step results, timestamp | ✓ |
| Minimal (required only) | staging URL, Coolify project UUID, staging app UUID, per-step pass/fail, run timestamp | |
| Coolify UUIDs + server alias | app UUIDs, project UUID, server alias, Doppler project name — skip SSH host | |

**User's choice:** Full teardown record — self-contained so cleanup needs no flags.

---

## Partial Failure Handling

| Option | Description | Selected |
|--------|-------------|----------|
| Warn-and-continue | Print ⚠ warning, continue, exit 0 if all resolved | ✓ |
| Fail-fast | Exit non-zero on first failed DELETE | |
| Strict with summary | Attempt all, exit non-zero if any failed | |

**User's choice:** Warn-and-continue — matches e2e.sh's existing pattern.

---

## Server Credentials

| Option | Description | Selected |
|--------|-------------|----------|
| Read server alias from report file | Script calls coolify_load_server with alias from report — no flags needed | ✓ |
| Optional --server flag, fallback to report | Accept --server override, fall back to report | |
| Require --server flag | Operator must always pass --server explicitly | |

**User's choice:** Read from report file — self-contained operation.

---

## Claude's Discretion

- Exact wording of confirmation block
- Optional dry-run flag (not required)
- Whether to preview before deleting

## Deferred Ideas

None.
