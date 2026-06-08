# Troubleshooting

Issues encountered during real-world setup, with exact symptoms and fixes.

---

## SSH

### `WARNING: UNPROTECTED PRIVATE KEY FILE! bad permissions`

**Symptom:** `ssh -i ~/.ssh/<key> ...` fails with `bad permissions` and ignores the key.

**Cause:** Key file has permissions wider than `0600` — common when copying keys from another machine (WSL, Windows, another Linux user).

**Fix:**
```bash
chmod 0600 ~/.ssh/<keyname>
```

---

## Coolify Installation

### Step 1/9 hangs for more than 10 minutes

**Symptom:** The Coolify install script prints `1/9 Installing required packages` and never advances. `ps aux | grep needrestart` shows a `needrestart` process.

**Cause:** Ubuntu's `needrestart` tool prompts interactively for which services to restart after package installation. The install script runs non-interactively, so the prompt is never answered and the process blocks indefinitely.

**Fix:** Before re-running the install script, configure needrestart to restart services automatically without prompting:
```bash
echo "\$nrconf{restart} = 'a';" | tee /etc/needrestart/conf.d/autorestart.conf
```

Then re-run the Coolify install script. It is idempotent — already-installed packages are skipped.

---

## DNS

### DNS records not resolving after adding them to Cloudflare

**Symptom:** `dig +short <domain>` returns nothing even after adding A records in Cloudflare.

**Cause:** The domain has multiple Cloudflare zones (e.g., from different accounts or import attempts). Records were added to a zone whose nameservers are not active in the registrar.

**Diagnosis:**
```bash
dig +short NS <domain>   # shows which nameservers are authoritative
```

If the authoritative nameservers don't match the Cloudflare zone where you added the records, the records won't resolve.

**Fix:** In your registrar (e.g., GoDaddy), update the nameservers to match the zone that contains your records. Cloudflare shows the assigned nameservers under **DNS → Nameservers** for each zone.

### Records added to own Cloudflare zone instead of a collaborator's zone

**Symptom:** You add A records in Cloudflare and they appear to save correctly, but the main domain or subdomains stop working. Other people's changes to DNS seem to take effect but yours don't.

**Cause:** Multiple Cloudflare zones can exist for the same domain root (e.g., if you and a collaborator each have `strategem.ai` in separate Cloudflare accounts). Only the zone whose nameservers are active at the registrar will have its records served. If your registrar (e.g., GoDaddy) points to your collaborator's nameservers (`fred.ns.cloudflare.com` / `lia.ns.cloudflare.com`), records you add to your own zone (`myname.ns.cloudflare.com`) are silently ignored.

**Diagnosis:**
```bash
dig +short NS <your-domain>     # shows which nameservers are active
# Compare against what Cloudflare shows for each zone under DNS → Nameservers
```

**Fix:**
1. Determine which zone is authoritative (matches registrar nameservers).
2. Add all records to **that** zone, not your own.
3. If you changed registrar nameservers to your zone by mistake: revert to the correct nameservers in the registrar immediately. DNS TTL on NS records is typically 24–48 hours but Cloudflare zones re-propagate quickly once the registrar is corrected.

**Records needed for a typical Coolify deployment on a shared domain:**
```
coolify.<cicd-subdomain>   A   <vps-ip>   # Coolify dashboard
*.<cicd-subdomain>         A   <vps-ip>   # wildcard for all CI/CD app subdomains
<app>.<your-domain>        A   <vps-ip>   # production app (one per app)
```

---

## Docker

### `permission denied while trying to connect to the Docker API`

**Symptom:** `docker` commands fail immediately after `sudo usermod -aG docker $USER`.

**Cause:** The docker group membership is only applied to new login sessions. The current shell was opened before the group was added.

**Fix:** Either log out and log back in, or activate the group in the current shell:
```bash
newgrp docker
```

Run `docker info` to confirm the group is active before running the E2E test or any docker command.

---

## GitHub Container Registry (GHCR)

### `invalid tag "ghcr.io/MyOrg/image:latest"` in CI

**Symptom:** A GitHub Actions workflow fails with `invalid tag` on the Docker build step.

**Cause:** Docker image names must be fully lowercase. GitHub org names are case-sensitive in the UI but GHCR requires lowercase.

**Fix:** Convert the org name to lowercase before using it as an image tag. In GitHub Actions:
```yaml
- name: Set lowercase owner
  run: echo "GHCR_OWNER=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> $GITHUB_ENV

- name: Build and push
  uses: docker/build-push-action@v6
  with:
    tags: ghcr.io/${{ env.GHCR_OWNER }}/my-image:latest
```

