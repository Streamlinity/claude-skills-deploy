# Milestones

## v1.0 v1.0 (Shipped: 2026-06-08)

**Phases completed:** 5 phases, 14 plans, 18 tasks

**Key accomplishments:**

- Edit 1 — Line 138:
- Python heredoc in provision.sh now checks result.returncode, accumulates per-key (key, stderr) failures, and raises SystemExit(1) with named-key error lines after exhausting all keys
- One-liner:
- E2E_SERVER and E2E_BASE_DOMAIN now fail fast with actionable errors pointing to /setup-coolify init, replacing silent vultr-stream/cicd.streamlinity.com defaults
- Removed dead-code `coolify_get_github_app_uuid` reference from SKILL.md step 2, corrected step 6 (no auto-deploy), replaced maintainer-specific init examples with generic placeholders, and fixed broken See also link to docs/schema.md
- Task 1: Insert ## Quick start section above ## Prerequisites in README.md
- Domain-neutral `references/api-reference.md` with top-of-file placeholder note and all maintainer-specific values replaced with `<your-coolify-domain>`, `<your-doppler-account>`, `<your-app-domain>`, and `<your-ssh-host>`
- One-liner:
- Completed:
- Completed:
- Documented deploy_server, deploy_ssh_host, and deploy_vps_ip schema references, added a 'Deploy to a separate VPS' setup guide, created a delete-and-reprovision migration guide, and updated SKILL.md execution flow details.
- Created a unit-style bash regression test that verifies scripts/validate.sh rejects unregistered deploy_server targets and baseline backward-compatible deployments run successfully.

---
