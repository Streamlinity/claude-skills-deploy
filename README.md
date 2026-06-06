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
- Automated DNS A record provisioning (Cloudflare) — no more manual A records before HTTPS. When `dns: provider: cloudflare` is set, `/setup-coolify` creates staging + production A records pointing at your VPS automatically.

---

## Where to start?

Choose the pathway that matches your goal to avoid reading in circles:

| What are you trying to do? | Recommended Starting File | Description |
|----------------------------|----------------------------|-------------|
| **Learn the concepts** | 📊 [docs/architecture.md](./docs/architecture.md) | Component architecture, runtime pipelines, and directory layout |
| **Set up a new server/domain** | 🚀 [docs/setup-guide.md](./docs/setup-guide.md) | Authoritative step-by-step from zero VPS to running pipeline |
| **Run E2E integration tests** | 🧪 [docs/test-environment.md](./docs/test-environment.md) | Full guide to pushing the test image, running, and cleanup |
| **Configure YAML or JSON fields** | 📄 [docs/schema.md](./docs/schema.md) | Field references, optional parameters, and annotated examples |
| **Deploy a second domain / Fork** | 🌐 [docs/fork-guide.md](./docs/fork-guide.md) | Multi-domain configuration delta vs. making a true GitHub fork |

---

## Quick Install

Clone the repository directly into your personal Claude skills directory:

```bash
git clone https://github.com/anatesan-stream/claude-skills-deploy.git ~/.claude/skills/setup-coolify
```

Open any Claude Code session — `/setup-coolify` is immediately available. No build or install step is required.
If you are setting this up for the first time, go to **[docs/setup-guide.md](./docs/setup-guide.md)** to configure your server credentials.

**Local tooling checklist** (quick verify before running anything):

```bash
claude --version                        # Claude Code installed
doppler --version                       # 3.76.0 or later
gh auth status                          # GitHub CLI authenticated
python3 -c "import yaml; print('ok')"   # PyYAML present
ssh -o BatchMode=yes <ssh-alias> 'echo ok'  # SSH alias resolves
```

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
| `MISSING:DNS_CREDENTIAL:CLOUDFLARE_API_TOKEN` | DNS provider is cloudflare but the token is not present in the configured source | `doppler secrets set CLOUDFLARE_API_TOKEN --project <p> --config stg` (or add `cloudflare_api_token` to `coolify.json` if using `credential_source: coolify_json`) |
| `ERROR: fqdn '...' is not under configured DNS zone '...'` | `dns.zone_name` is not a suffix of the staging or production domain | Check `dns.zone_name` in `coolify.yaml` — it must be a suffix of both domains (e.g. `example.com` covers `app.example.com` and `app-staging.example.com`) |
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

## E2E Integration Testing

To verify the skill against real staging/production environments, run the end-to-end integration test suite. This suite provisions a throwaway Coolify project, deploys a hello-world container, smoke-tests HTTPS connectivity, and tears down all resources automatically.

See **[docs/test-environment.md](./docs/test-environment.md)** for full instructions on setting up, running, and cleaning up tests.

---

## Next Steps

- Check out **[docs/architecture.md](./docs/architecture.md)** for concepts and diagrams.
- Follow the authoritative **[docs/setup-guide.md](./docs/setup-guide.md)** to configure your servers.
- Read the canonical **[docs/schema.md](./docs/schema.md)** for detailed field schemas.
- Set up a different domain/organization? See **[docs/fork-guide.md](./docs/fork-guide.md)**.