### `Make package public` step silently succeeds but package stays private

**Symptom:** The workflow step prints `✓ package visibility set to public` but the GHCR package remains private. `docker pull` returns `unauthorized`.

**Cause:** The GitHub API endpoint `/user/packages/container/<name>` applies to packages owned by the authenticated user. For packages owned by an **org**, the correct endpoint is `/orgs/<org>/packages/container/<name>`.

**Fix:** Use the org endpoint in the workflow:
```bash
gh api --method PATCH "/orgs/${GHCR_OWNER}/packages/container/my-image" -f visibility=public
```

### Coolify VPS cannot pull the image — `unauthorized` or `pull access denied`

**Symptom:** Coolify deploy fails with `Error: pulling image ... unauthorized: unauthenticated` or `pull access denied for ghcr.io/...`. The image was just pushed successfully by GitHub Actions.

**Cause:** When GitHub Actions pushes a new Docker image to GHCR for a GitHub **org**, the package is **private by default**. The Coolify VPS cannot pull private GHCR packages without a configured credential helper.

**Fix:** Make the GHCR package public. In GitHub:
1. Go to `https://github.com/orgs/<org>/packages/container/<package-name>/settings`
2. Scroll to **Danger Zone → Change package visibility**
3. Set to **Public** and confirm.

This only needs to be done once per package (not per tag). Future pushes to the same package name inherit the public visibility.

> **Alternative:** Configure a GHCR pull secret on your Coolify VPS (Settings → Registries). But making the package public is simpler for non-sensitive images.

---

## GitHub Actions / CI

### Wrong Dockerfile stage built — dev image deployed instead of production

**Symptom:** Container starts but crashes immediately, or the dev reload loop runs but crashes because source isn't mounted as a volume. Logs show errors like `[WatchFiles] watching ...` then file-not-found errors.

**Cause:** `docker/build-push-action` without a `target:` field builds the **last** stage in the Dockerfile. If your Dockerfile ends with a `dev` stage (a common pattern for separating local dev from production), CI silently builds and pushes the wrong image.

**Fix:** Add `target: production` (or whatever your production stage is named) to the build step:

```yaml
- uses: docker/build-push-action@v6
  with:
    context: .
    file: ./Dockerfile
    target: production      # <-- required for multi-stage Dockerfiles
    push: true
    tags: ghcr.io/...
```

### Smoke test fails with TLS error on first deploy to a new domain

**Symptom:** The staging smoke test fails on the very first deploy to a new domain. The `curl` command returns a TLS/certificate error (`SSL certificate problem: unable to get local issuer certificate` or similar), even though the app is running.

**Cause:** Let's Encrypt certificate issuance takes 10–60 seconds after Traefik first picks up the new domain. If the smoke test runs immediately after the deploy is triggered, the cert may not be ready yet.

**Fix:** Add the `-k` flag to `curl` in the smoke test step. This tests app availability without validating the certificate:

```bash
curl -sfSk "https://$STAGING_DOMAIN/health" -o /dev/null
```

This is safe in CI — the certificate validity is enforced by the end user's browser and by production traffic; the smoke test only needs to confirm the app is reachable.

### Node.js 20 deprecation warnings from GitHub Actions

**Symptom:** GitHub Actions workflow shows annotation warnings like `Node.js 20 actions are deprecated` for `actions/checkout@v4`, `docker/build-push-action@v6`, `docker/login-action@v3`, `actions/delete-package-versions@v5`.

**Cause:** GitHub is migrating runners to Node.js 24. Node.js 20 actions will stop working after **September 16, 2026** (forced to Node.js 24 starting June 16, 2026).

**Fix:** Update the actions to their latest versions in `.github/workflows/deploy.yml`. Check each action's releases page for the Node.js 24-compatible version. As of mid-2026, upgrading `@v4` → `@v5` for checkout and `@v6` → `@v7` for build-push should resolve the warnings.

---

## Coolify API

### API calls return 401 despite a valid token in `coolify.json`

**Symptom:** `/setup-coolify validate` or `coolify_curl` returns HTTP 401 even though the API key in `~/.claude/coolify.json` is correct.

**Cause:** Coolify generates API tokens in the format `1|<token-string>`. The `|` character was previously used as a field delimiter when parsing `coolify.json`, causing the key to be truncated to `1`.

**Status:** Fixed in `scripts/lib-coolify-api.sh` — each field is now read with a separate `python3` call, so any character in the API key is safe.

**If you see this on an older install:** Pull the latest version of the skill or manually update `coolify_load_server()` in `scripts/lib-coolify-api.sh` to use per-field reads instead of `|`-delimited output.

