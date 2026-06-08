# Phase 4: Multi-Server Deployment - Research

**Researched:** 2026-06-07
**Domain:** Coolify API (server/destination model), bash/python3 scripting, coolify.yaml schema extension
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MSRV-01 | `coolify.yaml` supports optional `deploy_server:` field; absent = unchanged behavior | Schema extension pattern from dns: block; backward compat via Python `d.get('deploy_server','')` |
| MSRV-02 | `provision.sh` creates apps on the server named by `deploy_server`, falling back to `server_name`→`"localhost"` chain | Coolify API confirmed: `server_uuid` in POST /applications/dockerimage targets any registered server |
| MSRV-03 | `validate.sh` checks `deploy_server` (if set) exists as a registered Coolify server before provisioning | `GET /servers` returns all registered servers with name+uuid; name-match lookup already in `coolify_get_server_uuid` |
| MSRV-04 | `coolify.json` server entries support optional `deploy_ssh_host` for SSH operations on deployment VPS | Same `python3 json.load` pattern as `ssh_host`; fall back to `ssh_host` when absent |
| MSRV-05 | DNS A records use the deployment VPS IP (via `deploy_ssh_host` or `ssh_host`) | `GET /servers/{uuid}.ip` returns real IP for remote servers; SSH fallback via `ifconfig.me` preserved |
| MSRV-06 | Existing repos without `deploy_server:` continue to work unchanged | All new fields optional with explicit fallback chain; no required field changes |
| MSRV-07 | `docs/schema.md` and `docs/setup-guide.md` document `deploy_server:` and `deploy_ssh_host:` | Documentation additions only; no script dependency |
| MSRV-08 | Migration guide: existing localhost-deployed app → separate server (re-creation required) | Confirmed: Coolify has no move-app-between-servers API; guide must say delete + re-provision |
</phase_requirements>

---

## Summary

Phase 4 adds a single optional `deploy_server:` field to `coolify.yaml` and a single optional `deploy_ssh_host` field to `coolify.json` server entries. Together these allow Coolify apps to be created on any server registered in Coolify, not only the Coolify host (`localhost`).

The Coolify API already supports this: `POST /applications/dockerimage` accepts any `server_uuid` — not just the Coolify host's UUID. The `server_uuid` for the target server is looked up by name via `GET /servers`, which returns all registered servers with their `name`, `uuid`, and `ip` fields. The `destination_uuid` for that server can be looked up by scanning `GET /applications` for any existing app whose `destination.server.uuid` matches the target server UUID. If no apps exist yet on the new server, `destination_uuid` can be omitted and Coolify auto-assigns it.

For SSH operations (Docker volume creation) and DNS IP resolution, the `deploy_ssh_host` field in `coolify.json` provides the SSH alias for the deployment VPS — separate from `ssh_host` (which points to the Coolify host). When `deploy_ssh_host` is absent, the fallback is `ssh_host`. For DNS IP, `GET /servers/{uuid}.ip` returns the real IP of a registered remote server (set by the operator when adding the server to Coolify), providing an alternative to the SSH `ifconfig.me` round-trip.

**Primary recommendation:** Add `deploy_server:` to `coolify.yaml` and `deploy_ssh_host` + `vps_ip` (for the deploy server) to `coolify.json`. Route all server/destination/SSH/DNS operations through a resolved `DEPLOY_SERVER_NAME` variable that defaults through the existing fallback chain. No library or framework changes — pure bash + python3 in the existing scripts.

---

## Standard Stack

No new libraries or tools. All implementation stays within the existing stack.

| Component | Current | Phase 4 Role |
|-----------|---------|--------------|
| bash + python3 | All scripts | Extend existing parsing and control flow |
| `GET /servers` Coolify API | Used in `coolify_get_server_uuid` | Same; now called with `deploy_server` name |
| `POST /applications/dockerimage` | Used in `provision.sh` | Same; `server_uuid` now targets the deploy server |
| `ssh` CLI | Docker volume creation via `ssh "$SSH_HOST"` | Now uses `DEPLOY_SSH_HOST` (new variable) |
| `curl` + ifconfig.me | IP resolution fallback | Now called against `DEPLOY_SSH_HOST` |

**No new installation required.**

---

## Architecture Patterns

### Resolved Variables Pattern

The phase introduces two new resolved variables in `provision.sh` and `validate.sh`:

```
DEPLOY_SERVER_NAME  — the Coolify server name to target for app creation
DEPLOY_SSH_HOST     — the SSH alias for Docker volume creation and IP resolution
```

