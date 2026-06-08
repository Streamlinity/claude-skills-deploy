---
name: setup-coolify
description: This skill should be used when the user runs /setup-coolify, /setup-coolify init, or /setup-coolify validate. Provisions and updates a Coolify deployment for the current repo from coolify.yaml, configures Doppler secret injection (all env_vars including NEXT_PUBLIC_* injected at runtime via DOPPLER_TOKEN — same-image promotion model), and generates .github/workflows/deploy.yml. Reads coolify.yaml from the working directory and credentials from ~/.claude/coolify.json. Designed to work across multiple repos and multiple Coolify servers via the server alias in coolify.yaml.
disable-model-invocation: true
argument-hint: "[init | validate | (blank = provision)]"
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
| `/setup-coolify` | Provision/update: ensures Doppler keys exist, upserts staging + production Coolify apps, syncs env vars, mounts Doppler-fallback volume, triggers initial deploy. Idempotent. |
| `/setup-coolify init` | Interactive setup of `~/.claude/coolify.json` for a new server alias. Prompts for url, api_key, doppler_account. |
| `/setup-coolify validate` | Dry-run: checks that all `env_vars` keys in coolify.yaml exist in Doppler staging AND production configs; verifies Coolify API reachability. No mutations. |

## Secrets injection model (same-image promotion)

All `env_vars` in `coolify.yaml` — including `NEXT_PUBLIC_*` keys — are set as
**runtime** Coolify env vars whose values are pulled from Doppler at container
start via `doppler run` (the Dockerfile ENTRYPOINT). The same Docker image is
promoted from staging to production without a rebuild; the only thing that differs
between the two app instances is the `DOPPLER_TOKEN` (scoped to the matching
Doppler config).

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
   - Source `lib-doppler-api.sh`. Create a service token scoped to `staging` config. Set `DOPPLER_TOKEN` env var on the app. Set every `env_vars` key on the app as a **runtime** env var (no build-time path under same-image promotion); values fetched from Doppler via `doppler --account <acct> secrets get --project <p> --config staging <KEY> --plain`.
   - SSH to the deployment VPS (`DEPLOY_SSH_HOST`) and run `docker volume create ${APP_UUID}-doppler-cache`. PATCH the app with `custom_docker_run_options: --mount source=${APP_UUID}-doppler-cache,target=/etc/doppler-cache`.

4. **Upsert production app** (same flow, name = `${PROJECT_NAME}-production`)

5. **Write coolify_app_ids back to coolify.yaml** (cache optimization)

6. **Done.** `provision.sh` does NOT trigger an initial deploy. The first deploy is fired by pushing to `main`, which activates the generated `.github/workflows/deploy.yml` (build → GHCR → deploy-staging → smoke-test → deploy-production). To redeploy manually, push any commit to `main` or trigger the workflow from the GitHub Actions UI.

## init flow

Interactive prompts:
- Server alias to add (string, e.g. `my-server`)
- Coolify URL (e.g. `https://coolify.example.com`)
- API key (paste — token displayed once in Coolify UI)
- Doppler account name (e.g. `my-doppler-account`)

Merge into `~/.claude/coolify.json` (preserve existing servers). `chmod 0600`.

## validate flow

Runs `bash $HOME/.claude/skills/setup-coolify/scripts/validate.sh`. See the script for details.

## See also

- `~/.claude/skills/setup-coolify/references/api-reference.md` — Coolify + Doppler API endpoint reference
- `docs/schema.md` (in the repo) — `coolify.yaml` and `coolify.json` schema reference, including the reserved `build_time: true` annotation
