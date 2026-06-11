# coolify.yaml & coolify.json Schema Reference

Canonical schema for the two config files consumed by the setup-coolify skill.
`coolify.yaml` is per-repo and committed; `~/.claude/coolify.json` is machine-local
and contains credentials.

---

## coolify.yaml — Per-Repo Manifest

`coolify.yaml` lives at the root of each repo you deploy. It contains no secret values —
secrets live in Doppler. Commit this file. The `server:` alias selects which Coolify
instance and Doppler account to use; all other config is repo-local.

### Required Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `project` | string | Coolify project name (also used as Coolify-side project name). Conventionally the same as the repo name without the org prefix. | `skillmap` |
| `server` | string | Alias matching a key in `~/.claude/coolify.json` `servers`. Determines Coolify URL and Doppler account routing. | `vultr-stream` |
| `doppler_project` | string | Doppler project slug. Conventionally the same as `project` unless multiple repos share one Doppler project. | `skillmap` |
| `registry.image` | string | GHCR image path (no tag). The CI workflow appends the git SHA tag at build time — never include it here. Format: `ghcr.io/<org>/<repo>`. | `ghcr.io/my-org/my-app` |
| `environments.staging.domain` | string | FQDN for staging (no protocol, no trailing slash). | `skillmap-staging.cicd.streamlinity.com` |
| `environments.staging.doppler_environment` | string | Doppler config name for staging. Doppler creates `stg` by default — only change if you renamed it. | `stg` |
| `environments.production.domain` | string | FQDN for production (no protocol, no trailing slash). | `skillmap.cicd.streamlinity.com` |
| `environments.production.doppler_environment` | string | Doppler config name for production. Doppler creates `prd` by default — only change if you renamed it. | `prd` |
| `env_vars` | list of strings | Secret keys your app reads at runtime. All are injected at container start from Doppler — NOT baked into the image. Keys must exist in every environment's Doppler config. | `[DATABASE_URL, ANTHROPIC_API_KEY]` |

**Additional environments:** `environments:` is a map — `staging` and `production` are
required (the CI pipeline promotes staging → production), but you may add extra entries
(e.g. `qa`, `preview`) with the same `domain` + `doppler_environment` fields. Extra
environments are provisioned identically (Coolify app, Docker volume, Doppler service
token, DNS record) but do not participate in the generated CI pipeline — deploy them
manually via the Coolify UI or API.

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `registry.retention_tags` | int | `5` | Number of GHCR image tags to retain. Older tags are deleted by the CI workflow after each push. |
| `build.context` | string | `.` | Docker build context path relative to repo root. Use `.` for repos with the app at root (the common case). Set to `./skillmap` or similar only for monorepos / nested-app layouts like ai-upskilling. |
| `build.dockerfile` | string | `./Dockerfile` | Path to the Dockerfile, relative to repo root. For nested apps (e.g. `build.context: ./skillmap`), set this to `./skillmap/Dockerfile`. |
| `coolify_app_ids.staging` | string \| null | `~` | Coolify application UUID for staging. Written by `provision.sh` after the first successful run. Do not edit manually. |
| `coolify_app_ids.production` | string \| null | `~` | Coolify application UUID for production. Written by `provision.sh` after the first successful run. Do not edit manually. |
| `deploy_server` | string | _empty_ | Optional. Name of a Coolify-registered server to deploy apps on. When absent, apps deploy on the Coolify host (server_name from coolify.json, defaulting to `localhost`). Set this when staging/production should run on a separately-registered VPS rather than the Coolify host. Example: `my-app-vps`. |
| `port` | int | `3000` | TCP port your container exposes. `provision.sh` uses this for Coolify's health-check port binding. Set this when your app listens on any port other than 3000. | `8080` |
| `health_check_path` | string | `/api/health` | HTTP path polled by Coolify's health check and by the CI smoke test. Change this if your app exposes health at a different URL (e.g. `/healthz`, `/health`, `/`). | `/healthz` |

### Optional DNS block

Automates A record creation for staging and production domains, eliminating the manual DNS step before Coolify can issue Let's Encrypt certificates. When `provider: none` (or the block is absent), A records must be created manually.

