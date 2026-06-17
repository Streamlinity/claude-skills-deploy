# claude-skills-deploy

Coolify + Doppler deployment skill for Claude Code. One command bootstraps any repo into a same-image-promotion CI/CD pipeline with secrets managed by Doppler.

**What you get:**
- `/setup-coolify` — idempotent provisioning of Coolify staging + production apps, Doppler service tokens, and DNS A records
- Auto-generated `.github/workflows/deploy.yml` — build once, deploy to staging, smoke-test, promote the identical image to production
- `init.sh` bootstrapper — takes a new repo from zero to `coolify.yaml` + `deploy.yml` in under a minute
- Strictly read-only `validate` with explicit `seed` and `provision` subcommands — no silent side-effects

---

## Install

Clone directly into your Claude skills directory:

```bash
git clone https://github.com/Streamlinity/claude-skills-deploy.git ~/.claude/skills/setup-coolify
```

Open any Claude Code session — `/setup-coolify` is immediately available. No build step required.

**Update to latest:**

```bash
git -C ~/.claude/skills/setup-coolify pull
```

After pulling, run `/setup-coolify validate` in any repo — it will print `WARN:` lines for new optional fields missing from your `~/.claude/coolify.json`. Run `/setup-coolify init_cicd` to fill them interactively.

**Local tooling checklist:**

```bash
claude --version                        # Claude Code installed
doppler --version                       # 3.76.0 or later
gh auth status                          # GitHub CLI authenticated
python3 -c "import yaml; print('ok')"   # PyYAML present
ssh -o BatchMode=yes <ssh-alias> 'echo ok'  # SSH alias resolves
```

---

## Set up a new CI/CD environment

Use this path when you have a fresh VPS and want to get Coolify + Doppler wired up for the first time before deploying any apps.

**See [docs/setup-guide.md](./docs/setup-guide.md) for the authoritative step-by-step walkthrough.** The summary:

1. Provision a VPS (Vultr, Hetzner, EC2) and install Coolify:
   ```bash
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
   ```

2. Add an SSH host alias in `~/.ssh/config` pointing at the VPS.

3. Register the server in Claude's credential registry:
   ```
   /setup-coolify init_cicd
   ```
   Prompts for Coolify URL, API key, Doppler account, SSH host alias, and Doppler token. Writes to `~/.claude/coolify.json` (never committed).

4. Create a Doppler project + `staging` / `production` configs and seed your initial secrets. *(Browser step — Doppler UI.)*

5. Verify everything is reachable before touching any app:
   ```
   /setup-coolify validate
   ```

---

## Add an app to an existing environment

Use this path when Coolify + Doppler are already running and you want to onboard a new repo.

1. From the repo root, generate `coolify.yaml` and `.github/workflows/deploy.yml`:
   ```bash
   bash ~/.claude/skills/setup-coolify/init/init.sh
   ```
   Prompts for project name, server alias, domains, env var names, and optional multi-server config.

2. If you have local `.env` files, seed Doppler from them (never overwrites existing values):
   ```
   /setup-coolify seed
   ```

3. Dry-run check before provisioning:
   ```
   /setup-coolify validate
   ```

4. Provision Coolify apps, Docker volumes, and Doppler service tokens:
   ```
   /setup-coolify
   ```

5. Commit and push to activate the GitHub Actions pipeline:
   ```bash
   git add coolify.yaml .github/workflows/deploy.yml
   git commit -m "chore: add coolify deployment config"
   git push
   ```

---

## Upgrade or migrate an existing deployment

Use this path when updating the skill after a pull, adding a new required field, or re-provisioning an existing app on a new machine.

**Update the skill:**

```bash
git -C ~/.claude/skills/setup-coolify pull
```

**Check for new required fields:**

```
/setup-coolify validate
```

Any `FAIL:` lines indicate new Tier 1 or Tier 2 fields that must be added. Run `/setup-coolify init_cicd` to fill them interactively for the affected server alias.

**Re-provision (idempotent):**

```
/setup-coolify
```

Safe to re-run at any time — existing resources are detected by name and skipped; only missing or changed resources are created or patched.

**Preview changes before applying:**

```
/setup-coolify plan
```

Prints `+ CREATE` / `= EXISTS` / `~ PATCH` per resource against live state. Nothing is mutated.

---

## Subcommands

