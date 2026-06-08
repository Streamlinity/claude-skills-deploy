---
created: 2026-05-27T16:18:36.391Z
title: Add DNS provisioning and cleanup to deployment skill
area: tooling
files:
  - scripts/provision.sh
  - scripts/validate.sh
  - init/init.sh
  - test/e2e.sh
  - docs/setup-guide.md
  - docs/schema.md
  - README.md
---

## Problem

The skill provisions Coolify apps and Doppler secrets but does nothing about DNS. A new deployment needs DNS A records (or CNAMEs) pointing staging and production domains at the VPS IP before HTTPS/Let's Encrypt can work. Currently the operator must do this manually — often the step most likely to be missed or done wrong.

The same gap exists in the cleanup script: DNS records created during provisioning are never removed, leaving orphaned records after teardown.

## Solution

1. **Ask upfront in `init.sh`**: prompt for DNS provider (Cloudflare, GoDaddy, etc.) and collect the required API credentials. Store provider + credential key names in `coolify.yaml` under a new `dns:` block (key names only — values go in Doppler or `~/.claude/coolify.json`).

2. **Extend `provision.sh`**: after Coolify apps are created, resolve the VPS IP from `ssh_host` or a new `vps_ip` field in `coolify.json`, then call the DNS provider API to upsert A records for staging and production domains. Use the same lookup-then-create-if-missing idempotency pattern already established for Coolify resources.

3. **Extend `validate.sh`**: check that DNS credentials are present (same as the Doppler key presence check pattern). No mutations.

4. **E2E test (`test/e2e.sh`)**: provision DNS records as part of the hello-world test; remove them unconditionally in the `trap EXIT` cleanup handler.

5. **Cleanup script**: add DNS record deletion for staging + production domains, using IDs/zone info captured in the e2e report JSON (same pattern as `coolify_project_uuid`, `ssh_host`, etc.).

6. **Docs**: update `setup-guide.md`, `schema.md` (new `dns:` block), and `README.md` prerequisites to document provider options, required API keys, and the automated flow.

Start with Cloudflare (most common) and make provider selection extensible via a `lib-dns-api.sh` library following the `lib-coolify-api.sh` pattern.
