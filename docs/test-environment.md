# Test Environment Setup

A complete guide to setting up and running the E2E integration test suite. The test
exercises the full skill against real infrastructure: it provisions a throwaway Coolify
project, deploys a hello-world container, smoke-tests the live HTTPS URL, and hands off
to a cleanup script to tear everything down.

---

## Overview

The test workflow has three phases:

```
Phase 1: Run     →  test/e2e.sh              creates resources, deploys, smoke-tests
Phase 2: Inspect →  (manual — browse the URL)  verify the live deployment looks right
Phase 3: Cleanup →  test/cleanup-deployment.sh  tears down all created resources
```

The handoff between phases is a JSON report written to `test/results/YYYYMMDDHHMMSS.json`
by `test/e2e.sh`. The cleanup script reads this file and needs nothing else from the
operator — all Coolify UUIDs, the SSH host alias, and the Doppler project slug are
embedded in the report automatically.

---

## Prerequisites

### 1. Complete the main setup guide

The test runs against a real Coolify server. Before you can run the E2E test you need:

- A Coolify instance with HTTPS enabled and a valid API token
- DNS coverage for test subdomains following the pattern `csd-hello-test-YYYYMMDDHHMMSS-staging.<base-domain>`. Either:
  - A wildcard A record (e.g., `*.cicd.streamlinity.com → <vps-ip>`), **or**
  - `dns_default` configured in `~/.claude/coolify.json` for the server alias — the test then creates and cleans up per-run A records automatically via the Cloudflare API
- `~/.claude/coolify.json` populated with the server alias, URL, API key, Doppler
  account, and SSH host
- Doppler CLI authenticated (`doppler login`)
- SSH alias resolving to the VPS

See **[docs/setup-guide.md](./setup-guide.md)** if any of the above is not yet in place.

### 2. Local tooling

```bash
# Verify all required tools are present and authenticated
doppler --version          # 3.76.0 or later
docker info                # Docker daemon running
docker buildx version      # buildx for linux/amd64 cross-build (if on Apple Silicon)
ssh -o BatchMode=yes <ssh-alias> 'echo ok'  # SSH alias resolves
```

Python 3 with PyYAML is also required (used by `provision.sh` and `validate.sh`):

```bash
python3 -c "import yaml; print('ok')"
```

### 3. Test image in GHCR

The test deploys a minimal nginx container from `test/hello-world/`. This image must
exist in GHCR before the test can run. It only needs to be pushed once (or when
`test/hello-world/` changes).

**What the test image does:**
- nginx:alpine base, listens on port 3000
- `GET /api/health` → `200 OK` with body `claude-skills-deploy-e2e-ok`
- `GET /` → static `index.html` containing the same sentinel string
- The smoke test checks both the HTTP status code and the sentinel string body

**Option A — Push via CI (recommended, no PAT needed):**

GitHub Actions workflow `push-test-image.yml` builds and pushes the image using
`GITHUB_TOKEN` (no separate PAT required). Trigger it manually:

```bash
gh workflow run push-test-image.yml --repo anatesan-stream/claude-skills-deploy
```

Or it runs automatically on any push to `main` that modifies `test/hello-world/`.

**Option B — Push from your local machine:**

Requires a GitHub PAT with `write:packages, read:packages, delete:packages` scopes.

1. Create the PAT at `https://github.com/settings/tokens/new`.

2. Store it in Doppler so any operator can push without sharing secrets out-of-band:
   ```bash
   doppler secrets set GHCR_TOKEN --project claude-skills-deploy --config stg
   ```
   Paste the token value when prompted.

3. Push the image:
   ```bash
   bash test/push-hello-world.sh
   ```
   The script reads `GHCR_TOKEN` from Doppler automatically if the env var is not set.
   To override the GHCR org (e.g., for a fork):
   ```bash
   GHCR_ORG=my-org bash test/push-hello-world.sh
   ```

**Verify the image is pullable** before running the test:
```bash
docker pull ghcr.io/anatesan-stream/csd-hello-world:latest
```

### 4. Required environment variables

