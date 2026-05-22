---
phase: 01-bug-fixes
plan: "03"
subsystem: scripts/provision.sh, docs/schema.md
tags: [bug-fix, configurable, backward-compatible, documentation]
dependency_graph:
  requires: ["01-02"]
  provides: [BUG-03-fix]
  affects: [scripts/provision.sh, docs/schema.md]
tech_stack:
  added: []
  patterns: [python3-json-inline-read, coolify-json-optional-field-with-default]
key_files:
  modified:
    - scripts/provision.sh
    - docs/schema.md
decisions:
  - "D-06: Read server_name from coolify.json using same python3 json.load pattern as ssh_host, with 'localhost' default"
  - "D-07: Document server_name in Optional Fields per Server Entry subsection and Backward Compatibility section, following ssh_host migration block pattern"
metrics:
  duration: "~3 minutes"
  completed: "2026-05-22T07:31:44Z"
  tasks_completed: 2
  files_modified: 2
---

# Phase 1 Plan 3: Fix Hardcoded server_name in provision.sh (BUG-03) Summary

Replaced the hardcoded `coolify_get_server_uuid "localhost"` call in `scripts/provision.sh` with a configurable `server_name` field read from `~/.claude/coolify.json`, defaulting to `"localhost"` for backward compatibility. Documented the new optional field in `docs/schema.md`.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Replace hardcoded 'localhost' in provision.sh with server_name from coolify.json | 8650e47 | scripts/provision.sh |
| 2 | Document server_name as optional field in docs/schema.md | 8497d5c | docs/schema.md |

## What Was Done

### Task 1 — provision.sh fix (8650e47)

Replaced lines 46-51 in `scripts/provision.sh`. The original code:

```bash
SERVER_UUID=$(coolify_get_server_uuid "localhost")
[ -n "$SERVER_UUID" ] || { echo "ERROR: server 'localhost' not found in Coolify" >&2; exit 1; }
```

Now reads `server_name` from `coolify.json` using the same `python3 -c` / `json.load` pattern already used for `ssh_host`:

```bash
SERVER_NAME=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
print(e.get('server_name','localhost'))
")
SERVER_UUID=$(coolify_get_server_uuid "$SERVER_NAME")
[ -n "$SERVER_UUID" ] || { echo "ERROR: server '$SERVER_NAME' not found in Coolify ..." >&2; exit 1; }
```

The diagnostic echo also now shows `server_name=$SERVER_NAME` for observability.

### Task 2 — schema.md documentation (8497d5c)

Two additions to `docs/schema.md`:

1. **Optional Fields per Server Entry** subsection (inserted after the `ssh_host` required-fields block) — a table documenting `server_name`, its `"localhost"` default, and when to set it.

2. **Backward Compatibility** section — new `server_name (added in Phase 1 bug fixes)` subsection between the existing `ssh_host` and `coolify_app_ids` blocks, following the identical pattern. Cites the historical error message and explains the migration path.

## Verification

All plan-level checks pass:

- `grep -F 'coolify_get_server_uuid "localhost"' scripts/provision.sh` → 0 matches (hardcoded literal gone)
- `grep -F 'coolify_get_server_uuid "$SERVER_NAME"' scripts/provision.sh` → 1 match
- `grep -F "e.get('server_name','localhost')" scripts/provision.sh` → 1 match
- `bash -n scripts/provision.sh` → exit 0
- `grep -F '### Optional Fields per Server Entry' docs/schema.md` → 1 match
- `` grep -F '`server_name` (added in Phase 1 bug fixes)' docs/schema.md `` → 1 match
- `grep -o 'server_name' docs/schema.md | wc -l` → 5 (≥ 4 required)
- Smoke test: default `"localhost"` returned when `server_name` absent from `coolify.json` → OK

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — both files are fully wired. No placeholder values or TODO markers introduced.

## Self-Check: PASSED

- scripts/provision.sh: modified, committed at 8650e47
- docs/schema.md: modified, committed at 8497d5c
- No hardcoded `coolify_get_server_uuid "localhost"` remains in provision.sh
- All acceptance criteria verified via grep and bash -n
