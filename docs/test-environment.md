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
- DNS wildcard covering the base domain (e.g., `*.cicd.streamlinity.com`) — test
  subdomains follow the pattern `csd-e2e-YYYYMMDDHHMMSS-staging.<base-domain>`
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

1. Verifies prerequisites (Coolify API reachable, Doppler authenticated, test image pullable)
2. Creates a throwaway Doppler project (`csd-e2e-YYYYMMDDHHMMSS`) with `stg`/`prd` configs and seeds dummy secrets
3. Generates a temporary `coolify.yaml` scoped to the throwaway project
4. Runs `validate.sh` (dry-run pre-flight)
5. Runs `provision.sh` (creates Coolify project + staging app + production app, wires Doppler service tokens, mounts Docker volumes)
6. Triggers a staging deploy via the Coolify API and polls until the container reports `running:healthy`
7. Triggers a production deploy
8. Smoke-tests the staging HTTPS URL (`/api/health` → HTTP 200 + body contains sentinel string)
9. Writes `test/results/YYYYMMDDHHMMSS.json` (the handoff report)

**Failure behaviour:** if any step fails, all created resources are deleted automatically
via a `trap EXIT` handler, and the report is still written with whatever was completed.
Use `--keep` to suppress the failure teardown if you need to inspect the broken state in
the Coolify UI.

### Phase 2: Inspect

After a successful run, open the staging URL in a browser:

```
https://csd-e2e-YYYYMMDDHHMMSS-staging.<base-domain>/api/health  → 200 OK
https://csd-e2e-YYYYMMDDHHMMSS-staging.<base-domain>/            → hello-world page
```

In Coolify UI, verify that:
- The throwaway project (`csd-e2e-YYYYMMDDHHMMSS`) is visible
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
  "run_timestamp": "2026-05-22T11:10:12+00:00",
  "server_alias": "vultr-stream",
  "ssh_host": "v_cicd_stream",
  "staging_url": "https://csd-e2e-...-staging.cicd.streamlinity.com",
  "coolify_project_uuid": "c14f0xso31g3k3scu42v1kb1",
  "staging_app_uuid": "su6tfh4w4pi7iz728f59wbis",
  "production_app_uuid": "yzdewk70emltd0wgajqk61cd",
  "doppler_project": "csd-e2e-2026-05-22-111012",
  "steps": [ ... ]
}
```

The cleanup script reads every field it needs directly from this file. You do not need to
look up any IDs manually.

**What cleanup deletes** (in dependency order — Coolify requires apps to be removed before the project):

| Step | Resource | Method |
|------|----------|--------|
| 1 | Staging app | Coolify API `DELETE /applications/<staging_app_uuid>` |
| 2 | Production app | Coolify API `DELETE /applications/<production_app_uuid>` |
| 3 | Coolify project | Coolify API `DELETE /projects/<coolify_project_uuid>` (retried up to 3× with backoff) |
| 4 | Docker volumes (×2) | SSH to VPS: `docker volume rm <app-uuid>-doppler-cache` for each app |
| 5 | Doppler project | `doppler projects delete <doppler_project>` |

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
| Doppler delete fails | `csd-e2e-*` project already deleted or CLI not authenticated | Re-authenticate with `doppler login` and retry, or delete manually at `dashboard.doppler.com` |