The test requires two environment variables. Both have no default — the test will print
a specific error and exit if either is missing.

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `E2E_SERVER` | Yes | Server alias key from `~/.claude/coolify.json` | `vultr-stream` |
| `E2E_BASE_DOMAIN` | Yes | Base domain for test subdomains. Must be covered by a wildcard DNS A record pointing at the VPS. | `cicd.streamlinity.com` |
| `E2E_IMAGE` | No | Docker image to deploy. Defaults to `ghcr.io/anatesan-stream/csd-hello-world:latest`. Override to use your fork's image. | `ghcr.io/my-org/csd-hello-world:latest` |

---

## Running the test

### Phase 1: Run

```bash
E2E_SERVER=<alias> E2E_BASE_DOMAIN=<base-domain> bash test/e2e.sh
```

For the reference implementation:
```bash
E2E_SERVER=vultr-stream E2E_BASE_DOMAIN=cicd.streamlinity.com bash test/e2e.sh
```

Flag equivalents:
```bash
bash test/e2e.sh --server vultr-stream           # same as E2E_SERVER=
bash test/e2e.sh --server vultr-stream --keep    # skip teardown on failure (debug mode)
```

The test takes 3–5 minutes. It prints a step-by-step log and exits 0 on full success.
At the end of a successful run, you will see:

```
  Staging URL: https://csd-e2e-YYYYMMDDHHMMSS-staging.<base-domain>
  Report:      test/results/YYYYMMDDHHMMSS.json
  Next step:   bash test/cleanup-deployment.sh test/results/YYYYMMDDHHMMSS.json
```

**What the test does internally:**

0. Scans for stale `csd-hello-test-*` resources from previous runs (report files, Coolify apps, DNS records) and deletes them before starting
1. Verifies prerequisites (Coolify API reachable, Doppler authenticated, test image pullable)
2. Creates a throwaway Doppler project (`csd-hello-test-YYYYMMDDHHMMSS`) with `stg`/`prd` configs and seeds dummy secrets
3. Generates a temporary `coolify.yaml`; if `dns_default` is set in `~/.claude/coolify.json`, a `dns:` block is injected automatically
4. Runs `validate.sh` (dry-run pre-flight, including DNS credential check)
5. Runs `provision.sh` (creates Coolify project + staging + production apps, wires Doppler service tokens, mounts Docker volumes; creates DNS A records if configured)
6. Triggers a staging deploy via the Coolify API and polls until `running:healthy`
7. Smoke-tests the staging HTTPS URL (`/api/health` → HTTP 200 + body contains sentinel string)
8. Triggers a production deploy and polls until `running:healthy`
9. Writes `test/results/YYYYMMDDHHMMSS.json` (the handoff report)
10. Prints a completion summary: staging and production URLs, DNS records created (with record IDs), and the exact cleanup command

**On success:** all resources (DNS records, Coolify apps, Doppler project) are left running for inspection. Run the cleanup command from the summary when done.

**On failure:** all resources are torn down automatically via `trap EXIT` — including any DNS records created before the failure. Use `--keep` to suppress teardown and inspect the broken state manually; with `--keep`, DNS records are also left running.

### Phase 2: Inspect

The completion summary at the end of the test output prints the live URLs directly. You can also browse them:

```
https://csd-hello-test-YYYYMMDDHHMMSS-staging.<base-domain>/api/health  → 200 OK
https://csd-hello-test-YYYYMMDDHHMMSS-staging.<base-domain>/            → hello-world page
https://csd-hello-test-YYYYMMDDHHMMSS-production.<base-domain>/         → same hello-world page
```

In Coolify UI, verify that:
- The throwaway project (`csd-hello-test-YYYYMMDDHHMMSS`) is visible
- Both staging and production apps show a green running status
- Environment Variables on each app show `DOPPLER_TOKEN` set to a service token

### Phase 3: Cleanup

When done inspecting, pass the report file to the cleanup script:

```bash
bash test/cleanup-deployment.sh test/results/YYYYMMDDHHMMSS.json
```

Use the filename printed at the end of the test output. All files in `test/results/` are
also listed by `ls test/results/` if you need to find it.

**What the report file contains:**

