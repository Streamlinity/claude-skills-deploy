# Coolify + Doppler API Reference

> Replace `<your-coolify-domain>` with your Coolify instance root URL (e.g. `coolify.example.com`), `<your-doppler-account>` with your Doppler account slug, and `<your-ssh-host>` with the SSH alias for your Coolify VPS (from `~/.ssh/config`) throughout this document. The examples use placeholder values; you must substitute your own.

Source: `.planning/phases/07-coolify-doppler-deploy-infrastructure/07-RESEARCH.md`

Base URL: `https://<your-coolify-domain>/api/v1` (after SSL enabled + allowed_ips cleared)
Auth: `Authorization: Bearer <api_key>`

---

## Coolify API

### Projects

#### Create project

```bash
POST /api/v1/projects

curl -s -X POST "$COOLIFY_URL/api/v1/projects" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"skillmap","description":"SkillMap AI app"}'
# Response: {"uuid":"<project-uuid>"}
```

#### List projects

```bash
GET /api/v1/projects

curl -s "$COOLIFY_URL/api/v1/projects" \
  -H "Authorization: Bearer $COOLIFY_API_KEY"
# Response: [{"id":1,"uuid":"...","name":"skillmap","description":"..."}]
```

---

### Applications

#### List all applications

```bash
GET /api/v1/applications

curl -s "$COOLIFY_URL/api/v1/applications" \
  -H "Authorization: Bearer $COOLIFY_API_KEY"
# Response: [{uuid, name, status, git_branch, fqdn, build_pack, ...}]
```

#### Create application (registry-based — GHCR same-image promotion)

```bash
POST /api/v1/applications/private-github-app

curl -s -X POST "$COOLIFY_URL/api/v1/applications/private-github-app" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "project_uuid": "<project-uuid>",
    "server_uuid": "<server-uuid>",
    "environment_name": "staging",
    "github_app_uuid": "<github-app-uuid>",
    "name": "skillmap-staging",
    "git_repository": "my-org/my-app",
    "git_branch": "main",
    "build_pack": "dockerfile",
    "source_type": "registry",
    "docker_registry_image_name": "ghcr.io/my-org/my-app",
    "ports_exposes": "3000",
    "domains": "https://skillmap-staging.<your-app-domain>",
    "is_auto_deploy_enabled": false,
    "instant_deploy": false
  }'
# Response: {"uuid":"<new-app-uuid>"}
```

Note: `source_type: "registry"` tells Coolify to pull from a container registry
(GHCR) rather than building from source. This is required for same-image promotion.

#### Update application fields

```bash
PATCH /api/v1/applications/{uuid}

curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$APP_UUID" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "fqdn": "https://skillmap-staging.<your-app-domain>",
    "is_auto_deploy_enabled": false,
    "custom_docker_run_options": "--mount source=<app-uuid>-doppler-cache,target=/etc/doppler-cache"
  }'
```

#### Bulk set env vars

```bash
PATCH /api/v1/applications/{uuid}/envs/bulk

curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$APP_UUID/envs/bulk" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "data": [
      {"key": "DOPPLER_TOKEN", "value": "dp.st.staging.xxx", "is_preview": false},
      {"key": "DATABASE_URL", "value": "postgres://...", "is_preview": false}
    ]
  }'
```

NOTE: The bulk-envs `is_buildtime` field is **response-only** in the current API schema —
it is NOT accepted in the request body for bulk updates. Under the same-image promotion model
used by this skill, all env_vars are treated as runtime vars regardless of any `# build_time: true`
annotation in `coolify.yaml`. The `build_time: true` annotation and `is_buildtime` field are
**reserved for a future per-env build mode** and are NOT currently used by this skill.

Individual env var create (`POST /applications/{uuid}/envs`) may accept `is_buildtime` — verify
at implementation time if per-env build mode is ever implemented.

#### Set individual env var

```bash
POST /api/v1/applications/{uuid}/envs

curl -s -X POST "$COOLIFY_URL/api/v1/applications/$APP_UUID/envs" \
  -H "Authorization: Bearer $COOLIFY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key":"DOPPLER_TOKEN","value":"dp.st.staging.xxx","is_preview":false}'
```

#### Trigger deploy

```bash
GET /api/v1/deploy?uuid={uuid}&force=false

curl -s "$COOLIFY_URL/api/v1/deploy?uuid=$APP_UUID&force=false" \
  -H "Authorization: Bearer $COOLIFY_API_KEY"
# Response: {"deployments":[{"message":"...","resource_uuid":"...","deployment_uuid":"..."}]}
```

---

### Servers

#### List servers

```bash
GET /api/v1/servers

curl -s "$COOLIFY_URL/api/v1/servers" \
  -H "Authorization: Bearer $COOLIFY_API_KEY"
# Response: [{"uuid":"...","name":"localhost","ip":"host.docker.internal",...}]
```

---

### Sources (GitHub Apps)

#### List sources

```bash
GET /api/v1/sources

curl -s "$COOLIFY_URL/api/v1/sources" \
  -H "Authorization: Bearer $COOLIFY_API_KEY"
# Response: [{uuid, name, type, ...}]
# Filter for type == "github_app" to get the GitHub App UUID
```

---

## Doppler API

Base URL: `https://api.doppler.com/v3`
Auth: `Authorization: Bearer <doppler_personal_token>` (for setup steps)
Runtime auth: `DOPPLER_TOKEN` service token (scoped per project/config)

### Create service token

```bash
POST /v3/configs/config/tokens

curl -s -X POST "https://api.doppler.com/v3/configs/config/tokens" \
  -H "Authorization: Bearer $DOPPLER_PERSONAL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"project":"skillmap","config":"staging","name":"coolify-staging","access":"read"}'
# Response: {"token":{"key":"dp.st.staging.xxx",...}}

# CLI (simpler):
doppler --account <your-doppler-account> configs tokens create "coolify-staging" \
  -p skillmap -c staging --plain
```

### Download all secrets

```bash
GET /v3/configs/config/secrets/download?project=<p>&config=<c>&format=json

curl -s "https://api.doppler.com/v3/configs/config/secrets/download?project=skillmap&config=staging&format=json" \
  -H "Authorization: Bearer $DOPPLER_PERSONAL_TOKEN"
# Response: {"KEY1":"value1","KEY2":"value2",...}

# CLI equivalent:
doppler --account <your-doppler-account> secrets download \
  --project skillmap --config staging --no-file --format docker
```

### Check single key exists

```bash
GET /v3/configs/config/secret?project=<p>&config=<c>&name=<key>

curl -s "https://api.doppler.com/v3/configs/config/secret?project=skillmap&config=staging&name=DATABASE_URL" \
  -H "Authorization: Bearer $DOPPLER_PERSONAL_TOKEN"
# Response: {"secret":{"name":"DATABASE_URL","value":{"raw":"..."}}}

# CLI (used by validate.sh):
doppler --account <your-doppler-account> secrets get \
  --project skillmap --config staging DATABASE_URL --plain
# Exit code 0 = exists, non-zero = missing
```

---

## Notes

- Coolify volume API does NOT exist (GitHub issue #4084, closed without implementation).
  Use SSH to create Docker named volumes: `ssh <your-ssh-host> "docker volume create <name>"`
  then set `custom_docker_run_options` via PATCH.
- Coolify `allowed_ips` must be cleared (set to `*`) before API calls succeed from non-whitelisted IPs.
- Coolify API tokens are stored as hashes (Laravel Sanctum) — original value unrecoverable.
  Generate new token via Coolify UI: Settings → Keys & Tokens → API Tokens.
