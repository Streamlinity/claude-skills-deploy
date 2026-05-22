# claude-skills-deploy

Coolify + Doppler deployment skills for Claude Code. One command bootstraps any repo into a same-image-promotion CI/CD pipeline with secrets managed by Doppler.

**Status:** Production-ready for the reference implementation (skillmap on Vultr / streamlinity.com). Designed for multi-domain reuse via fork.

> **New here?** See **[docs/architecture.md](./docs/architecture.md)** for a diagram showing the two repos, three services, and how they connect — before diving into the setup steps below.

---

## What you get

- `/setup-coolify` Claude Code skill: provisions Coolify staging + production apps idempotently
- Doppler integration: all secrets injected at container start via `DOPPLER_TOKEN`
- Auto-generated `.github/workflows/deploy.yml` implementing GHCR same-image promotion (build once, deploy staging, smoke test, then deploy SAME image to production)
- `init.sh` bootstrapper: takes a new repo from zero to `coolify.yaml` + `.github/workflows/deploy.yml` in under a minute (one command, two files written)

---

## Quick start

The happy path in 5 commands. Full prerequisites (Doppler CLI, Python, an actual Coolify server) are documented below — see [Prerequisites](#prerequisites) and [docs/setup-guide.md](./docs/setup-guide.md) before running any of these against a real server.

1. **Install the skill**
   ```bash
   git clone https://github.com/anatesan-stream/claude-skills-deploy.git ~/.claude/skills/setup-coolify
   ```
   Drops the skill into your personal Claude Code skills directory. After this, `/setup-coolify` is available in any Claude Code session.

2. **Configure your Coolify server (one-time per machine + server pair)**
   ```
   /setup-coolify init
   ```
   Interactive prompts populate `~/.claude/coolify.json` with the Coolify URL, API key, Doppler account, and SSH host for one server alias.

3. **Bootstrap a repo**
   ```bash
   bash ~/.claude/skills/setup-coolify/init/init.sh
   ```
   Run from the target repo's root. Writes `./coolify.yaml` and `./.github/workflows/deploy.yml`.

4. **Dry-run check**
   ```
   /setup-coolify validate
   ```
   Verifies every `env_vars` key in `coolify.yaml` exists in Doppler and the Coolify API is reachable. No mutations.

5. **Provision**
   ```
   /setup-coolify
   ```
   Creates Coolify staging + production apps, wires Doppler service tokens, mounts the Doppler-cache Docker volume. Idempotent. After this, push to `main` triggers the first deploy via the generated `.github/workflows/deploy.yml`.

Need more? See [docs/setup-guide.md](./docs/setup-guide.md) for the full VPS + Coolify + Doppler stand-up walkthrough, or [docs/fork-guide.md](./docs/fork-guide.md) for adding a second domain to an existing setup.

---

## Prerequisites

Before running the install:

1. **Claude Code** installed and configured (`~/.claude/` directory exists)
2. **Doppler CLI** v3.76.0 or later:
   ```bash
   curl -Ls --tlsv1.2 --proto "=https" https://cli.doppler.com/install.sh | sh
   doppler --version
   ```
   Note: this skill does NOT use the deprecated `--account` flag (removed in v3.76.0).
3. **GitHub CLI** (`gh`) for repo operations:
   ```bash
   gh --version
   gh auth status
   ```
4. **Python 3 with PyYAML**:
   ```bash
   python3 -c "import yaml" || pip3 install pyyaml
   ```
5. **A Coolify instance** with HTTPS enabled and a generated API token (see [docs/setup-guide.md](./docs/setup-guide.md) if you need to stand one up)
6. **A Doppler workspace** with projects/configs scoped per environment (`staging`, `production`)
7. **An SSH alias** in `~/.ssh/config` for your Coolify host (used to create Docker volumes via SSH)

---

## Install

Clone the repo into your personal Claude skills directory. Repo root IS the skill directory (flat layout):

```bash
git clone https://github.com/anatesan-stream/claude-skills-deploy.git ~/.claude/skills/setup-coolify
```

Open any Claude Code session — `/setup-coolify` is immediately available. No build, no install step.

Verify:
```bash
ls ~/.claude/skills/setup-coolify/SKILL.md
```

---

## First-time configuration (per Coolify server)

Before the skill can provision anything, configure your machine:

1. Create `~/.claude/coolify.json` (or run `/setup-coolify init` for an interactive prompt):
   ```json
   {
     "servers": {
       "vultr-stream": {
         "url": "https://coolify.cicd.streamlinity.com",
         "api_key": "<paste from Coolify UI: Settings → Keys & Tokens>",
         "doppler_account": "streamlinity",
         "ssh_host": "v_cicd_stream"
       }
     }
   }
   ```
2. `chmod 0600 ~/.claude/coolify.json` (contains API keys).
3. Authenticate Doppler CLI: `doppler login` (one-time).
4. Confirm SSH alias resolves: `ssh -o BatchMode=yes <ssh_host> 'echo ok'`.

See **[docs/setup-guide.md](./docs/setup-guide.md)** for a full per-domain walkthrough including standing up a Coolify instance and creating a Doppler project.

---

## Bootstrap a new repo

From inside the target repo's root directory:

```bash
bash ~/.claude/skills/setup-coolify/init/init.sh
```

You'll be prompted for project name, server alias, Doppler project, GHCR registry image, staging domain, production domain, build paths, and env var keys. The script writes BOTH `./coolify.yaml` AND `./.github/workflows/deploy.yml` in one command. **No manual editing required.**

Then provision:
```bash
/setup-coolify validate    # dry-run check
/setup-coolify             # provision Coolify + Doppler
```

Commit:
```bash
git add .github/workflows/deploy.yml coolify.yaml
git commit -m "ci: add Coolify deploy pipeline" && git push
```

Push to `main` triggers: build to GHCR → deploy staging → smoke test → deploy production (same image).

---

## Subcommands

| Form | Action |
|------|--------|
| `/setup-coolify` | Provision/update: ensures Doppler keys exist, upserts staging + production Coolify apps, syncs env vars, mounts Doppler-fallback volume, triggers deploys. Idempotent. |
| `/setup-coolify init` | Interactive setup of `~/.claude/coolify.json` for a new server alias. Prompts for url, api_key, doppler_account, ssh_host. |
| `/setup-coolify validate` | Dry-run: checks every `env_vars` key in coolify.yaml exists in Doppler staging AND production. Verifies Coolify API reachability. No mutations. |

---

## Forking for a new domain

The skill is domain-agnostic. Every domain-specific value lives in `coolify.yaml` (committed per-repo) and `~/.claude/coolify.json` (machine-local). To use this skill for `strategem.ai` (or any other domain), you only change configuration — no code changes.

See **[docs/fork-guide.md](./docs/fork-guide.md)** for the strategem.ai walkthrough.

---

## Schema reference

See **[docs/schema.md](./docs/schema.md)** for full `coolify.yaml` and `coolify.json` field documentation.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERROR: 'ssh_host' field is missing` | `~/.claude/coolify.json` server entry has no `ssh_host` | Add `"ssh_host": "<alias>"` to the server entry. Must match a host alias in `~/.ssh/config`. |
| `MISSING:<KEY>:staging (key absent in Doppler)` | env_vars key in coolify.yaml not yet in the Doppler `staging` config | `doppler secrets set --project <p> --config staging <KEY>=<value>` |
| `doppler: unknown flag --account` | Old code using removed CLI flag | This skill does not use `--account`. If you wrote custom scripts, remove that flag (v3.76.0+). |
| `custom_docker_run_options did not round-trip` | Coolify did not persist the volume mount PATCH | Verify your Coolify version. Re-run `/setup-coolify` (idempotent). |
| `/setup-coolify` not found in Claude Code | Wrong install depth or symlink missing | Verify `~/.claude/skills/setup-coolify/SKILL.md` exists at exactly that path. The repo root must BE the skill directory. |
| `ModuleNotFoundError: No module named 'yaml'` | PyYAML not installed | `pip3 install pyyaml` |
| Staging smoke test times out in GitHub Actions | Coolify deploy took longer than 6 minutes | Check Coolify UI for deploy logs. Likely cause: image pull from GHCR is slow or app crashed at start. |

---

## How it works

1. **You write** `coolify.yaml` (committed, no secrets) and `~/.claude/coolify.json` (local, has secrets).
2. **`/setup-coolify`** reads both, then idempotently:
   - Upserts a Coolify project + staging app + production app (via REST API, lookup-by-name)
   - Creates Doppler service tokens scoped per env, sets `DOPPLER_TOKEN` env var on each app
   - SSHes to the Coolify host to create a persistent Docker volume at `/etc/doppler-cache` (Doppler fallback cache for stateless containers)
   - Writes the resulting app UUIDs back to `coolify.yaml` as a cache
3. **`generate-workflow.sh`** (invoked automatically by init.sh, or runnable standalone) writes `.github/workflows/deploy.yml` that:
   - On push to `main`, builds the Docker image with commit-SHA tag and pushes to GHCR
   - PATCHes the staging app to the new tag, triggers deploy, smoke-tests
   - On staging green, PATCHes the production app to the SAME tag (no rebuild) and deploys

---

## E2E integration test

`test/e2e.sh` exercises the full skill against your real infrastructure — creates a throwaway Coolify project + Doppler project, provisions staging + production apps, deploys a hello-world container, and smoke-tests the live staging URL.

**Success behaviour:** on a clean run, staging and production apps are left running so you can inspect the live deployment. A JSON report is written to `test/results/YYYYMMDD-HHMMSS.json` on every run (pass or fail). Run cleanup when ready: `bash test/cleanup-deployment.sh <report-file>`.

**Failure behaviour:** cleanup (teardown of all Coolify + Doppler resources) runs automatically via `trap EXIT`. Use `--keep` to suppress teardown and inspect the failure state manually.

**One-time setup** (build and push the test image to GHCR — needs a PAT with `write:packages` scope):

```bash
export GHCR_TOKEN=ghp_...    # github.com/settings/tokens/new → write:packages
bash test/push-hello-world.sh
```

**Run the test** (~3-5 minutes):

```bash
bash test/e2e.sh                                  # default server (vultr-stream) + domain (cicd.streamlinity.com)
bash test/e2e.sh --server hetzner-strategem       # test a different server alias
bash test/e2e.sh --keep                           # skip cleanup on failure (debug)
E2E_SERVER=other-alias bash test/e2e.sh           # override server via env var
E2E_BASE_DOMAIN=ci.example.com bash test/e2e.sh  # override base domain
```

The test exercises `validate.sh` → `provision.sh` → deploy trigger → deployment API polling → HTTPS smoke test (`/api/health` HTTP 200 + body check). If any step fails, cleanup runs and a report is still written. See `test/hello-world/` for the nginx:alpine test container (port 3000, `/api/health` endpoint).

---

## See also

- [Architecture & setup flow diagrams](./docs/architecture.md)
- [Schema reference](./docs/schema.md)
- [Per-domain setup guide](./docs/setup-guide.md)
- [Fork guide (strategem.ai example)](./docs/fork-guide.md)
- [Coolify + Doppler API reference](./references/api-reference.md)