```json
{
  "run_timestamp": "2026-06-05T20:15:42+00:00",
  "server_alias": "vultr-stream",
  "ssh_host": "v_cicd_stream",
  "staging_url": "https://csd-hello-test-20260605-201542-staging.cicd.streamlinity.com",
  "coolify_project_uuid": "mtbk0jixkdzwpgzvhfkmw6bb",
  "staging_app_uuid": "w104d7pje7caa46rbh91974m",
  "production_app_uuid": "dmjt4oi8m78jvapyffzpx34x",
  "doppler_project": "csd-hello-test-20260605-201542",
  "dns_provider": "cloudflare",
  "dns_zone_id": "0460cc9ea6669c54884bfe98317396ea",
  "dns_zone_name": "streamlinity.com",
  "dns_credential_source": "coolify_json",
  "dns_credential_key": "cloudflare_api_token",
  "dns_records": [
    {"name": "csd-hello-test-20260605-201542-staging.cicd.streamlinity.com", "record_id": "c5737094abc298b6...", "type": "A"},
    {"name": "csd-hello-test-20260605-201542-production.cicd.streamlinity.com", "record_id": "e83961f8ef1e2360...", "type": "A"}
  ],
  "steps": [ ... ]
}
```

The cleanup script reads every field it needs directly from this file. You do not need to
look up any IDs manually.

**What cleanup deletes** (in dependency order — Coolify requires apps to be removed before the project):

| Step | Resource | Method |
|------|----------|--------|
| 1 | DNS A records (if any) | Cloudflare API: delete each record by ID from the `dns_records` array in the report |
| 2 | Staging app | Coolify API `DELETE /applications/<staging_app_uuid>` |
| 3 | Production app | Coolify API `DELETE /applications/<production_app_uuid>` |
| 4 | Coolify project | Coolify API `DELETE /projects/<coolify_project_uuid>` (retried up to 3× with backoff) |
| 5 | Docker volumes (×2) | SSH to VPS: `docker volume rm <app-uuid>-doppler-cache` for each app |
| 6 | Doppler project | `doppler projects delete <doppler_project>` |

The cleanup script prints a confirmation block and exits 0. It is idempotent — safe to
re-run against the same report if interrupted.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERROR: E2E_SERVER is required` | `E2E_SERVER` env var not set and `--server` flag not passed | Set `E2E_SERVER=<alias>` before the command, or use `--server <alias>` |
| `ERROR: E2E_BASE_DOMAIN is required` | `E2E_BASE_DOMAIN` env var not set | Set `E2E_BASE_DOMAIN=<base-domain>` — must match a wildcard DNS A record pointing at your VPS |
| `test image not found or not pullable` | Hello-world image not yet pushed to GHCR | Run `bash test/push-hello-world.sh` or trigger the `push-test-image.yml` CI workflow |
| Smoke test times out (>120s) | Container failed to start, or DNS not propagated | Check Coolify UI → app logs. Verify the base domain wildcard A record resolves from the VPS. |
| `ssh: Could not resolve hostname` | `ssh_host` alias not in `~/.ssh/config`, or not populated in `coolify.json` | Confirm `~/.ssh/config` has the alias and `ssh -o BatchMode=yes <alias> 'echo ok'` returns `ok` |
| `ERROR: report file missing fields: ssh_host, doppler_project` | Report was written by a pre-Phase-3 version of `e2e.sh` | Use a report from a recent run, or patch the JSON manually with the missing fields |
| `⚠ could not delete Coolify project` after cleanup | Project delete failed even after retry | The project may contain other apps not created by this test run. Delete manually in Coolify UI. |
| `⚠ could not delete <fqdn>` during cleanup | Cloudflare API token expired or wrong permissions | Verify the token in `~/.claude/coolify.json` has **Zone → DNS → Edit** permission, then delete the orphaned A records manually in Cloudflare dashboard. |
| `MISSING:DNS_CREDENTIAL:...` in validate output | DNS provider is `cloudflare` but the token is not in the configured source | Add `cloudflare_api_token` to the server entry in `~/.claude/coolify.json` (if `credential_source: coolify_json`) or set it as a Doppler secret (if `credential_source: doppler`). |
| Doppler delete fails | `csd-hello-test-*` project already deleted or CLI not authenticated | Re-authenticate with `doppler login` and retry, or delete manually at `dashboard.doppler.com` |

---

## Next Steps

- **Return to the Setup Guide:** Go back to **[docs/setup-guide.md](./setup-guide.md)** to continue bootstrapping your application repositories.
- **Review Field Schemas:** Refer to **[docs/schema.md](./schema.md)** for a full field-by-field reference of `coolify.yaml` and `coolify.json`.