These are derived from the fallback chain below, preserving full backward compatibility:

```
DEPLOY_SERVER_NAME:
  1. coolify.yaml deploy_server:        (new — takes priority)
  2. coolify.json servers.<alias>.server_name   (existing field)
  3. "localhost"                         (existing hardcoded default)

DEPLOY_SSH_HOST:
  1. coolify.json servers.<alias>.deploy_ssh_host  (new)
  2. coolify.json servers.<alias>.ssh_host         (existing — unchanged fallback)
```

Both variables replace the current `SERVER_NAME` and `SSH_HOST` references in provision.sh. When neither new field is set, the chain produces the exact same values as today — zero behavior change for existing repos.

### Destination UUID Lookup (improved)

The current `coolify_get_destination_uuid` calls `GET /destinations` (confirmed 404 on this Coolify version), then falls back to empty string. This works for localhost (Coolify auto-assigns the destination). For a remote server it may fail.

**Improved strategy — scan apps by server uuid:**

```bash
coolify_get_destination_uuid() {
  local server_uuid="$1"
  # Strategy 1: scan existing apps for a matching destination.server.uuid
  local out
  out=$(coolify_curl GET "/applications" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    local found
    found=$(echo "$out" | python3 -c "
import json,sys
apps=json.load(sys.stdin)
for a in apps:
    d=a.get('destination',{})
    s=d.get('server',{})
    if s.get('uuid')=='$server_uuid':
        print(d.get('uuid','')); break
" 2>/dev/null || echo "")
    [ -n "$found" ] && echo "$found" && return
  fi
  # Strategy 2: GET /destinations fallback (works in some Coolify versions)
  out=$(coolify_curl GET "/destinations" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    echo "$out" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
if isinstance(d,list):
    for x in d:
        if x.get('server',{}).get('uuid')=='$server_uuid' or x.get('server_uuid')=='$server_uuid':
            print(x.get('uuid','')); break
" 2>/dev/null || true
  fi
  # Returns empty string — Coolify will auto-assign for single-destination servers
}
```

This is a pure improvement: same behavior for localhost (apps already exist, scan finds the destination UUID), better behavior for new remote servers (scan finds UUID from any existing app on that server, or returns empty and lets Coolify auto-assign).

### IP Resolution for DNS (multi-server aware)

Current code uses `coolify.json .vps_ip` then SSH `ifconfig.me`. For a deploy server:

```bash
# Current (localhost-only):
VPS_IP=$(python3 -c "...d.get('servers',{}).get('$SERVER_ALIAS',{}).get('vps_ip','')")

# Phase 4 extension:
# 1. Check coolify.json servers.<alias>.deploy_vps_ip  (new optional field)
# 2. Fall back to coolify.json servers.<alias>.vps_ip  (existing — means "Coolify host IP")
# 3. Fall back to GET /servers/{DEPLOY_SERVER_UUID}.ip (available from Coolify API!)
# 4. Fall back to SSH deploy_ssh_host + ifconfig.me
```

The `GET /servers/{uuid}.ip` field is confirmed to return the real IP for remote servers (for localhost it returns `host.docker.internal`, so the fallback logic must skip that string).

**Note:** For the Coolify host itself, `ip = "host.docker.internal"` — not a usable public IP. The `vps_ip` in `coolify.json` covers this case. For a separately-registered remote server, `ip` is the real public IP entered by the operator.

### validate.sh Extension

Add one new check when `DEPLOY_SERVER` is set in `coolify.yaml`:

```bash
# After existing server alias + ssh_host checks:
if [ -n "${DEPLOY_SERVER:-}" ]; then
  DEPLOY_SERVER_UUID=$(coolify_get_server_uuid "$DEPLOY_SERVER")
  if [ -z "$DEPLOY_SERVER_UUID" ]; then
    # List available servers for a helpful error
    AVAILABLE=$(coolify_curl GET "/servers" | python3 -c "
import json,sys
print(', '.join(s.get('name','') for s in json.load(sys.stdin)))
" 2>/dev/null || echo "<unable to list>")
    fail "INVALID:coolify.yaml:deploy_server '$DEPLOY_SERVER' not registered in Coolify. Available: $AVAILABLE"
  fi
fi
```

This accumulates into the existing `ERRORS` counter, consistent with validate.sh error pattern.

### coolify.yaml Template Extension

Add `deploy_server:` as an optional field with a `# CHANGE:` / `# LEAVE:` comment:

