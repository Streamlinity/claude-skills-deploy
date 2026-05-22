---
status: partial
phase: 02-test-framework
source: [02-VERIFICATION.md]
started: 2026-05-22T16:59:55Z
updated: 2026-05-22T16:59:55Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Full E2E success run (TEST-01)
expected: `bash test/e2e.sh` completes all 9 steps against a live Coolify server, staging + production apps remain running after exit, `test/results/*.json` is written, and the `═══ Deployment complete` banner is printed
result: [pending]

### 2. E2E_SERVER/E2E_BASE_DOMAIN override path (TEST-04)
expected: `E2E_SERVER=other-server bash test/e2e.sh` runs against `other-server` with no script edits; `E2E_BASE_DOMAIN=foo.example.com bash test/e2e.sh` produces staging URL `<project>-staging.foo.example.com`
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