| Field | Type | Default | Description | Example |
|-------|------|---------|-------------|---------|
| `dns.provider` | string | `none` | DNS provider. `cloudflare` enables automated provisioning; `none` skips DNS entirely. | `cloudflare` |
| `dns.zone_name` | string | — | Root DNS zone. Must be a suffix of both `environments.staging.domain` and `environments.production.domain`. | `example.com` |
| `dns.credential_source` | string | `doppler` | Where the API token is stored. `doppler` — read from the Doppler staging config at provision time. `coolify_json` — read from `~/.claude/coolify.json` servers.<alias>.<credential_key>. | `doppler` |
| `dns.credential_key` | string | — | Name of the Doppler secret (e.g. `CLOUDFLARE_API_TOKEN`) or `coolify.json` server field (e.g. `cloudflare_api_token`) that holds the provider API token. | `CLOUDFLARE_API_TOKEN` |

**Example dns block (Cloudflare, token in Doppler):**

```yaml
dns:
  provider: cloudflare
  zone_name: example.com
  credential_source: doppler
  credential_key: CLOUDFLARE_API_TOKEN
```

**To skip DNS automation:**

```yaml
dns:
  provider: none
  zone_name: ""
  credential_source: doppler
  credential_key: ""
```

Or simply omit the `dns:` block entirely.

## DNS Providers

### Cloudflare

Cloudflare is the only supported provider in this release. The `lib-dns-api.sh` library includes a provider dispatch shim (`dns_upsert_a_record`, `dns_delete_record`) that routes calls by `$DNS_PROVIDER` — adding a new provider requires only implementing the corresponding `dns_<provider>_*` functions and a new case branch.

**Token requirements:** Create a Cloudflare API token at `https://dash.cloudflare.com/profile/api-tokens` with **Zone: DNS: Edit** permission scoped to the target zone only. User-level "Global API Key" is not recommended.

**Storing the token in Doppler (recommended):**

```bash
doppler secrets set CLOUDFLARE_API_TOKEN --project <your-project> --config stg
```

The token is shared across environments (DNS credentials are zone-level, not env-level), so storing it once in the staging config is sufficient. `provision.sh` and `validate.sh` read from the staging config by default.

**Storing the token in coolify.json (alternative):**

Add a `cloudflare_api_token` (or any field name matching `dns.credential_key`) to your server entry:

```json
{
  "servers": {
    "vultr-stream": {
      "url": "...",
      "api_key": "...",
      "doppler_account": "...",
      "ssh_host": "...",
      "cloudflare_api_token": "cf_..."
    }
  }
}
```

Then set `dns.credential_source: coolify_json` and `dns.credential_key: cloudflare_api_token` in `coolify.yaml`.

**Token location (deprecation notice):** the token must live in the server entry
matching the `server:` alias in `coolify.yaml` (`servers.<alias>.<credential_key>`).
Two legacy lookup fallbacks — scanning all server entries, and a top-level key —
still work but print a deprecation `WARN:` and will be removed: in a multi-server
`coolify.json` they can silently resolve another org's token.

### Reserved (Not Yet Active)

The `# build_time: true` trailing-comment annotation on `env_vars` entries is reserved
for a future per-environment build mode where staging and production need different
baked-in values. Under the current same-image promotion model all `env_vars` — including
`NEXT_PUBLIC_*` keys — are injected at container start via Doppler. The annotation is
intentionally absent from active manifests; `provision.sh` and `generate-workflow.sh`
currently parse but ignore it.

Do not add `# build_time: true` to current manifests. The field name is locked for future
use; it will be a breaking change when activated.

---

## coolify.json — Machine-Local Credentials

Path: `~/.claude/coolify.json`. **Never commit this file.** Set permissions immediately
after creation:

```bash
chmod 0600 ~/.claude/coolify.json
```

Use `/setup-coolify init_cicd` to populate this file interactively, or write it manually
using the schema below.

> **Note:** JSON has no comment syntax. This table IS the annotation — refer to it when
> filling out the file manually.

### Required Fields per Server Entry

| Field | Where to get the value | Example |
|-------|------------------------|---------|
| `url` | Coolify dashboard URL — the root domain your Coolify instance runs on, HTTPS, no trailing slash. | `https://coolify.cicd.streamlinity.com` |
| `api_key` | Coolify → Settings → Keys & Tokens → Generate API Token. Scoped to your instance. | `xOIN...` (opaque string) |
| `doppler_account` | Your Doppler account slug — visible in the Doppler dashboard URL (`dashboard.doppler.com/workplace/<slug>`) or run `doppler configure get account`. | `streamlinity` |
| `ssh_host` | SSH alias from `~/.ssh/config` that reaches the Coolify server as root. Used by `provision.sh` to create Docker volumes on first deploy. Must match a `Host` entry in `~/.ssh/config`. | `v_cicd_stream` |