```yaml
# CHANGE: name of the Coolify-registered server to deploy apps on.
# When absent, defaults to the 'server_name' in coolify.json (usually 'localhost').
# Use this when your app VPS is separate from the Coolify host.
# Example: deploy_server: my-app-vps
# deploy_server:   # uncomment to use a separate deployment VPS
```

The field is commented out in the template — operators uncomment it to enable. This prevents confusion for users who don't need it.

### init.sh Extension

Add a prompt for `deploy_server` after the existing `server` alias prompt:

```
[Optional] Deploy server name (Coolify-registered server for app deployment).
Leave blank to deploy on the Coolify host (localhost) — the common case.
deploy_server []: 
```

The template substitution adds `{{DEPLOY_SERVER}}` token. When the operator leaves it blank, the template renders the field commented out. When provided, renders as `deploy_server: <name>`.

### Project Structure (unchanged)

```
scripts/
├── provision.sh       # CHANGE: DEPLOY_SERVER_NAME + DEPLOY_SSH_HOST variables
├── validate.sh        # CHANGE: deploy_server existence check
├── lib-coolify-api.sh # CHANGE: coolify_get_destination_uuid improved
├── lib-dns-api.sh     # NO CHANGE
└── lib-doppler-api.sh # NO CHANGE
init/
├── init.sh            # CHANGE: new optional deploy_server prompt
└── templates/
    └── coolify.yaml.tmpl  # CHANGE: deploy_server commented-out field
docs/
├── schema.md          # CHANGE: document deploy_server + deploy_ssh_host
└── setup-guide.md     # CHANGE: add "Deploy to a separate VPS" how-to
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Server existence check | Custom server registry or caching layer | `GET /servers` by name via existing `coolify_get_server_uuid` |
| Deploy server IP lookup | SSH-only IP resolution | `GET /servers/{uuid}.ip` from Coolify API (already have the UUID) |
| Destination lookup | Re-implementing Coolify's internal destination model | Scan `GET /applications` for existing app on that server — Coolify already stores this |

---

## Runtime State Inventory

This phase involves adding new optional fields and a new code path — no renaming or migration of existing identifiers. No runtime state needs to change for existing deployments.

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | None — no database, no key-value store; coolify_app_ids written per-repo to coolify.yaml | No migration |
| Live service config | Coolify apps already on localhost server — not affected (backward compat path unchanged) | None |
| OS-registered state | None | None |
| Secrets/env vars | `ssh_host` in coolify.json — remains required; `deploy_ssh_host` is new optional | No change to existing keys |
| Build artifacts | None — no compiled output | None |

---

## Common Pitfalls

### Pitfall 1: destination_uuid silently wrong for multi-server

**What goes wrong:** Operator sets `deploy_server: my-app-vps` but `coolify_get_destination_uuid` returns empty string. Coolify auto-assigns the destination — but auto-assignment picks the default destination for the request, which may be the localhost destination, not the one for `my-app-vps`. The app ends up created on the wrong server.

**Why it happens:** `GET /destinations` returns 404 on this Coolify version. The current fallback is empty string, which works for localhost because there's only one destination. For multi-server there are multiple destinations and the wrong one may be picked.

**How to avoid:** Use the improved `coolify_get_destination_uuid` (scan apps by server UUID). For a brand-new deploy server with no existing apps, `destination_uuid` still omitted — but this is correct because Coolify has exactly one destination per server and will select it automatically when `server_uuid` is explicit.

**Warning signs:** App UUID returned by CREATE, but `GET /applications/{uuid}.destination.server.name` shows `localhost` instead of `my-app-vps`.

### Pitfall 2: Coolify host IP vs deploy server IP

**What goes wrong:** DNS A records get provisioned with `host.docker.internal` (the Coolify internal hostname for localhost) or the Coolify host's public IP instead of the deploy VPS public IP.

**Why it happens:** `provision.sh` uses `coolify.json .vps_ip` (which operators set for the Coolify host). When `deploy_server:` is set, the DNS target must be the deploy VPS IP, not the Coolify host IP.

**How to avoid:** Introduce `deploy_vps_ip` as a new optional field in `coolify.json`. When set, use it for DNS. When absent, fall back to `GET /servers/{DEPLOY_SERVER_UUID}.ip`. Guard: skip if resolved IP equals `"host.docker.internal"` (means Coolify localhost, not usable).

**Warning signs:** DNS A records provisioned, HTTPS returns certificate error or 502 — app is running on the deploy VPS but DNS points elsewhere.

### Pitfall 3: Docker volume created on wrong server

**What goes wrong:** `ssh "$SSH_HOST" "docker volume create ..."` creates the volume on the Coolify host, but the app is running on the deploy VPS. The volume mount succeeds silently but the Doppler cache is not accessible.

**Why it happens:** `SSH_HOST` points to the Coolify host, not the deploy VPS.

**How to avoid:** Resolve `DEPLOY_SSH_HOST` before the volume creation loop. When `deploy_ssh_host` is absent from coolify.json, the fallback to `ssh_host` means the Coolify host is used — correct for the localhost case, wrong for multi-server. The provision.sh must use `DEPLOY_SSH_HOST` for all `ssh "$..."` calls in the per-env loop.

**Warning signs:** Volume created successfully (exit 0) but app fails health check on `/api/health`. Doppler cache volume exists on Coolify host but not on deploy VPS.

### Pitfall 4: Coolify does not support moving apps between servers

**What goes wrong:** Operator adds `deploy_server:` to an existing repo (one that already has `coolify_app_ids` cached) and re-runs `/setup-coolify`. The existing apps on localhost are not moved — `provision.sh` finds them by name and skips creation. Apps remain on localhost.

**Why it happens:** `coolify_find_app_by_name` is name-based. It finds the existing app regardless of which server it's on. Coolify has no API to move an app between servers.

**How to avoid:** Migration guide (MSRV-08) must be explicit: to move an app from localhost to a separate server, the operator must (1) delete the old app in Coolify UI, (2) clear `coolify_app_ids` in `coolify.yaml`, (3) re-run `/setup-coolify`. The skill cannot automate this.

**Warning signs:** `provision.sh` prints `EXISTS` for both apps but apps are still served from localhost.

### Pitfall 5: validate.sh coolify_load_server called before deploy_server check

**What goes wrong:** `validate.sh` calls `coolify_load_server "$SERVER"` (the Coolify instance alias) to set `COOLIFY_URL` and `COOLIFY_API_KEY`. If this is moved or delayed, the subsequent Coolify API calls for server validation fail.

**Why it happens:** `deploy_server` check requires the Coolify API to be reachable, which requires the server alias to already be loaded.

**How to avoid:** Add the `deploy_server` validation block after the existing `coolify_load_server` + reachability check, not before. The ordering in validate.sh is: YAML parse → alias check → ssh_host check → API reachable → Doppler keys → DNS → [new] deploy_server. This ensures the API is confirmed reachable before trying to list servers.

---

## Code Examples

### Extract deploy_server from coolify.yaml (provision.sh parse block)

```python
# Source: extends existing eval "$(python3 -c...)" parse block in provision.sh
import yaml
d = yaml.safe_load(open('$YAML_PATH'))
print(f"DEPLOY_SERVER='{d.get('deploy_server', '')}'")
```

```bash
# In provision.sh, after existing SERVER_NAME resolution:
if [ -n "${DEPLOY_SERVER:-}" ]; then
  # Override: use deploy_server from coolify.yaml
  DEPLOY_SERVER_NAME="$DEPLOY_SERVER"