### `allowed_ips` — setting to `*` has no effect

**Symptom:** The setup guide says set `allowed_ips` to `*`, but the Coolify UI shows `0.0.0.0`.

**Clarification:** In the Coolify UI, the "allow all" value is `0.0.0.0` (or leave the field empty). Both are equivalent to `*`. Set the field to `0.0.0.0` and save.

### Cloudflare Error 1000 — `DNS points to prohibited IP`

**Symptom:** Browser shows `Error 1000: DNS points to prohibited IP` when visiting the domain. The Cloudflare DNS dashboard shows A records with content values like `172.67.x.x` or `104.21.x.x`.

**Cause:** The A record's content is set to one of Cloudflare's own anycast IPs, and the proxy is also enabled — creating a routing loop. This can happen when DNS records were imported or auto-populated incorrectly.

**Fix:**
1. In Cloudflare DNS, delete all A records for the affected domain that have `172.67.x.x`, `104.21.x.x`, or any other Cloudflare-owned IP as their content.
2. Add a new A record pointing to your actual VPS IP (e.g., `87.99.142.159`).
3. Set **Proxy status** to **DNS only** (grey cloud) — required when the VPS runs its own TLS termination (e.g., Traefik with Let's Encrypt).

```
Name: demo                 Type: A    Content: <vps-ip>    Proxy: DNS only
```

> **Note:** All VPS-hosted subdomains routed through Traefik should use DNS only. If Cloudflare's orange-cloud proxy is enabled, Let's Encrypt HTTP-01 challenges will fail because the challenge request hits Cloudflare's edge, not your VPS.

---

## Coolify Proxy (Traefik)

### Apps deploy successfully but HTTPS URLs time out or return connection errors

**Symptom:** Coolify shows the app as `running:healthy` and the Coolify API confirms the deploy finished, but `curl https://<app-domain>` times out or fails TLS.

**Cause:** Coolify's Traefik proxy (`coolify-proxy` container) is not running. Without it, no traffic reaches the deployed containers and no Let's Encrypt certificates are issued.

**Fix:**
```bash
# On the Coolify VPS:
cd /data/coolify/proxy && docker compose up -d
```

Or in the Coolify UI: **Servers → localhost → Proxy → Start Proxy**.

Verify it's running:
```bash
docker ps | grep coolify-proxy
```

### `Bind for 0.0.0.0:80 failed: port is already allocated` when starting Traefik

**Symptom:** Starting `coolify-proxy` fails because another container owns ports 80 or 443.

**Cause:** A pre-existing service (e.g., a standalone Caddy, nginx, or another reverse proxy) is bound to the public ports. Traefik and any other service cannot both own port 80/443 simultaneously.

**Fix:** Make the pre-existing service internal (remove its port bindings) and route its domains through Traefik instead. The high-level approach:

1. Add `{ auto_https off }` to the service's config (if Caddy) — Traefik handles TLS now.
2. Remove `ports: 80:80` and `443:443` from the service's `docker-compose.yml`.
3. Add the service to the `coolify` Docker network.
4. Add Traefik Docker labels to the service so Traefik routes its hostnames to it.
5. Stop the old container, start `coolify-proxy`, then restart the service with the new config.

Example Traefik labels (replace `example.com` with the actual domain):
```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=coolify
  - traefik.http.routers.myservice-http.entrypoints=http
  - traefik.http.routers.myservice-http.rule=Host(`example.com`)
  - traefik.http.routers.myservice-http.middlewares=redirect-to-https@file
  - traefik.http.routers.myservice-https.entrypoints=https
  - traefik.http.routers.myservice-https.rule=Host(`example.com`)
  - traefik.http.routers.myservice-https.tls.certresolver=letsencrypt
  - traefik.http.services.myservice.loadbalancer.server.port=80
```

The `redirect-to-https@file` middleware is defined in `/data/coolify/proxy/dynamic/coolify.yaml` and is available to all containers on the `coolify` network.

**Always back up config files before making these changes:**
```bash
cp docker-compose.yml docker-compose.yml.bak
cp Caddyfile Caddyfile.bak
```

### HTTPS still fails after fixing DNS — ACME challenge failures are cached

**Symptom:** After correcting a DNS misconfiguration (e.g., wrong IP, Cloudflare proxy in front of the VPS), the domain still gets a certificate error even though `dig +short <domain>` now returns the correct VPS IP. Traefik logs show repeated `Unable to obtain ACME certificate` errors with old timestamps.

**Cause:** Traefik caches failed ACME attempts in `/data/coolify/proxy/acme.json`. After multiple failures, it backs off exponentially (up to several hours) before retrying. Restarting the proxy alone does not clear this backoff — the cached state is reloaded from `acme.json` on startup.

**Fix:** Remove the stale certificate entry for the domain from `acme.json`, then restart the proxy:

```bash
# On the Coolify VPS:
python3 - << 'PY'
import json
path = "/data/coolify/proxy/acme.json"
with open(path) as f:
    d = json.load(f)
before = len(d["letsencrypt"]["Certificates"])
d["letsencrypt"]["Certificates"] = [
    c for c in d["letsencrypt"]["Certificates"]
    if c.get("domain", {}).get("main") != "your-domain.com"
]
print(f"Removed {before - len(d['letsencrypt']['Certificates'])} entry/entries")
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY

cd /data/coolify/proxy && docker compose restart
```

Traefik will request a fresh certificate on restart. Verify success after ~30 seconds:
```bash
docker logs coolify-proxy --since 1m 2>&1 | grep -i "certif\|acme\|ERR"
```

A valid cert should appear in `acme.json` for the domain with an `Issuer` from Let's Encrypt.

### 502 Bad Gateway — container healthy but requests fail

**Symptom:** Coolify shows the app as `running:healthy` and the deploy log shows success, but accessing the app URL returns `502 Bad Gateway`. The container is running and the app responds on its internal port.

**Cause:** Coolify generates Traefik routing labels based on `ports_exposes` in the database. This defaults to `3000`. If your app listens on a different port (e.g., `8000`), Traefik routes traffic to the wrong port and gets connection refused.

**Diagnosis:** On the VPS, inspect the container labels:
```bash
docker inspect <container-id> | grep loadbalancer.server.port
```

**Fix (permanent):** Add `port: <your-port>` to `coolify.yaml`, then re-run `/setup-coolify` to update the Coolify database. The next deploy will generate the correct Traefik labels automatically.

**Fix (immediate, for a running container without redeploying):** Patch the generated docker-compose file on the VPS and recreate the container:
```bash
APP_UUID=<your-app-uuid>
sed -i 's/loadbalancer.server.port=3000/loadbalancer.server.port=8000/g; s/{{upstreams 3000}}/{{upstreams 8000}}/g' \
  /data/coolify/applications/$APP_UUID/docker-compose.yaml
cd /data/coolify/applications/$APP_UUID && docker compose up -d --force-recreate
```

> **Note:** `/data/coolify/applications/` on the host is the same path as `/var/www/html/storage/app/applications/` inside the Coolify container (bind-mounted volume). Either path works for edits.

### Container marked unhealthy immediately after deploy

**Symptom:** Coolify shows the container as `unhealthy` right after deployment. The health check log shows `connection refused` or `404 Not Found` on the health endpoint.

**Cause:** The default health check configuration in `provision.sh` was `port=3000` and `path=/api/health`. Apps using different values (e.g., `port=8000`, `path=/health`) will always fail the check and be restarted in a loop.

**Fix:** Add the correct values to `coolify.yaml`:
```yaml
port: 8000
health_check_path: /health
```

Then re-run `/setup-coolify` — it will PATCH the Coolify app with the correct health check settings. The next deploy will use these values.

**Immediate fix via API (without waiting for a new deploy):**
```bash
APP_UUID=<your-app-uuid>
curl -sfS -X PATCH "http://<coolify-host>:8000/api/v1/applications/$APP_UUID" \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"health_check_port": 8000, "health_check_path": "/health"}'
```

Then trigger a redeploy from the Coolify UI.

### Pre-existing Caddy service returns "Client sent an HTTP request to an HTTPS server"

**Symptom:** After routing a Caddy service through Traefik (removing Caddy's port 80/443 bindings and adding Traefik labels), HTTPS requests to the domain return HTTP 400 with body `Client sent an HTTP request to an HTTPS server.`

**Cause:** Caddy's `auto_https off` global setting disables TLS certificate management, but bare hostnames in site blocks (e.g., `example.com {`) still bind to port **443** by default and still expect TLS. Traefik forwards plain HTTP to that port, causing the mismatch.

**Fix:** Explicitly prefix all site block addresses in `Caddyfile` with `http://` to force Caddy to listen on port 80:

```caddyfile
{
    auto_https off
}

# Before: example.com {
# After:
http://example.com {
    ...
}

http://other.example.com {
    ...
}
```

Then restart the service. Verify with:
```bash
docker exec <caddy-container> netstat -tlnp | grep LISTEN
# Should show :::80, not :::443
```

The Traefik label `traefik.http.services.<name>.loadbalancer.server.port=80` is then correct and no further label changes are needed.
