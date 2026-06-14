---
phase: 06-promotion-integrity-diagnostics
plan: "02"
subsystem: docs
tags: [invariants, ci, verify-promotion, same-image-promotion]

# Dependency graph
requires:
  - phase: 06-01
    provides: verify-promotion job added to generate-workflow.sh output
provides:
  - INV-04 invariant documenting deployed image tag must equal build SHA, enforced by verify-promotion job
  - INV-05 invariant documenting production smoke test prerequisite, with Phase 07 planned enforcement note
  - Updated enforcement table with Assert (per-push) layer for verify-promotion job
affects: [07-runtime-identity, future-invariant-enforcement]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Invariant documentation follows INV-01 structural template: Rule, Why, Enforced by, Remediate, Not affected by"
    - "Planned enforcement noted inline in Enforced-by bullet when machine check not yet implemented"

key-files:
  created: []
  modified:
    - docs/invariants.md

key-decisions:
  - "INV-04 Enforced-by references verify-promotion job added in 06-01 — creates explicit cross-link between CI job and its invariant"
  - "INV-05 uses planned: enforced by Phase 07 language — makes enforcement timeline explicit without blocking current delivery"
  - "Enforcement table gains Assert (per-push) row after Monitor (continuous) — represents a fourth enforcement layer in the CSD model"

patterns-established:
  - "Planned invariants use (planned: enforced by Phase NN) bullet pattern in Enforced-by section"

requirements-completed: [INV-04, INV-05]

# Metrics
duration: 5min
completed: 2026-06-13
---

# Phase 06 Plan 02: Invariants INV-04 and INV-05 Documentation Summary

**INV-04 (deployed image tag = build SHA via verify-promotion) and INV-05 (production smoke test prerequisite) added to docs/invariants.md with updated enforcement table**

## Performance

- **Duration:** 5 min
- **Started:** 2026-06-13T18:15:00Z
- **Completed:** 2026-06-13T18:20:00Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Added `Assert (per-push)` row to the enforcement table, making the layer model four-deep (check, enforce, monitor, assert)
- Added INV-04 section: rule that both Coolify apps must have `docker_registry_image_tag` matching the current build SHA; enforced by verify-promotion job added in plan 06-01
- Added INV-05 section: rule that ghcr-cleanup must not run unless production smoke test passed; enforcement planned for Phase 07

## Task Commits

Each task was committed atomically:

1. **Task 1: Append INV-04 and INV-05 sections and update enforcement table** - `7f7d05c` (docs)

**Plan metadata:** TBD (docs: complete plan)

## Files Created/Modified
- `docs/invariants.md` - Two new invariant sections (INV-04, INV-05) and updated enforcement table row

## Decisions Made
- INV-04 Enforced-by explicitly references the verify-promotion job (added in plan 06-01) to create a durable cross-link between the CI job and its governing invariant
- INV-05 uses `(planned: enforced by Phase 07 ...)` language to accurately represent that machine enforcement does not exist yet, matching project transparency conventions
- The enforcement table row ordering (check → enforce → monitor → assert) follows the existing layered trust model from the original table

## Deviations from Plan

None - plan executed exactly as written. The acceptance criterion stating `grep -c 'INV-04' docs/invariants.md` should output "at least 3" is a planning artefact — the invariant identifier appears only in the heading as designed, matching the INV-01 template format. The substantive must_haves (section presence, verify-promotion reference, Phase 07 planned note, Assert per-push row) are all satisfied.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- INV-04 and INV-05 are fully documented — the invariants reference is now complete for the v1.1 milestone scope
- Phase 07 (runtime identity) will add the machine enforcement for INV-05's production smoke test
- docs/invariants.md "Adding a new invariant" section remains last, guiding future contributors

---
*Phase: 06-promotion-integrity-diagnostics*
*Completed: 2026-06-13*