> **Important:** `ssh_host` is REQUIRED as of this skill release. Earlier Phase 7
> implementations defaulted to `v_cicd_stream` when absent — that fallback has been
> removed. Scripts will fail loudly if the field is missing. Run `/setup-coolify init_cicd`
> to populate this file interactively.

### Optional Fields per Server Entry

| Field | Default | Description |
|-------|---------|-------------|
| `doppler_token` | — | Personal or service token for the Doppler workspace associated with this server. When set, `validate.sh` and `provision.sh` export it as `DOPPLER_TOKEN` before every Doppler CLI call, scoping all operations to the correct workspace. **Strongly recommended for multi-workspace setups** (e.g. one server per org). Without it, the Doppler CLI falls back to ambient interactive auth, which may target the wrong workspace silently. Obtain from Doppler → Settings → Service Tokens, or use a personal token from your profile. |
| `server_name` | `"localhost"` | Coolify-side name of the managed Docker host node. The Coolify UI lets you rename the node from the default `"localhost"` (Settings → Servers). `provision.sh` uses this value to look up the server UUID via `GET /servers`. Set this only if your Coolify instance has a custom server name; otherwise omit it and the default applies. |
| `vps_ip` | — | Public IPv4 address of the Coolify VPS. When set, `provision.sh` uses this value directly instead of resolving it via SSH + `ifconfig.me` on every run. Optional but recommended to avoid an SSH round-trip on re-runs. Example: `"149.248.4.46"`. |
| `cloudflare_api_token` | — | Cloudflare User API Token with **Zone: DNS: Edit** permission scoped to the target zone. Only required when `dns.credential_source: coolify_json` in `coolify.yaml`. Alternatively, store the token in Doppler and set `credential_source: doppler`. |
| `dns_default` | — | Object read by `test/e2e.sh` to inject a `dns:` block into E2E test runs. When present, every test run creates and deletes real DNS records, exercising the full DNS code path automatically. Structure mirrors the `dns:` block in `coolify.yaml` — see the **Optional DNS block** section above. Example below. |
| `deploy_ssh_host` | — | Optional. SSH alias from `~/.ssh/config` for the deployment VPS. Used by `provision.sh` to create Docker volumes on the deployment VPS (when `deploy_server` is set in `coolify.yaml`). Falls back to `ssh_host` when absent — the Coolify host, which is correct for the localhost deployment case. Set this only when your deployment VPS is separate from your Coolify host. Example: `my-app-vps`. |
| `deploy_vps_ip` | — | Optional. Public IPv4 address of the deployment VPS. Used by `provision.sh` to set DNS A records pointing at the deployment server (not the Coolify host). Resolution order when set in coolify.yaml: `deploy_vps_ip` (this field) → `GET /servers/{uuid}.ip` (Coolify API, skipped when value is `host.docker.internal`) → SSH `ifconfig.me` on `deploy_ssh_host`. Set this to skip the Coolify-API and SSH round-trips. Example: `"203.0.113.42"`. |

> **Keeping server entries up to date:** As the skill evolves, new optional fields are added. `/setup-coolify validate` prints `WARN:` lines for any missing optional fields in the active server entry, with instructions to re-run `/setup-coolify init_cicd` to fill them. Re-running `init_cicd` for an existing alias skips fields that already pass validation and only prompts for missing ones.

---

## Complete Annotated Example

### coolify.yaml — annotated

Lines are annotated with one of three labels:

- `# CHANGE THIS` — values the new repo owner must set
- `# leave as-is` — sane defaults; only change for advanced use
- `# auto-filled by /setup-coolify` — written by `provision.sh`; do not edit

