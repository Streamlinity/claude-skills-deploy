# Per-Domain Setup Guide

A complete walkthrough from blank VPS to a working Coolify + Doppler CI/CD pipeline.
Follow these steps once per Coolify instance (i.e., once per domain/org). After this
guide is complete, run `bash init/init.sh` in any target repo to bootstrap it.

---

## Overview

This guide covers the one-time infrastructure setup required before you can run
`/setup-coolify` on any repo. You will: stand up a Coolify instance, generate an API
token, add an SSH alias, configure Doppler, populate `~/.claude/coolify.json`, wire up
GitHub Actions secrets, and finally bootstrap + provision your first repo.

The reference implementation is skillmap on Vultr (IP `149.248.4.46`) using Doppler
workspace `streamlinity` and Coolify at `https://coolify.cicd.streamlinity.com`. Replace
these values with your own throughout.

---

## DNS setup

Provision your VPS first (Step 1, items 1–3) to get the public IP. Then create DNS
records using one of the two options below. The Coolify dashboard record
(`coolify.<your-domain>`) must always be created manually (it predates the skill).
App A records (staging + production) can be automated via Cloudflare.

### Option A: Automated DNS via Cloudflare (recommended)

Skip the manual per-app records below. Instead:

1. Create a Cloudflare API token at `https://dash.cloudflare.com/profile/api-tokens`
   with **Zone: DNS: Edit** permission scoped to your target zone. Copy the token.

2. Store it in Doppler (staging config — DNS credentials are shared across environments):
   ```bash
   doppler secrets set CLOUDFLARE_API_TOKEN --project <your-project> --config stg
   ```
   Or store it in `~/.claude/coolify.json` if you prefer `credential_source: coolify_json`
   (see [docs/schema.md](./schema.md) for the `dns:` block schema).

3. When running `bash init/init.sh`, answer `cloudflare` to the DNS provider prompt.
   The generated `coolify.yaml` will contain a `dns:` block. `/setup-coolify` then
   creates A records for staging and production automatically after Coolify apps are
   provisioned.

**Still required manually** (predates the skill):

| Purpose | Type | Name | Value |
|---------|------|------|-------|
| Coolify dashboard | A | `coolify.<your-domain>` | `<vps-ip>` |

> **Note:** If your staging/production domains use a wildcard A record at the DNS
> provider, automated DNS provisioning is still safe — the skill's upsert is idempotent.

### Option B: Manual DNS records

If you are not using Cloudflare, or prefer manual control, create these records before
running `/setup-coolify`:

| Purpose | Type | Name | Value | Notes |
|---------|------|------|-------|-------|
| Coolify dashboard | A | `coolify.<your-domain>` | `<vps-ip>` | Required for HTTPS on Coolify UI |
| Deployed app — staging | A | `*.<base-domain>` | `<vps-ip>` | Wildcard covers all `<app>-staging.<base-domain>` subdomains |
| Deployed app — production | A | `<app>.<your-domain>` | `<vps-ip>` | One record per production app |
| E2E test subdomains | — | (covered by wildcard or automated DNS) | — | `csd-hello-test-*-staging.<base-domain>` — resolved by wildcard A record, or created automatically per-run when `dns_default` is set in `coolify.json` |

**Reference implementation** for `streamlinity.com` on Vultr IP `149.248.4.46`:

```
coolify.cicd.streamlinity.com   A   149.248.4.46   # Coolify dashboard + API
*.cicd.streamlinity.com         A   149.248.4.46   # wildcard for all app subdomains
skillmap.cicd.streamlinity.com  A   149.248.4.46   # production app (or covered by wildcard)
```

> **Wildcard vs. explicit records:** A wildcard (`*.<base-domain>`) covers staging,
> E2E test throwaway subdomains, and any new apps automatically. Most DNS providers
> support wildcard A records. If yours does not, add explicit A records for each
> `<app>-staging.<base-domain>` and `<app>-production.<base-domain>`.

### DNS propagation

Let's Encrypt HTTP-01 challenges require the A record to resolve from the public internet
before certificate issuance will succeed. After creating records, verify propagation:

```bash
dig +short coolify.<your-domain>          # should return <vps-ip>
dig +short anything.cicd.<your-domain>    # should return <vps-ip> (wildcard check)
```

