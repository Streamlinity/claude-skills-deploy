---
name: setup-coolify
description: This skill should be used when the user runs /setup-coolify, /setup-coolify plan, /setup-coolify init_cicd, /setup-coolify init_app, or /setup-coolify validate. Provisions and updates a Coolify deployment for the current repo from coolify.yaml, configures Doppler secret injection (all env_vars including NEXT_PUBLIC_* injected at runtime via DOPPLER_TOKEN — same-image promotion model), and generates .github/workflows/deploy.yml. Reads coolify.yaml from the working directory and credentials from ~/.claude/coolify.json. Designed to work across multiple repos and multiple Coolify servers via the server alias in coolify.yaml.
disable-model-invocation: true
argument-hint: "[plan | init_cicd | init_app | validate | (blank = provision)]"
allowed-tools: Read Write Bash
---

# setup-coolify

Arguments: `$ARGUMENTS`

Provision or update a Coolify + Doppler deployment from `coolify.yaml` in the current
working directory. Same skill works for any repo and any Coolify server — the `server:`
alias in `coolify.yaml` selects both the Coolify URL and the Doppler account.

## Subcommands

| Form | Action |
|------|--------|
| `/setup-coolify` | Provision/update: ensures Doppler keys exist, upserts every app in the `environments:` map (staging + production required; extra envs like `qa` provisioned identically), syncs env vars, mounts Doppler-fallback volume. Does NOT deploy — the first deploy fires on push to `main` via the generated workflow. Idempotent. |
| `/setup-coolify plan` | Read-only diff (Terraform-style): runs `provision.sh --plan`, reporting `+ CREATE` / `= EXISTS` / `~ PATCH` per resource (project, apps, volumes, Doppler tokens, DNS records) against live state, then exits. Nothing is mutated. Use before re-running provision on a production server. |
| `/setup-coolify init_cicd` | Interactive setup of `~/.claude/coolify.json` for a new server alias. Prompts for url, api_key, doppler_account, ssh_host. Validates existing credentials before prompting for replacement. |
| `/setup-coolify init_app` | Bootstraps `coolify.yaml` and `.github/workflows/deploy.yml` in the current repo. Prompts for project name, server alias, domains, env vars, and optional deploy_server/deploy_ssh_host. Seeds dev+stg Doppler configs from `.env.local` when present. |
| `/setup-coolify validate` | Validates that all `env_vars` keys in coolify.yaml exist in Doppler staging AND production configs; verifies Coolify API reachability. If `.env.local` or `.env.production` are present in the repo root, automatically fills any **missing** Doppler keys from those files before checking — `.env.local` seeds `dev` + `stg`, `.env.production` seeds `prd`. Never overwrites an existing Doppler value. |

## Secrets injection model (same-image promotion)

Coolify receives **only `DOPPLER_TOKEN`** — a service token scoped to the matching Doppler config (`stg` or `prd`). No other secret values are stored in or pass through Coolify. At container start, the Dockerfile ENTRYPOINT runs `doppler run` which uses `DOPPLER_TOKEN` to fetch all `env_vars` secrets directly from Doppler and inject them into the process environment.

The same Docker image is promoted from staging to production without a rebuild; the only thing that differs between the two app instances is the `DOPPLER_TOKEN` (scoped to the matching Doppler config). This means:
- **Staging** gets a service token for the `stg` Doppler config → all staging secrets
- **Production** gets a service token for the `prd` Doppler config → all production secrets
- `DOPPLER_TOKEN` itself is stored in Coolify and is visible in the Coolify UI, API responses, and deployment logs. It is a scoped service token — an attacker who obtains it can read all secrets in the matching Doppler config. Protect it accordingly (rotate on exposure; `--rotate-tokens` flag in provision).
- Actual secret values (DATABASE_URL, API keys, etc.) are never stored in or pass through Coolify. They flow directly from Doppler to the container at start time via `doppler run`.

The `# build_time: true` trailing-comment annotation in `coolify.yaml` is
**reserved for a future per-env build mode** and is NOT currently parsed by
this skill. Under the current model, the annotation has no behavioural effect —
every env_var is treated identically (runtime-injected). Do not rely on the
annotation to change provisioning behaviour today.

## Execution flow (provision = blank arguments)

1. **Load and validate config**
   - Parse `./coolify.yaml`. Bail if missing or invalid YAML.
   - Read `~/.claude/coolify.json`. Look up `servers.$SERVER_ALIAS` entry. Bail if missing.
   - Run `bash $HOME/.claude/skills/setup-coolify/scripts/validate.sh`. If non-zero, print errors and bail BEFORE touching Coolify.

2. **Discover Coolify topology by lookup-by-name (no hardcoded UUIDs)**
   - Source `lib-coolify-api.sh`. Call `coolify_upsert_project "$PROJECT_NAME"` to get project UUID.
   - Resolve `DEPLOY_SERVER_NAME`: uses `deploy_server` in `coolify.yaml` if set, otherwise reads `server_name` from `~/.claude/coolify.json` (`servers.<alias>.server_name`, default `localhost`). Call `coolify_get_server_uuid "$DEPLOY_SERVER_NAME"`. Bail if not found.
   - Call `coolify_get_destination_uuid "$DEPLOY_SERVER_UUID"` (which scans existing applications on the server first, falling back to `/destinations`).
   - Resolve `DEPLOY_SSH_HOST`: uses `deploy_ssh_host` in `coolify.json` if set, falling back to `ssh_host`. REQUIRED — bail if missing (used in step 3 to create the Doppler-cache Docker volume on the deployment VPS).

