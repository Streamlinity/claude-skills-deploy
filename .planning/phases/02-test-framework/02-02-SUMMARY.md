---
phase: 02-test-framework
plan: 02
subsystem: test
tags: [validation, static-analysis, yaml, github-actions]
dependency_graph:
  requires: []
  provides: [test/validate-workflow.sh]
  affects: []
tech_stack:
  added: []
  patterns: [inline-python-heredoc, error-accumulation]
key_files:
  created:
    - test/validate-workflow.sh
  modified: []
decisions:
  - "Inline Python heredoc (<<'PY') with single-quoted marker to prevent bash variable expansion in Python f-strings"
  - "Error accumulation pattern for VALID-02 — collect all broken needs refs before exiting, matching validate.sh convention"
metrics:
  duration: "5 minutes"
  completed: "2026-05-22"
  tasks_completed: 1
  files_changed: 1
---

# Phase 02 Plan 02: validate-workflow.sh Static Validator Summary

## One-liner

Standalone bash+Python static validator that catches YAML syntax errors and unresolved `needs:` job references in generated GitHub Actions deploy.yml files.

## What Was Built

`test/validate-workflow.sh` — a single-file standalone script that runs two checks:

- **VALID-01**: Parses the workflow file with `python3 yaml.safe_load` and exits 1 with `FAIL: YAML syntax error: <details>` if it fails
- **VALID-02**: Builds a set of all defined job names, then iterates every `needs:` value (handling both string scalar and list form), accumulates all broken references, and exits 1 printing one `FAIL: job '<job>' needs '<dep>' which is not defined` line per broken reference

On full pass: prints `OK: YAML syntax valid` and `OK: all needs references resolve`, exits 0.

This is the static defence against the BUG-01 regression class (the `smoke-staging` job reference bug fixed in Phase 01).

## Tasks Completed

| Task | Description | Commit |
|------|-------------|--------|
| 1 | Create test/validate-workflow.sh with VALID-01 + VALID-02 checks | 4dd0723 |

## Verification Results

All acceptance criteria passed:

- `bash -n` syntax check: PASS
- Shebang, strict mode, line-2 header convention: PASS
- `yaml.safe_load`, `defined = set(jobs.keys())`, `isinstance(needs, str)` present: PASS
- Behaviour check 1 (valid workflow exits 0): PASS
- Behaviour check 2 (broken string-form needs exits 1 with correct message): PASS
- Behaviour check 3 (broken list-form needs exits 1): PASS
- Behaviour check 4 (no args exits 1): PASS
- No library sourcing: PASS
- Min 40 lines (actual: 81): PASS

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None.

## Self-Check: PASSED

- `test/validate-workflow.sh` exists: FOUND
- Commit `4dd0723` exists: FOUND