```yaml
# coolify.yaml — per-repo deploy manifest. SAFE TO COMMIT (no secrets).
# Full schema: docs/schema.md

project: myapp           # CHANGE THIS: short slug, lowercase. Becomes the Coolify project name.
server: vultr-stream     # CHANGE THIS: must match a key in ~/.claude/coolify.json servers.
doppler_project: myapp   # CHANGE THIS (or leave same as project): Doppler project slug.

registry:
  # CHANGE THIS: GHCR image path — org/repo only, NO tag.
  # init.sh auto-suggests this from your git remote.
  # The CI workflow appends the git SHA tag; never include it here.
  image: ghcr.io/your-org/your-repo
  retention_tags: 5      # leave as-is: number of GHCR tags to keep

build:
  # leave as-is if Dockerfile is at repo root (default for most projects).
  # CHANGE context/dockerfile only for monorepos (e.g. context: ./myapp).
  context: .
  dockerfile: ./Dockerfile

environments:
  staging:
    domain: myapp-staging.example.com   # CHANGE THIS: staging FQDN, no protocol
    doppler_environment: stg             # leave as-is: Doppler default config name for staging
  production:
    domain: myapp.example.com            # CHANGE THIS: production FQDN, no protocol
    doppler_environment: prd             # leave as-is: Doppler default config name for production

# CHANGE THIS: list every env var your app reads.
# All are injected at container start from Doppler — NOT baked into the image.
# Keys must exist in both the stg and prd Doppler configs.
env_vars:
  - DATABASE_URL
  - ANTHROPIC_API_KEY
  - STRIPE_SECRET_KEY

# auto-filled by /setup-coolify — DO NOT edit. ~ = not yet provisioned.
coolify_app_ids:
  staging: ~
  production: ~
```

### coolify.json — annotated

JSON has no comment syntax. Use the annotation table below when filling in values, then
write the JSON block with the actual values substituted.

| Field | What to put here |
|-------|-----------------|
| `url` | Your Coolify dashboard root URL (HTTPS, no trailing slash) |
| `api_key` | Coolify → Settings → Keys & Tokens → Generate API Token |
| `doppler_account` | Doppler account slug — `doppler configure get account` |
| `ssh_host` | SSH alias from `~/.ssh/config` that reaches the Coolify server as root |

The example below shows two server entries. Multiple entries let you deploy different
projects to different Coolify instances from the same machine. The `server:` field in
each `coolify.yaml` selects which entry to use.

```json
{
  "servers": {
    "vultr-stream": {
      "url": "https://coolify.cicd.streamlinity.com",
      "api_key": "REDACTED",
      "doppler_account": "streamlinity",
      "ssh_host": "v_cicd_stream",
      "vps_ip": "149.248.4.46",
      "cloudflare_api_token": "cfut_...",
      "dns_default": {
        "provider": "cloudflare",
        "zone_name": "streamlinity.com",
        "credential_source": "coolify_json",
        "credential_key": "cloudflare_api_token"
      }
    },
    "hetzner-strategem": {
      "url": "https://coolify.cicd.strategem.ai",
      "api_key": "REDACTED",
      "doppler_account": "StrategemAI",
      "doppler_token": "dp.pt.REDACTED",
      "ssh_host": "hetzner-strategem",
      "cloudflare_api_token": "cfut_REDACTED",
      "dns_default": {
        "provider": "cloudflare",
        "zone_name": "strategem.ai",
        "credential_source": "coolify_json",
        "credential_key": "cloudflare_api_token"
      }
    }
  }
}
```

---

## Field Lifecycle

Knowing who writes each field prevents accidental overwrites.

### User-written fields (in `coolify.yaml`)

Set these yourself when onboarding a new repo:

- `project`
- `server`
- `doppler_project`
- `registry.image`
- `registry.retention_tags` (optional; default 5 is usually correct)
- `environments.staging.domain`
- `environments.staging.doppler_environment`
- `environments.production.domain`
- `environments.production.doppler_environment`
- `env_vars` (list)
- `build.context` (optional; default `.`)
- `build.dockerfile` (optional; default `./Dockerfile`)
- `dns.provider` (optional; default `none`)
- `dns.zone_name` (optional; required when `dns.provider` is not `none`)
- `dns.credential_source` (optional; default `doppler`)
- `dns.credential_key` (optional; required when `dns.provider` is not `none`)
- `deploy_server` (optional; default empty — apps deploy on the Coolify host)

### Skill-written fields (in `coolify.yaml`)

These are set automatically by `provision.sh` after the first successful run:

- `coolify_app_ids.staging` — Coolify application UUID, consumed by `generate-workflow.sh` to embed in `deploy.yml`
- `coolify_app_ids.production` — Coolify application UUID, consumed by `generate-workflow.sh` to embed in `deploy.yml`

Provisioning never reads these back — every `provision.sh` run re-resolves apps by
name, so the values exist purely as workflow-generation input.

Do not edit these manually. If you delete or reprovision an app, `provision.sh` will
overwrite them on the next run.

### User-written fields (in `coolify.json`)