Allow up to 10 minutes for propagation on most providers (Cloudflare is typically
near-instant). Do not proceed to Step 1 item 5 (enabling HTTPS) until both resolve.

---

## Step 1: Stand up a Coolify instance

**Recommended VPS providers:** Vultr, Hetzner, AWS EC2. A $6–12/mo VPS (2 vCPU, 4 GB RAM)
is sufficient for most workloads. Ubuntu 22.04 LTS is the tested base image.

1. Provision a new VPS, note its public IP.
2. SSH in as root:
   ```bash
   ssh root@<ip>
   ```
3. Install Coolify:
   ```bash
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
   ```
   This installs Docker, Coolify, and sets up systemd. The install takes 2–5 minutes.
4. Once the install completes, open `http://<ip>:8000` in a browser. Create your admin
   account on the first-run wizard.
5. Enable HTTPS: navigate to Coolify **Settings → Configuration → HTTPS** and follow the
   prompts to issue a Let's Encrypt certificate for your Coolify domain. You will need a
   DNS A record pointing to the VPS IP first (e.g., `coolify.cicd.example.com → <ip>`).

**Post-install: clear `allowed_ips`**

By default Coolify may restrict API access to specific IPs. Before API calls from
GitHub Actions (or your local machine) will work, open Coolify **Settings → Security**
and clear `allowed_ips` (set to `*` or your known IP ranges). Leaving this at the
default value causes every API call to return HTTP 403 even with a valid token.

---

## Step 2: Generate a Coolify API token

1. Log in to your Coolify dashboard.
2. Navigate to **Settings → Keys & Tokens → API Tokens**.
3. Click **Create Token**. Give it a descriptive name (e.g., `claude-skills-deploy`).
4. Scope: **read + write** (the skill needs write access to create/update apps).
5. **Copy the token immediately.** Coolify uses Laravel Sanctum which stores hashed tokens
   only — the plaintext is shown once at creation and cannot be retrieved later.
6. Store it temporarily in a secure note; you will paste it into `~/.claude/coolify.json`
   and into a GitHub Actions secret in steps below.

---

## Step 3: Create the SSH alias

The skill SSHes to your Coolify server to create persistent Docker volumes (Doppler
fallback cache). Add an alias to `~/.ssh/config`:

```
Host my-coolify-server
  HostName <ip-address>
  User root
  IdentityFile ~/.ssh/id_ed25519
```

Replace `my-coolify-server` with a memorable alias (e.g., `vultr-stream`,
`hetzner-strategem`). This alias is the value you set for `ssh_host` in
`~/.claude/coolify.json` and `server:` in `coolify.yaml`.

Confirm the alias works:
```bash
ssh -o BatchMode=yes my-coolify-server 'echo ok'
```
The output should be `ok`. If it times out, check the VPS firewall (port 22 must be
open) and that your public key is in `root@<ip>:~/.ssh/authorized_keys`.

---

## Step 4: Set up Doppler

1. **Install the Doppler CLI:**
   ```bash
   curl -Ls --tlsv1.2 --proto "=https" https://cli.doppler.com/install.sh | sh
   doppler --version   # should be 3.76.0 or later
   ```

2. **Authenticate:**
   ```bash
   doppler login
   ```
   This opens a browser OAuth flow. Complete it and return to the terminal.

3. **Create a Doppler project** (one project per repo you deploy):
   ```bash
   doppler projects create <project-name>
   ```
   Or create via the Doppler dashboard at `dashboard.doppler.com`. Use a slug that
   matches your repo name (e.g., `skillmap`, `strategem-website`).