3. **Upsert staging app**
   - Compute name: `${PROJECT_NAME}-staging` (e.g. `skillmap-staging`).
   - `coolify_find_app_by_name` — if UUID returned, skip create. Else `POST /applications/private-github-app` with `source_type: registry` and `docker_registry_image_name: $REGISTRY_IMAGE`. PATCH `is_auto_deploy_enabled=false`.
   - Source `lib-doppler-api.sh`. Create a service token scoped to `staging` config. Set **only `DOPPLER_TOKEN`** on the Coolify app — no other secret values are stored in Coolify. The app's Dockerfile ENTRYPOINT runs `doppler run` which uses `DOPPLER_TOKEN` to fetch all `env_vars` secrets directly from Doppler at container start.
   - SSH to the deployment VPS (`DEPLOY_SSH_HOST`) and run `docker volume create ${APP_UUID}-doppler-cache`. PATCH the app with `custom_docker_run_options: --mount source=${APP_UUID}-doppler-cache,target=/etc/doppler-cache`.

4. **Upsert production app** (same flow, name = `${PROJECT_NAME}-production`)

5. **Write coolify_app_ids back to coolify.yaml** (consumed by `generate-workflow.sh` to embed app UUIDs in `deploy.yml`; provisioning never reads it back — every run re-resolves by name)

6. **Done.** `provision.sh` does NOT trigger an initial deploy. The first deploy is fired by pushing to `main`, which activates the generated `.github/workflows/deploy.yml` (build → GHCR → deploy-staging → smoke-test → deploy-production). To redeploy manually, push any commit to `main` or trigger the workflow from the GitHub Actions UI.

## init_cicd flow

Interactive prompts (server credential collection):
- Server alias to add (string, e.g. `my-server`)
- Coolify URL (e.g. `https://coolify.example.com`)
- API key (paste — token displayed once in Coolify UI)
- Doppler account name (e.g. `my-doppler-account`)
- SSH host alias (e.g. `my-vps`)
- Cloudflare API token (optional — leave blank if DNS is managed outside Cloudflare or manually). When provided, stored as `cloudflare_api_token` under the server entry. Token requires Zone:DNS:Edit scope. Also prompt for `dns_default` block: zone name (e.g. `example.com`) and credential key (`cloudflare_api_token`). This pre-populates the `dns:` block for future `coolify.yaml` generation and is used by `provision.sh` and `test/e2e.sh` to auto-create DNS A records.

If the alias already exists in `~/.claude/coolify.json`, validates existing credentials first (Coolify API ping + `doppler whoami`). Prompts to replace only if validation fails.

**Re-run to fill missing optional fields (gap-fill mode):** As the skill evolves, new optional fields are added to the server entry schema (`doppler_token`, `cloudflare_api_token`, `dns_default`). Older entries created before these fields existed will be missing them. Re-running `/setup-coolify init_cicd` for an existing alias is the supported upgrade path — it skips fields that already pass validation and only prompts for the fields that are absent or fail their check. `/setup-coolify validate` will print `WARN:` lines for any missing optional fields and instruct you to re-run `init_cicd` to fill them.

Merge into `~/.claude/coolify.json` (preserve existing servers). `chmod 0600`.

Example resulting server entry:
```json
"my-server": {
  "url": "https://coolify.example.com",
  "api_key": "...",
  "doppler_account": "MyOrg",
  "ssh_host": "my-vps",
  "cloudflare_api_token": "...",
  "dns_default": {
    "provider": "cloudflare",
    "zone_name": "example.com",
    "credential_source": "coolify_json",
    "credential_key": "cloudflare_api_token"
  }
}
```

## init_app flow

Run from the target repo root (`bash ~/.claude/skills/setup-coolify/init/init.sh`). Writes `./coolify.yaml` and `.github/workflows/deploy.yml`.

Interactive prompts:
- Project name, server alias, Doppler project, registry image, staging/production domains
- DNS provider (cloudflare/none) and optional DNS zone + credential config
- Optional deploy_server (Coolify-registered server name) and build context/Dockerfile
- Env var keys

After writing files, detects `.env.local` and offers to seed `dev` and `stg` Doppler configs from it.

## plan flow

Runs `bash $HOME/.claude/skills/setup-coolify/scripts/provision.sh --plan`.

Read-only: runs validate, resolves topology (project, server, destination, DNS zone),
then for every environment reports `+ CREATE` (resource absent), `= EXISTS` (matches
desired state), or `~ PATCH` (lists exactly which fields would change: domains, volume
mount, image name, health_check_path, DNS record IP). Exits 0 without mutating anything.

## validate flow

Runs `bash $HOME/.claude/skills/setup-coolify/scripts/validate.sh`.

1. Parses and schema-checks `coolify.yaml`.
2. Verifies server alias, ssh_host, Coolify API reachability, deploy_server, SSH connectivity, DNS credentials.
3. **Gap-fill from local .env files (automatic, targeted mutation):**
   - If `.env.local` exists in the repo root → sets any keys missing from Doppler `stg` and `dev` configs using values from the file.
   - If `.env.production` exists → sets any keys missing from Doppler `prd` config.
   - Only fills missing/empty keys. Never overwrites an existing Doppler value.
   - Logs every key filled with its target config.
4. Checks that every `env_vars` key from `coolify.yaml` exists in Doppler staging AND production with a non-placeholder value. Reports all failures before exiting (error-accumulation pattern).

The gap-fill step means a developer can run `/setup-coolify validate` immediately after cloning a repo (with `.env.local` present) and have their Doppler configs populated automatically, without a separate manual seeding step.

## See also

- `~/.claude/skills/setup-coolify/references/api-reference.md` — Coolify + Doppler API endpoint reference
- `docs/schema.md` (in the repo) — `coolify.yaml` and `coolify.json` schema reference, including the reserved `build_time: true` annotation