All fields in `~/.claude/coolify.json` are user-written. Use `/setup-coolify init_cicd` to
populate interactively, or write the file manually.

**Permissions:** `chmod 0600 ~/.claude/coolify.json` (file contains API keys).

---

## Validation

`validate.sh` runs a dry-run pre-flight check before any Coolify API calls. It enforces:

### coolify.yaml checks

- All required fields present and non-empty (`project`, `server`, `doppler_project`,
  `registry.image`, `environments.staging.domain`, `environments.staging.doppler_environment`,
  `environments.production.domain`, `environments.production.doppler_environment`, `env_vars`)
- `env_vars` is a non-empty list
- If `dns.provider` is not `none`: `dns.zone_name` is non-empty; `dns.zone_name` is a suffix of both staging and production domains; `dns.credential_key` is non-empty; the credential named by `dns.credential_key` is present in the declared `dns.credential_source` (Doppler staging config or `coolify.json`)

### coolify.json checks

- `servers.<alias>` entry exists for the `server` value referenced in `coolify.yaml`
- Server entry contains all four required fields: `url`, `api_key`, `doppler_account`,
  `ssh_host`
- `ssh_host` value matches a `Host` entry in `~/.ssh/config`

### Live checks

- Coolify API: `GET /projects` returns HTTP 200 (confirms URL and API key are valid)
- Doppler: every `env_vars` key is present in both staging and production configs with
  non-placeholder values (not empty string, not `CHANGE_ME`)

Run validation before provisioning:

```bash
bash ~/.claude/skills/setup-coolify/scripts/validate.sh ./coolify.yaml
```

Exit code 0 = all checks passed. Non-zero = at least one check failed (error message
printed to stderr with the failing field/key name).

---

## Backward Compatibility

### `build.context` / `build.dockerfile` (added in Phase 8)

These fields are optional with safe defaults (`.` and `./Dockerfile`). Existing
`coolify.yaml` files that omit the `build:` block continue to work — scripts treat
absence as the defaults. Only set these for repos where the app is not at root.

### `ssh_host` (added in Phase 8)

Required in `~/.claude/coolify.json` server entries as of this skill release. Phase 7
implementations defaulted to `v_cicd_stream` when absent — this fallback has been
removed. Update your `~/.claude/coolify.json` to add `"ssh_host": "<alias>"` to each
server entry. The `/setup-coolify init_cicd` interactive flow now prompts for this value.

### `server_name` (added in Phase 1 bug fixes)

Optional `server_name` field in `~/.claude/coolify.json` server entries. Defaults to `"localhost"` —
the conventional name of the managed Docker host on a single-node Coolify install.
Existing `coolify.json` files that omit `server_name` continue to work unchanged: `provision.sh`
falls back to `"localhost"` when the field is absent.

Set `server_name` only if you have renamed your Coolify server node in the Coolify UI (Settings →
Servers) to something other than `localhost`. Without this fix, `provision.sh` failed
with `ERROR: server 'localhost' not found in Coolify` on any instance with a custom
server name.

### `coolify_app_ids` (carried from Phase 7)

These cache fields are optional in the schema; `provision.sh` writes them on first run
and reads them to skip re-provisioning on subsequent runs. Files created before Phase 7
that lack this block are treated as if both values are `~` (null).

### Multi-server deployment (Phase 4)

Three new optional fields:

- `deploy_server` in `coolify.yaml` — defaults to empty (deploys on the Coolify host)
- `deploy_ssh_host` in `coolify.json` server entries — defaults to `ssh_host` value
- `deploy_vps_ip` in `coolify.json` server entries — defaults via Coolify API + SSH fallback

Existing `coolify.yaml` files that omit `deploy_server:` continue to work
unchanged. `provision.sh` resolves the deploy target via this fallback
chain: `coolify.yaml deploy_server` → `coolify.json servers.<alias>.server_name`
→ `"localhost"`. For SSH operations: `deploy_ssh_host` → `ssh_host`. For DNS
A records: `deploy_vps_ip` → Coolify `GET /servers/{uuid}.ip` (skipping
`host.docker.internal`) → `vps_ip` (only when `deploy_server` is unset) →
SSH + `ifconfig.me`.

See [docs/multi-server-migration.md](./multi-server-migration.md) for
converting an existing localhost-deployed app to a separately-registered
server. Coolify has no API to move existing apps between servers — the
migration requires deleting and re-provisioning.