4. **Create the required configs.** Doppler uses "configs" for environments. The skill
   expects `stg` and `prd` configs (Doppler's actual defaults):
   ```bash
   # Doppler creates dev, dev_personal, stg, and prd by default for new projects.
   # Verify they exist:
   doppler configs --project <project-name>
   ```
   If `stg` or `prd` are absent, create them via the dashboard:
   Doppler → Your Project → Configs → Add Config.

5. **Seed secrets.** Every key listed in `env_vars` in your `coolify.yaml` must exist in
   both the `stg` and `prd` Doppler configs before `/setup-coolify validate` will pass:
   ```bash
   doppler secrets set --project <project-name> --config stg KEY=value
   doppler secrets set --project <project-name> --config prd KEY=value
   ```
   Repeat for every key your application needs (e.g., `DATABASE_URL`,
   `ANTHROPIC_API_KEY`, `STRIPE_SECRET_KEY`).

---

## Step 5: Configure ~/.claude/coolify.json

Create (or update) `~/.claude/coolify.json` with your server entry. You can write this file manually or generate it interactively.

**Option A: Interactive Flow (Recommended)**
Run:
```bash
/setup-coolify init
```
This prompts you for the server alias, URL, API key, Doppler account, and SSH host, then merges the new entry into `~/.claude/coolify.json` and automatically sets the correct permissions.

**Option B: Manual Setup**
Create the file at `~/.claude/coolify.json` using this format (see **[docs/schema.md](./schema.md#coolifyjson--machine-local-credentials)** for the canonical field reference and detailed description of each property):

Concrete example for the reference implementation (with optional DNS fields):
```json
{
  "servers": {
    "vultr-stream": {
      "url": "https://coolify.cicd.streamlinity.com",
      "api_key": "xOIN...",
      "doppler_account": "streamlinity",
      "ssh_host": "v_cicd_stream",
      "cloudflare_api_token": "cfut_...",
      "dns_default": {
        "provider": "cloudflare",
        "zone_name": "streamlinity.com",
        "credential_source": "coolify_json",
        "credential_key": "cloudflare_api_token"
      }
    }
  }
}
```

The `cloudflare_api_token` and `dns_default` fields are optional. Add them if you want automated DNS provisioning. `dns_default` is also read by `test/e2e.sh` to inject a `dns:` block into E2E test runs, so DNS record creation and cleanup are exercised automatically during testing. See [docs/schema.md](./schema.md) for the full field reference.

**Secure the file immediately:**
```bash
chmod 0600 ~/.claude/coolify.json
```

---

## Step 6: Set up the GitHub repo

The generated `.github/workflows/deploy.yml` requires two GitHub Actions secrets:

1. **`COOLIFY_API_KEY`** — the Coolify API token from Step 2:
   ```bash
   gh secret set COOLIFY_API_KEY --body "<token>"
   ```

2. **`COOLIFY_URL`** — the Coolify instance root URL:
   ```bash
   gh secret set COOLIFY_URL --body "https://coolify.cicd.streamlinity.com"
   ```

3. **Enable GHCR write permission.** GitHub Actions needs permission to push Docker images
   to GHCR (GitHub Container Registry). In your repo settings:
   - Go to **Settings → Actions → General → Workflow permissions**
   - Select **Read and write permissions**
   - Save.

   Or via CLI:
   ```bash
   gh api repos/{owner}/{repo} --method PATCH --field default_workflow_permissions=write
   ```

---

## Step 6b: Store GHCR_TOKEN for local E2E testing

The E2E test script (`test/e2e.sh`) needs to pull the hello-world test image from GHCR.
The image must be pushed once before the test can run. This requires a GitHub PAT with
`write:packages` scope stored in Doppler.

**Why Doppler, not an env var?** Any operator with access to the `claude-skills-deploy`
Doppler project can push the test image and run E2E tests without sharing secrets
out-of-band. The token is never committed.

**One-time setup:**

1. Create a GitHub PAT with `write:packages, read:packages, delete:packages` scopes at
   `https://github.com/settings/tokens/new`.

2. Store it in Doppler:
   ```bash
   doppler secrets set GHCR_TOKEN --project claude-skills-deploy --config stg
   ```

3. Push the hello-world test image (only needed once, or when `test/hello-world/` changes):
   ```bash
   bash test/push-hello-world.sh
   ```
   The script automatically reads `GHCR_TOKEN` from Doppler if it is not set in the
   environment.

**Alternative — CI push (no PAT required):** The `push-test-image.yml` workflow in this
repo builds and pushes the test image using `GITHUB_TOKEN` (no separate PAT). Run it
manually from GitHub Actions → "Push E2E Test Image" → Run workflow, or it triggers
automatically when `test/hello-world/` changes on `main`.

**Teardown safety:** `GHCR_TOKEN` lives in the `claude-skills-deploy` Doppler project.
E2E cleanup only deletes the throwaway test project (e.g., `csd-e2e-YYYYMMDDHHMMSS`)
from Doppler — it never touches the `claude-skills-deploy` project or its secrets.

---

## Step 7: Bootstrap and provision

With all setup complete, bootstrap any target repo:

```bash
# Navigate to the repo root:
cd ~/development/<your-project>

# Run the bootstrapper (writes BOTH coolify.yaml AND .github/workflows/deploy.yml):
bash ~/.claude/skills/setup-coolify/init/init.sh
```

You will be prompted for:
- Project name (e.g., `skillmap`)
- Server alias (must match a key in `~/.claude/coolify.json`, e.g., `vultr-stream`)
- Doppler project slug (e.g., `skillmap`)
- GHCR registry image (e.g., `ghcr.io/anatesan-stream/ai-upskilling`)
- Staging domain (e.g., `skillmap-staging.cicd.streamlinity.com`)
- Production domain (e.g., `skillmap.cicd.streamlinity.com`)
- DNS provider (default `cloudflare`; enter `none` to skip automated DNS)
- DNS zone name (e.g., `streamlinity.com` — derived from production domain by default)
- DNS credential source (`doppler` or `coolify_json`)
- DNS credential key (name of the Doppler secret or `coolify.json` field holding your API token)
- Build context (default `.`; set to `./skillmap` only for monorepos with a nested app)
- Dockerfile path (default `./Dockerfile`)
- Env var keys (space-separated list of all keys your app needs)

After the bootstrapper completes, validate and provision:
```bash
/setup-coolify validate    # dry-run: checks Doppler keys + Coolify API
/setup-coolify             # provisions staging + production apps (idempotent)
```

Commit and push the generated files:
```bash
git add coolify.yaml .github/workflows/deploy.yml
git commit -m "ci: add Coolify deploy pipeline"
git push
```

---

## Step 8: Run the E2E integration test

The E2E test exercises the full skill end-to-end against your real infrastructure: it
creates a throwaway Coolify project + Doppler project, provisions staging and production
apps, deploys a hello-world container, and smoke-tests the live HTTPS URL. Run this once
after Step 7 to confirm your setup is correct before using the skill on a real repo.

See **[docs/test-environment.md](./test-environment.md)** for the full guide including
prerequisites (test image setup, required env vars), the run/inspect/cleanup workflow,
the report file format, and a troubleshooting table.

**Quick reference** (assuming Step 6b is complete):

```bash
# Run the test (~3-5 minutes)
E2E_SERVER=<alias> E2E_BASE_DOMAIN=<base-domain> bash test/e2e.sh

# Inspect: browse to the staging URL printed in the output

# Clean up when done
bash test/cleanup-deployment.sh test/results/YYYYMMDDHHMMSS.json
```

---

## Verifying success

1. **Check the GitHub Actions workflow was registered:**
   ```bash
   gh workflow view Deploy --repo <org>/<repo>
   ```

2. **Trigger a test push.** Push any commit to `main`. The workflow runs:
   - Build Docker image → push to GHCR with `sha-<commit>` tag
   - Patch staging app → trigger staging deploy → smoke test (HTTP 200 on `/api/health`)
   - On smoke test green: patch production app → trigger production deploy

3. **Check Coolify UI.** Both apps (`<project>-staging` and `<project>-production`) should
   appear in the Coolify project with a green status indicator after the first deploy.

4. **Verify Doppler token injection.** In Coolify, open either app → Environment Variables.
   You should see `DOPPLER_TOKEN` set to a service token, plus all `env_vars` keys listed
   (with `DOPPLER_*` prefix from Coolify's display). The actual secret values are NOT
   stored in Coolify — they are pulled from Doppler at container start.

5. **Visit the staging URL** in a browser. The app should load without errors.

---

## Next Steps

- **Verify your pipeline:** Follow **[docs/test-environment.md](./test-environment.md)** to run the end-to-end integration tests on your new server.
- **Deploying to a different domain / organization?** Review the **[docs/fork-guide.md](./fork-guide.md)** to understand the clone vs. fork workflow for organization-wide custom templates.
