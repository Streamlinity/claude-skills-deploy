# Phase 1: Bug Fixes - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-22
**Phase:** 01-bug-fixes
**Areas discussed:** BUG-01 scope, BUG-02 fail behavior, BUG-03 docs

---

## BUG-01 scope

| Option | Description | Selected |
|--------|-------------|----------|
| Fix both | Change needs: [deploy-staging, build] AND change smoke URL from '/' to '/api/health' — both in same heredoc, zero extra risk | ✓ |
| Strict phase scope | Only change needs: [deploy-staging]. Leave smoke URL for Phase 2. | |

**User's choice:** Fix both
**Notes:** Both changes are in the same heredoc in generate-workflow.sh. Smoke URL bug is MEDIUM severity in CONCERNS.md but trivial to fix alongside the required change.

---

## BUG-02 fail behavior

### Question 1: Fail strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Fail fast on first bad key | Raise SystemExit immediately with key + stderr | |
| Collect all bad keys, then fail | Loop all keys, accumulate failures, print full list, exit non-zero | ✓ |

**User's choice:** Collect all bad keys, then fail

### Question 2: Error output format

| Option | Description | Selected |
|--------|-------------|----------|
| Key + stderr from Doppler | `ERROR: doppler secrets get KEY_NAME failed: <subprocess stderr>` | ✓ |
| Key name only | `ERROR: failed to fetch KEY_NAME from Doppler` | |

**User's choice:** Key + stderr from Doppler
**Notes:** Operator needs the actual Doppler error to diagnose root cause without re-running manually.

---

## BUG-03 docs

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, update schema.md | Add server_name as optional field, follow ssh_host migration note pattern | ✓ |
| Code only, skip docs | Fix provision.sh only, leave schema.md for later | |

**User's choice:** Yes, update schema.md

---

## Claude's Discretion

- Exact Python error message wording (structure decided, wording open)
- Whether to print a summary header before per-key errors
- How server_name is extracted from coolify.json (Python inline or function extension)

## Deferred Ideas

None — discussion stayed within phase scope.