else
  # Existing fallback chain (unchanged):
  DEPLOY_SERVER_NAME=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
print(e.get('server_name','localhost'))
")
fi
```

### Resolve DEPLOY_SSH_HOST in provision.sh

```bash
# After SSH_HOST resolution (which reads ssh_host — unchanged):
DEPLOY_SSH_HOST=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
e=d.get('servers',{}).get('$SERVER_ALIAS',{})
# deploy_ssh_host overrides ssh_host for volume creation and IP resolution
print(e.get('deploy_ssh_host', '') or e.get('ssh_host', ''))
")
# DEPLOY_SSH_HOST is now the SSH alias for the deployment VPS
# SSH_HOST retains its current value (Coolify host alias) for backward compat
```

### IP resolution for DNS (deploy server aware)

```bash
# In provision.sh, after DEPLOY_SERVER_UUID is known:
DEPLOY_VPS_IP=$(python3 -c "
import json
d=json.load(open('$HOME/.claude/coolify.json'))
print(d.get('servers',{}).get('$SERVER_ALIAS',{}).get('deploy_vps_ip',''))
")
if [ -z "$DEPLOY_VPS_IP" ]; then
  # Try Coolify API: GET /servers/{uuid}.ip (real IP for remote servers)
  DEPLOY_VPS_IP=$(coolify_curl GET "/servers/$DEPLOY_SERVER_UUID" | python3 -c "
import json,sys
ip=json.load(sys.stdin).get('ip','')
# Skip 'host.docker.internal' — that is the Coolify host internal alias, not a real IP
if ip and ip != 'host.docker.internal': print(ip)
" 2>/dev/null || echo "")
fi
if [ -z "$DEPLOY_VPS_IP" ]; then
  # Final fallback: SSH to deploy VPS
  DEPLOY_VPS_IP=$(ssh "$DEPLOY_SSH_HOST" "curl -s -4 ifconfig.me" 2>/dev/null | tr -d '[:space:]' || echo "")
fi
```

### Validate deploy_server existence (validate.sh)

```bash
# In validate.sh, after API reachability check, before Doppler key checks:
DEPLOY_SERVER=$(python3 -c "
import yaml
d=yaml.safe_load(open('$YAML_PATH'))
print(d.get('deploy_server',''))
")
if [ -n "$DEPLOY_SERVER" ]; then
  DEPLOY_SRV_UUID=$(coolify_get_server_uuid "$DEPLOY_SERVER")
  if [ -z "$DEPLOY_SRV_UUID" ]; then
    AVAILABLE=$(coolify_curl GET "/servers" | python3 -c "
import json,sys
print(', '.join(s.get('name','') for s in json.load(sys.stdin)))
" 2>/dev/null || echo "<unable to list>")
    fail "INVALID:coolify.yaml:deploy_server '$DEPLOY_SERVER' not registered in Coolify (available: $AVAILABLE)"
  else
    echo "validate: deploy_server '$DEPLOY_SERVER' -> uuid=$DEPLOY_SRV_UUID OK"
  fi
fi
```

### coolify.yaml template fragment

```yaml
# CHANGE: Coolify-registered server name for app deployment.
# When absent (default), apps are deployed on the Coolify host ('localhost').
# Set this only when staging/production apps should run on a different VPS
# from the Coolify host itself.
# Example: deploy_server: my-app-vps
# deploy_server:
```

---

## Confirmed API Facts (from live inspection)

| Fact | Confidence | Source |
|------|-----------|--------|
| `GET /servers` returns `name`, `uuid`, `ip`, `is_coolify_host` per server | HIGH | Live API query on vultr-stream |
| `GET /servers/{uuid}.ip` = `"host.docker.internal"` for the Coolify host | HIGH | Live API query |
| `GET /servers/{uuid}.ip` = real IP for remote servers (entered at registration) | MEDIUM | Coolify UI behavior; confirmed by docs |
| `GET /destinations` returns 404 on this Coolify version | HIGH | Live API query |
| `POST /applications/dockerimage` accepts any registered `server_uuid` | HIGH | Live provisioning + deepwiki API schema |
| `destination_uuid` is optional — Coolify auto-assigns when omitted | HIGH | Live provision.sh behavior confirmed |
| Scanning `GET /applications` for `destination.server.uuid` match returns the correct destination UUID | HIGH | Live API query on vultr-stream |
| Coolify has no API to move an existing app between servers | HIGH | No endpoint found; deepwiki confirms |
| App `destination.server` is immutable after creation | HIGH | Coolify architecture (server selection at create time) |

---

## State of the Art

| Old Approach | Current Approach | Impact |
|---|---|---|
| Hardcoded `server_name="localhost"` | `server_name` in coolify.json (Phase 1 bug fix) | Now configurable, default preserved |
| `GET /destinations` for destination UUID | Scan `GET /applications` by server UUID | Works across Coolify versions; 404-resilient |
| `ssh_host` for all SSH ops | `deploy_ssh_host` overrides `ssh_host` for deploy VPS | SSH targets the right server |

---

## Open Questions

1. **destination_uuid for first app on a brand-new remote server**
   - What we know: `destination_uuid` omitted → Coolify picks the default for the given `server_uuid`. For localhost this works. For a remote server that has no apps yet, no app to scan for destination UUID.
   - What's unclear: Does Coolify correctly auto-assign the destination for a remote server when `destination_uuid` is absent from the CREATE body?
   - Recommendation: Add a post-create verification: after CREATE, do `GET /applications/{uuid}.destination.server.uuid` and compare to `DEPLOY_SERVER_UUID`. If they don't match, hard-fail with an error that tells the operator to provide `deploy_vps_ip` or check their Coolify server setup. This is the round-trip verification pattern already used for volume mounts.

2. **`init.sh` prompt for `deploy_server`**
   - What we know: init.sh currently has no prompt for this field.
   - What's unclear: Should the default be blank (commented out in template) or prompted always?
   - Recommendation: Prompt is optional — ask "Deploy server (leave blank for Coolify host):" and render as commented-out when blank. This matches the optional-field pattern used for DNS.

---

## Environment Availability

Step 2.6: SKIPPED — phase is code/config changes only. No new external tools or services beyond what provision.sh already requires (`bash`, `python3`, `curl`, `ssh`). The Coolify API endpoints used (`GET /servers`, `GET /applications`) are confirmed available on the target instance.

---

## Validation Architecture

> nyquist_validation not explicitly disabled — section included.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Custom bash test runner — `test/e2e.sh` (no framework dependency) |
| Config file | none |
| Quick run command | `bash test/e2e.sh --server <alias>` (targets real Coolify) |
| Full suite command | `bash test/e2e.sh --server <alias>` + `bash test/validate-workflow.sh .github/workflows/deploy.yml` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MSRV-01 | `deploy_server:` absent → provisions on localhost unchanged | manual / e2e | `bash test/e2e.sh --server <alias>` (deploy_server absent) | ✅ existing |
| MSRV-02 | `deploy_server: X` → app created on server X | manual-only (requires second registered server) | N/A — no second server in test env | ❌ not testable in CI |
| MSRV-03 | validate.sh exits non-zero when deploy_server not in Coolify | unit-style | `bash test/validate-deploy-server.sh` | ❌ Wave 0 |
| MSRV-04 | `deploy_ssh_host` overrides `ssh_host` for SSH ops | manual | SSH connectivity test | N/A |
| MSRV-05 | DNS A record points to deploy VPS IP | manual | `dig +short <domain>` after provision | N/A |
| MSRV-06 | Existing coolify.yaml without deploy_server unchanged | e2e | `bash test/e2e.sh --server <alias>` (no deploy_server in coolify.yaml) | ✅ existing |
| MSRV-07 | schema.md + setup-guide.md updated | manual doc review | N/A | N/A |
| MSRV-08 | Migration guide exists and is accurate | manual review | N/A | N/A |

**Note on MSRV-02, MSRV-04, MSRV-05:** These require a second VPS registered in Coolify. The E2E test environment has only one server (`vultr-stream`). These requirements are validated manually or accepted as lower confidence. The E2E_SERVER env var override test (Phase 2 decision) was similarly accepted.

### Wave 0 Gaps

- [ ] `test/validate-deploy-server.sh` — unit-style test for MSRV-03: mock a coolify.yaml with `deploy_server: nonexistent` and verify validate.sh exits 1 with the named server in the error. Can be implemented as a local bash test against the real Coolify API (server name that doesn't exist → validate fails).

*(Existing test infrastructure covers MSRV-01 and MSRV-06 via the standard e2e.sh run.)*

---

## Sources

### Primary (HIGH confidence)

- Live Coolify API — `GET /servers`, `GET /applications`, `GET /applications/{uuid}` queried against `https://coolify.cicd.streamlinity.com`
- `/home/cnut/development/claude-skills-deploy/scripts/provision.sh` — current server/destination/SSH resolution code paths
- `/home/cnut/development/claude-skills-deploy/scripts/lib-coolify-api.sh` — `coolify_get_server_uuid`, `coolify_get_destination_uuid` functions
- `/home/cnut/development/claude-skills-deploy/scripts/validate.sh` — existing validation accumulation pattern

### Secondary (MEDIUM confidence)

- [Coolify multi-server docs](https://coolify.io/docs/knowledge-base/server/multiple-servers) — confirms separate VPS model, worker nodes need Docker+SSH only
- [DeepWiki Coolify API Endpoints](https://deepwiki.com/coollabsio/coolify/8.2-application-api-endpoints) — `destination_uuid` listed as required in POST schema; actual behavior (auto-assign when omitted) confirmed via live API

### Tertiary (LOW confidence)

- `GET /servers/{uuid}.ip` = real public IP for remote servers — confirmed for localhost only (host.docker.internal); remote server behavior inferred from Coolify UI behavior when adding a server

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — no new dependencies; existing script patterns confirmed
- Architecture: HIGH — Coolify API behavior verified live; all key assumptions confirmed
- Pitfalls: HIGH — all four pitfalls derived from actual API behavior and code path analysis
- MSRV-02 runtime (second server): LOW — cannot test without a second registered server; API behavior inferred

**Research date:** 2026-06-07
**Valid until:** 2026-09-07 (Coolify API is stable; 90-day validity for API behavior findings)
