#!/usr/bin/env bash
# validate-workflow.sh — Static validator for GitHub Actions workflow YAML.
#
# Usage: bash test/validate-workflow.sh <path-to-deploy.yml>
#
# Exit 0: both checks pass
# Exit 1: YAML syntax error OR unresolved needs: reference OR missing/bad arg
#
# Checks:
#   VALID-01  YAML parses without error (python3 yaml.safe_load)
#   VALID-02  every job name in every `needs:` list (string or list form) exists
#             as a defined job in the same file
#
# On VALID-02 failure all offending references are accumulated and printed before
# exit (matches validate.sh error-accumulation pattern in CONVENTIONS.md).

set -euo pipefail


YAML_FILE="${1:-}"
if [ -z "$YAML_FILE" ]; then
  echo "Usage: bash test/validate-workflow.sh <path-to-deploy.yml>" >&2
  exit 1
fi
if [ ! -f "$YAML_FILE" ]; then
  echo "ERROR: file not found: $YAML_FILE" >&2
  exit 1
fi

# ── VALID-01: YAML syntax ─────────────────────────────────────────────────────

python3 - "$YAML_FILE" <<'PY'
import sys, yaml
path = sys.argv[1]
try:
    with open(path) as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"FAIL: YAML syntax error: {e}", file=sys.stderr)
    sys.exit(1)
print("OK: YAML syntax valid")
PY

# ── VALID-02: needs: references resolve ───────────────────────────────────────

python3 - "$YAML_FILE" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f) or {}

jobs = data.get("jobs", {}) or {}
defined = set(jobs.keys())
errors = []

for job_name, job_def in jobs.items():
    if not isinstance(job_def, dict):
        continue
    needs = job_def.get("needs", [])
    # GitHub Actions allows needs: as a string scalar OR a list of strings.
    if isinstance(needs, str):
        needs = [needs]
    if needs is None:
        needs = []
    for dep in needs:
        if dep not in defined:
            errors.append((job_name, dep))

if errors:
    for job_name, dep in errors:
        print(
            f"FAIL: job '{job_name}' needs '{dep}' which is not defined",
            file=sys.stderr,
        )
    sys.exit(1)

print("OK: all needs references resolve")
PY

exit 0
