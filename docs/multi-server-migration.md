# Migrating an Existing App from localhost to a Separate Server

This guide covers converting an existing Coolify app that was deployed on
the Coolify host (the `localhost` server) to a separately-registered
Coolify server. This is required when you started with the default
deployment model and now want to split Coolify infrastructure from
application runtime onto distinct VPSes.

> **Important constraint:** Coolify has no API to move apps between servers. An app's destination server is set at create time and
> is immutable. The migration described below is destructive — the old
> app is deleted and a new one is created on the target server. There is
> no in-place rename or transfer path.

For new repos that have never been provisioned, you do not need this
guide: just set `deploy_server:` in `coolify.yaml` from the start and
follow **[docs/setup-guide.md → Deploy to a separate VPS](./setup-guide.md#deploy-to-a-separate-vps)**.

## Why migration is destructive

The Coolify API exposes `POST /applications/dockerimage` with a
`server_uuid` field — but this field is only honored at create time.
There is no `PATCH /applications/{uuid}/server` endpoint. The app's
`destination.server` relationship cannot be modified after creation. The
only way to move an app is delete + recreate.

The same constraint applies to the per-app Docker volumes that the skill
creates for the Doppler cache: they are created on the server that hosts
the app, and cannot be transferred between Docker hosts without a manual
`docker save` / `docker load` round-trip (out of scope for this skill).

## Migration steps

Run these steps from the target repo's root directory.

### Step 1: Document the current state

Before changing anything, capture the existing app UUIDs and any
operationally-meaningful state. From the repo root:

```bash
cat coolify.yaml | grep -A2 coolify_app_ids
```

Note the staging and production UUIDs. You will use these to confirm the
old apps are gone after Step 3.

If the apps have persistent state in their Docker volumes (database
files, uploaded assets, caches), back it up via SSH to the OLD server
before proceeding — the skill does NOT migrate volume contents:

```bash
ssh <old-ssh-host> "docker run --rm -v <volume-name>:/data -v \$(pwd):/backup busybox tar czf /backup/<volume-name>.tar.gz -C /data ."
```

Repeat for each persistent volume mounted by your app.

### Step 2: Delete the old apps in Coolify

There is no skill-provided command for this — Coolify has no API the
skill wraps for app deletion outside of the cleanup-deployment.sh test
harness. Delete the apps from the Coolify UI:

1. Coolify UI → your project → `<project>-staging` → **Settings →
   Delete Application**. Confirm.
2. Repeat for `<project>-production`.

Verify deletion via the API:

```bash
bash -c 'source ~/.claude/skills/setup-coolify/scripts/lib-coolify-api.sh && coolify_load_server <your-alias> && coolify_curl GET "/applications" | python3 -c "
import json,sys
apps=json.load(sys.stdin)
print([a[\"name\"] for a in apps if a[\"name\"].startswith(\"<project>-\")])
"'
```

Expected output: `[]` (empty list).

### Step 3: Clear coolify_app_ids in coolify.yaml

Edit `coolify.yaml` and replace the two app UUIDs with `~`:

```yaml
coolify_app_ids:
  staging: ~
  production: ~
```

These cache fields are what prevent `provision.sh` from re-creating apps
that already exist. Clearing them tells the next provision run to create
fresh apps on the new server.

### Step 4: Set deploy_server and deploy_ssh_host

Follow **[docs/setup-guide.md → Deploy to a separate VPS](./setup-guide.md#deploy-to-a-separate-vps)**
Steps A through D to:

1. Register the new VPS in Coolify (Step A)
2. Add an SSH alias for the new VPS (Step B)
3. Add `deploy_ssh_host` (and optionally `deploy_vps_ip`) to your existing
   `coolify.json` server entry (Step C)
4. Set `deploy_server: <new-server-name>` in `coolify.yaml` (Step D)

See **[docs/schema.md → Multi-server deployment (Phase 4)](./schema.md#multi-server-deployment-phase-4)**
for the canonical field reference.

### Step 5: Re-provision

```bash
/setup-coolify validate    # confirms new deploy_server exists in Coolify
/setup-coolify             # creates fresh apps on the new VPS
```

`provision.sh` will:

- Look up `deploy_server` in Coolify → get the new VPS UUID
- Create new apps with `server_uuid` pointing at the new VPS
- Verify (post-create) that the apps landed on the intended server
- Create Docker volumes on the new VPS via `deploy_ssh_host`
- Provision DNS A records targeting the new VPS public IP (if the
  `dns:` block is configured in `coolify.yaml`)
- Write back fresh app UUIDs to `coolify_app_ids` in `coolify.yaml`

### Step 6: Update DNS (manual case only)

If your `coolify.yaml` does NOT include a `dns:` block (provider: none or
block absent), update the staging and production A records manually at
your DNS provider to point at the new VPS public IP. The old localhost
apps are gone, so the old IP will not respond.

If the `dns:` block IS configured, `/setup-coolify` already updated the
A records — no manual DNS action required. Verify:

```bash
dig +short <staging-domain>     # should return new VPS IP
dig +short <production-domain>  # should return new VPS IP
```

### Step 7: Restore volume contents (if applicable)

If you backed up persistent volume contents in Step 1, restore them on
the new VPS:

```bash
# Copy the tarball to the new VPS
scp <volume-name>.tar.gz <new-ssh-host>:/tmp/

# Find the new volume name (provision.sh uses <app-uuid>-doppler-cache pattern
# for the Doppler cache; your app-specific volumes follow your own naming).
ssh <new-ssh-host> "docker volume ls"

# Restore into the new volume
ssh <new-ssh-host> "docker run --rm -v <new-volume-name>:/data -v /tmp:/backup busybox tar xzf /backup/<volume-name>.tar.gz -C /data"
```

For the Doppler secret cache volume specifically, no restore is needed —
the cache is rebuilt on first container start from Doppler.

## What is NOT migrated automatically

- **Docker volume contents** — application persistent data must be
  backed up + restored manually (Steps 1, 7)
- **GHCR images** — already pushed; the new apps pull from the same GHCR
  registry, no action needed
- **Doppler secrets** — stored in the Doppler project, not in Coolify;
  unaffected by app deletion + re-creation
- **GitHub Actions secrets** — `COOLIFY_API_KEY` and `COOLIFY_URL` are
  unchanged (same Coolify instance); the deploy workflow continues to
  target the same API
- **deploy.yml** — the GitHub Actions workflow pushes images and triggers
  deploys via Coolify API by app UUID; the new app UUIDs are written
  back to `coolify.yaml` by `provision.sh` in Step 5, but the deploy.yml
  embedded UUIDs are stale and must be regenerated:

  ```bash
  bash ~/.claude/skills/setup-coolify/scripts/generate-workflow.sh ./coolify.yaml
  ```

  Re-commit the regenerated `.github/workflows/deploy.yml` to update the
  pipeline.

## Rollback

If the migration fails or the new VPS is unhealthy, you can roll back by:

1. Re-creating the original apps on the localhost server (delete
   `deploy_server:` from `coolify.yaml`, clear `coolify_app_ids`, re-run
   `/setup-coolify`)
2. Restoring any backed-up volume contents on the localhost server
3. Updating DNS back to the Coolify host IP

There is no "snapshot and restore" — rollback is symmetric with the
forward migration.