| Form | Action |
|------|--------|
| `/setup-coolify` | Provision/update: upserts Coolify project + apps, creates Doppler service tokens, mounts Doppler-fallback Docker volume, syncs env vars. Does NOT deploy — the first deploy fires on `git push` via the generated workflow. Idempotent. |
| `/setup-coolify provision` | Explicit alias for blank — same behavior as `/setup-coolify` with no arguments. |
| `/setup-coolify plan` | Read-only diff: reports `+ CREATE` / `= EXISTS` / `~ PATCH` per resource against live Coolify + Doppler state. Nothing is mutated. Use before re-running provision on a production server. |
| `/setup-coolify seed` | Explicit Doppler gap-fill: reads `.env.local` → seeds `dev` + `stg` configs; reads `.env.production` → seeds `prd`. Logs every key set. Never overwrites an existing Doppler value. Run this after creating a new Doppler project and before provisioning. |
| `/setup-coolify validate` | Strictly read-only: verifies coolify.yaml schema, coolify.json Tier 1 fields (`url`, `api_key`, `doppler_account`, `ssh_host`, `doppler_token`), Tier 2 feature-gated fields (`cloudflare_api_token` when `dns.credential_source: coolify_json`; `deploy_ssh_host`/`deploy_vps_ip` when `deploy_server` is set), Doppler key presence, and Coolify API reachability. No mutations. |
| `/setup-coolify init_cicd` | Interactive setup of `~/.claude/coolify.json` for a new server alias. Prompts for all Tier 1 fields. Validates existing credentials before prompting for replacement. |
| `/setup-coolify init_app` | Bootstraps `coolify.yaml` + `.github/workflows/deploy.yml` in the current repo. Equivalent to running `bash ~/.claude/skills/setup-coolify/init/init.sh`. |

---

## How it works

1. **You write** `coolify.yaml` (committed, no secrets) and `~/.claude/coolify.json` (machine-local, contains API keys and tokens — never commit this file).

2. **`/setup-coolify`** reads both and idempotently:
   - Upserts a Coolify project + staging app + production app (REST API, lookup-by-name)
   - Creates Doppler service tokens scoped per environment, sets `DOPPLER_TOKEN` on each Coolify app
   - SSHes to the Coolify host to create a persistent Docker volume at `/etc/doppler-cache` (Doppler fallback cache for stateless containers)
   - If `.env.local` or `.env.production` files are present, calls `seed.sh` to fill Doppler configs before mutating Coolify
   - Writes resulting app UUIDs back to `coolify.yaml` as a cache

3. **`generate-workflow.sh`** (called by `init.sh`, also runnable standalone) writes `.github/workflows/deploy.yml` that:
   - On push to `main`: builds the Docker image with a commit-SHA tag and pushes to GHCR
   - PATCHes the staging app to the new tag, triggers deploy, polls until healthy, runs smoke test
   - On staging green: PATCHes the production app to the **same tag** (no rebuild) and deploys

**Secrets model:** Coolify stores only `DOPPLER_TOKEN` — a service token scoped to the matching Doppler config (`stg` or `prd`). No other secrets pass through Coolify. At container start, `doppler run` uses `DOPPLER_TOKEN` to fetch all secrets directly from Doppler and inject them into the process environment.

---

## E2E Integration Testing

To verify the skill against a real Coolify server, run the end-to-end integration test suite:

```bash
E2E_SERVER=<server-alias> E2E_BASE_DOMAIN=<your-domain> bash test/e2e.sh
```

This provisions a throwaway Coolify project, pushes a hello-world container, smoke-tests HTTPS connectivity, and leaves the deployment running (no auto-teardown — new users should see the result). Clean up when done:

```bash
bash test/cleanup-deployment.sh test/results/<timestamp>.json
```

See **[docs/test-environment.md](./docs/test-environment.md)** for full setup instructions, including how to push the hello-world test image and how to run the offline contract tests without a live server.

---

## Reference

| Topic | Doc |
|-------|-----|
| `coolify.yaml` + `coolify.json` field schemas, 3-tier required/optional model | [docs/schema.md](./docs/schema.md) |
| Using this skill for a second domain (e.g. strategem.ai) without code changes | [docs/fork-guide.md](./docs/fork-guide.md) |
| Common errors and fixes | [docs/troubleshooting.md](./docs/troubleshooting.md) |
| Component architecture, runtime pipelines, directory layout | [docs/architecture.md](./docs/architecture.md) |
| Getting Doppler secrets working locally on a new machine | [docs/developer-onboarding.md](./docs/developer-onboarding.md) |
| Image digest traceability, deployment polling, verify-promotion | [docs/deployment-correctness.md](./docs/deployment-correctness.md) |
