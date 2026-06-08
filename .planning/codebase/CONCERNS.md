# Codebase Concerns

**Analysis Date:** 2026-05-21

---

## Tech Debt

**Hardcoded server name "localhost" for Coolify node lookup:**
- Issue: `coolify_get_server_uuid "localhost"` is hardcoded in `scripts/provision.sh` line 47. Coolify server names are user-configurable and may not be "localhost" on all installs.
- Files: `scripts/provision.sh:47`
- Impact: Provision fails with "ERROR: server 'localhost' not found" on any Coolify instance where the node was registered with a custom name. Silent breakage for new users.
- Fix approach: Add an optional `server_name` field to `coolify.json` server entries (default `"localhost"`). Read it in `provision.sh` the same way `ssh_host` is read.
- Severity: **HIGH**

**Fallback CREATE endpoint — potentially correct but request body mismatch:**
- Context: `references/api-reference.md` (from Phase 7 research) shows `POST /applications/private-github-app` with `"source_type": "registry"` as the correct endpoint for registry-based (same-image promotion) deploys. However, `provision.sh` lines 99–101 try `POST /applications/dockerimage` first and fall back to `POST /applications/private-github-app` — the bodies may differ between the primary and fallback paths.
- Files: `scripts/provision.sh:99-101`, `references/api-reference.md`
- Impact: If the primary `dockerimage` endpoint fails, the fallback may succeed or fail depending on Coolify version. The request body used for the fallback path has not been verified to include `source_type: "registry"` and other registry-specific fields.
- Fix approach: Verify which endpoint the installed Coolify version supports; unify to a single endpoint with the correct body. Fail loudly on error with the actual response body.
- Severity: **MEDIUM**

**`doppler_download_secrets` defined but never called:**
- Issue: `lib-doppler-api.sh:51-53` defines `doppler_download_secrets` which is not called anywhere in the codebase.
- Files: `scripts/lib-doppler-api.sh:51-53`
- Impact: Dead code — creates confusion about the intended secrets injection path.
- Fix approach: Remove the function, or document its intended future use.
- Severity: **LOW**

**`coolify_get_github_app_uuid` defined but never called by provision.sh:**
- Issue: `lib-coolify-api.sh:101-116` defines `coolify_get_github_app_uuid`. `SKILL.md` step 2 says the provision flow calls it and bails if not found, but `provision.sh` never calls it.
- Files: `scripts/lib-coolify-api.sh:101-116`, `SKILL.md` (step 2 description is inaccurate)
- Impact: SKILL.md is misleading. The function is dead code. No functional impact on the actual provision flow.
- Fix approach: Remove the function and update SKILL.md step 2 to reflect the actual flow.
- Severity: **LOW**

**SKILL.md documents a deploy trigger step that does not exist:**
- Issue: `SKILL.md` step 6 says "Trigger initial deploys for both apps (`coolify_deploy_app`)". `provision.sh` ends at writing back `coolify_app_ids` with no deploy trigger. `coolify_deploy_app` is defined in `lib-coolify-api.sh:135` but is only called from `test/e2e.sh`.
- Files: `SKILL.md` (step 6), `scripts/provision.sh` (end of file), `scripts/lib-coolify-api.sh:135`
- Impact: Users expect the first deploy to be triggered automatically after provisioning. It is not. They must push a commit or manually trigger from the Coolify dashboard.
- Fix approach: Either add the deploy trigger at the end of `provision.sh`, or remove step 6 from `SKILL.md`.
- Severity: **MEDIUM**

---

## Security Considerations

**Shell injection via user-controlled values interpolated into `python3 -c` strings:**
- Risk: In `lib-coolify-api.sh`, shell variables like `$alias`, `$name`, and `$server_uuid` are directly interpolated inside double-quoted `python3 -c "..."` strings. A value containing `'` or `\n` or Python code fragments would break the inline Python or allow unintended execution (e.g., an alias of `x'; import os; os.system('rm -rf ~'); x='` passed to `coolify_load_server`). Same pattern in `lib-doppler-api.sh:17-21`.
- Files: `scripts/lib-coolify-api.sh:19-26`, `scripts/lib-coolify-api.sh:54-58`, `scripts/lib-coolify-api.sh:73-77`, `scripts/lib-doppler-api.sh:17-21`
- Current mitigation: In practice, values come from `~/.claude/coolify.json` which the user controls. Risk is low for single-user local use.
- Recommendation: Pass values as Python `sys.argv` arguments (the `heredoc + sys.argv` pattern used in `provision.sh:147` is the safe pattern — apply it in the lib functions too).
- Severity: **MEDIUM**

**Doppler service token printed to stdout inside `ENVS_JSON`:**
- Risk: `provision.sh` line 141 captures the Doppler service token in `$DOPPLER_SVC_TOKEN`. It is then passed as a positional argument to a Python heredoc at line 147 and embedded into `ENVS_JSON` (a JSON string). If shell debug mode (`set -x`) is active or if output is redirected to a log file, the token is visible in plaintext.
- Files: `scripts/provision.sh:141-162`
- Current mitigation: No `set -x` in provision.sh; output not redirected by default.
- Recommendation: Acceptable for a local dev tool. Add a comment noting the token is ephemeral and rotation (line 140) provides defense in depth.
- Severity: **LOW**

**`coolify.json` absence from `.gitignore`:**
- Risk: `~/.claude/coolify.json` contains the Coolify API key and is stored outside any repo, so it cannot be accidentally committed from this repo. However, there is no advisory note in `.gitignore` and no `pre-commit` hook to prevent a user from copying it into a project directory.
- Files: `.gitignore`
- Current mitigation: File lives at `~/.claude/` by default — outside any repo.
- Recommendation: Low risk as-is. Consider adding a `coolify.json` entry to `.gitignore` as a safety net.
- Severity: **LOW**

---

## Reliability Risks

**Silent empty-value injection when Doppler `secrets get` fails:**
- Issue: `provision.sh` lines 153–158 use `subprocess.run` to fetch each env var from Doppler, then set `v = result.stdout.strip()` unconditionally. If the `doppler secrets get` subprocess fails (network blip, revoked token, wrong project), `result.stdout` is empty and `v = ""`. The empty string is then appended to `data` and pushed to Coolify, silently setting the env var to an empty string in the container.
- Files: `scripts/provision.sh:153-158`
- Impact: App container starts with blank env vars. Failures are silent — `provision.sh` reports "ENVS synced (N keys)" with no indication that some values are empty. `validate.sh` catches this pre-flight, but only for keys that are non-empty in Doppler at validation time. If Doppler is unavailable only during provision (not during validate), silent empty values reach Coolify.
- Fix approach: Check `result.returncode` and `result.stderr`; `raise SystemExit` if any fetch fails, surfacing the specific key and error.
- Severity: **HIGH**

**No retry logic on any API call:**
- Issue: `coolify_curl` in `lib-coolify-api.sh:38-49` makes a single `curl` call with `-sfS` (fail on HTTP errors, no retry). `doppler_cmd` in `lib-doppler-api.sh:29-31` is a direct `doppler` call. No transient-error retries anywhere.
- Files: `scripts/lib-coolify-api.sh:38-49`, `scripts/lib-doppler-api.sh:29-31`
- Impact: A momentary Coolify API hiccup during provisioning causes the entire run to fail, requiring a full re-run.
- Fix approach: Add `--retry 3 --retry-delay 2` to `curl` calls in `coolify_curl`. Wrap `doppler_cmd` in a retry loop for transient failures.
- Severity: **MEDIUM**

**No rollback if staging provisioning succeeds but production provisioning fails:**
- Issue: `provision.sh` loops over `staging` then `production` sequentially. If staging is fully created (app, volume, Doppler token, env vars) and then production fails partway (e.g., SSH volume creation fails), the script exits 1 with no cleanup. On re-run (which is idempotent), the partially-created production app may have inconsistent state (old service token already revoked at line 140, new token not created).
- Files: `scripts/provision.sh:72-176`
- Impact: Re-run after a mid-loop failure should be safe due to idempotency design, but the Doppler token revocation at line 140 occurs before the new token is confirmed created. A failure between lines 140 and 142 leaves the environment with no valid service token.
- Fix approach: Restructure the token rotation to create-new-then-revoke-old, not revoke-then-create. Add a `trap cleanup EXIT` similar to `test/e2e.sh`.
- Severity: **MEDIUM**

**`coolify.yaml` write-back is not atomic:**
- Issue: `provision.sh` lines 182–188 open `coolify.yaml`, modify it in memory, then write it back with `open(path, 'w')`. If the process is interrupted between open-for-write and close (e.g., SIGKILL), `coolify.yaml` is truncated to empty.
- Files: `scripts/provision.sh:182-188`
- Impact: Loss of the entire `coolify.yaml` file on rare interrupt. Recoverable from git but unexpected.
- Fix approach: Write to a temp file then `os.replace(tmp, path)` (atomic on POSIX).
- Severity: **LOW**

**validate.sh does not verify SSH connectivity, only field presence:**
- Issue: `validate.sh` lines 63–75 check that `ssh_host` is non-empty in `coolify.json` but do not attempt `ssh -q -o BatchMode=yes "$SSH_HOST_CHECK" exit`. If the SSH alias is stale or the server is unreachable, `provision.sh` will fail at the `docker volume create` step (line 131) after all Coolify mutations have already occurred.
- Files: `scripts/validate.sh:63-75`
- Impact: Provision is partially completed (project and app created in Coolify, Doppler tokens created) before the SSH failure is detected.
- Fix approach: Add `ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST_CHECK" exit` to `validate.sh` and fail early if unreachable.
- Severity: **MEDIUM**

---

## Bugs

**Generated workflow references a non-existent job `smoke-staging`:**
- Issue: `generate-workflow.sh` line 146 emits `needs: [smoke-staging, build]` for `deploy-production`, but there is no `smoke-staging` job defined in the generated workflow. The smoke test is implemented as a step inside `deploy-staging`, not as a separate job.
- Files: `scripts/generate-workflow.sh:146`
- Impact: The generated `.github/workflows/deploy.yml` is **invalid** — GitHub Actions will reject it at parse time with "Job 'deploy-production' references non-existent job 'smoke-staging'". Production will never deploy automatically.
- Fix approach: Change `needs: [smoke-staging, build]` to `needs: [deploy-staging, build]` in the `cat > "$OUT_PATH"` heredoc.
- Severity: **HIGH** (functional breakage — production deploy pipeline is broken for all generated workflows)

**Smoke test in generated workflow polls `/` not `/api/health`:**
- Issue: The `deploy-staging` smoke test in the generated workflow (line 138) calls `curl -sfS "https://$STAGING_DOMAIN/" -o /dev/null` — the root path, not `/api/health`. The health check configured in Coolify (via PATCH in `provision.sh` line 121) is `/api/health`. The `e2e.sh` test (line 423) correctly polls `/api/health`.
- Files: `scripts/generate-workflow.sh:138`
- Impact: The CI smoke test may return 200 from a static or redirect response on `/` even if the app's health endpoint is broken.
- Fix approach: Change the smoke test URL to `"https://$STAGING_DOMAIN/api/health"`.
- Severity: **MEDIUM**

---

## Maintainability Issues

**YAML parsing pattern duplicated across four scripts:**
- Issue: The same `eval "$(python3 -c "import yaml; d=yaml.safe_load(open('$YAML_PATH')); print(...)")"` block appears in `provision.sh:22-34`, `validate.sh:24-36`, `generate-workflow.sh:30-45`, and `test/e2e.sh:317-323`. Any change to the coolify.yaml schema requires updates in all four locations.
- Files: `scripts/provision.sh:22-34`, `scripts/validate.sh:24-36`, `scripts/generate-workflow.sh:30-45`, `test/e2e.sh:317-323`
- Fix approach: Extract into a shared `lib-yaml.sh` function that exports all variables.
- Severity: **MEDIUM**

**`python3 -c` inline strings with shell variable interpolation are fragile:**
- Issue: Throughout the lib files, multi-line `python3 -c "..."` strings embed shell variables via double-quote interpolation. The code is difficult to read, cannot be syntax-highlighted, and is brittle if a variable contains a single quote or newline.
- Files: `scripts/lib-coolify-api.sh:19-35`, `scripts/lib-coolify-api.sh:54-58`, `scripts/lib-coolify-api.sh:73-77`, `scripts/lib-doppler-api.sh:17-21`
- Fix approach: Use the `python3 - "$arg" <<'PY'` heredoc pattern (already used in `provision.sh:147` and `provision.sh:179`) consistently.
- Severity: **LOW**

**`doppler_cmd` wrapper adds no value:**
- Issue: `lib-doppler-api.sh:29-31` defines `doppler_cmd() { doppler "$@"; }` — a one-line passthrough. The comment says it exists because Doppler CLI v3.76.0 has no `--account` flag, but since the wrapper does nothing, `DOPPLER_ACCOUNT` is exported but never actually used to scope the CLI commands.
- Files: `scripts/lib-doppler-api.sh:29-31`
- Impact: If multiple Doppler accounts are authenticated on the same machine, the CLI may default to the wrong account. The DOPPLER_ACCOUNT field in coolify.json is decorative.
- Fix approach: If multi-account support is needed, investigate `DOPPLER_CONFIG` or `doppler configure set` as the scoping mechanism. Document the limitation clearly.
- Severity: **MEDIUM**

---

## Scalability Limits

**Single-environment assumption: only `staging` and `production` are provisioned:**
- Issue: `provision.sh` lines 72–176 iterate over a hardcoded `for ENV_NAME in staging production` loop. The `coolify.yaml` schema provides no way to add a third environment (e.g., `preview`, `canary`, `qa`).
- Files: `scripts/provision.sh:72`
- Impact: Not a current blocker, but any use case requiring more than two environments requires script modification.
- Fix approach: Read environment names from `coolify.yaml` `environments:` keys dynamically.
- Severity: **LOW**

**No support for private GHCR registries in the Coolify app create payload:**
- Issue: `provision.sh` lines 82–98 build the app create body without registry credentials. Apps pulling from private GHCR registries (`ghcr.io`) will fail to deploy unless the Coolify server already has the registry credentials configured manually in its UI. There is no provisioning step for registry auth.
- Files: `scripts/provision.sh:82-98`
- Impact: First-time deploys will fail silently (Coolify will report an image pull error) on private registries not pre-configured in Coolify.
- Fix approach: Document the requirement in `docs/setup-guide.md`. Optionally, add a `PATCH /applications/$APP_UUID` call to set registry credentials if a `registry.username` and `registry.token` field are present in `coolify.yaml`.
- Severity: **MEDIUM**

---

## Missing Capabilities

**No support for multi-node Coolify installs:**
- The `coolify_get_server_uuid "localhost"` hardcode (see Tech Debt above) means the skill only works on single-node Coolify installations where the managed Docker host is named "localhost". Multi-node setups are unsupported.
- Files: `scripts/provision.sh:47`
- Severity: **HIGH** (blocks any multi-node Coolify user)

**No mechanism to update `generate-workflow.sh` output after re-provisioning:**
- Issue: `SKILL.md` says "Do not hand-edit — regenerate via `/setup-coolify` (rerun)". But the provision flow (`provision.sh`) does not call `generate-workflow.sh`. After re-provisioning (which may produce new app UUIDs), the deployed workflow file retains the old UUIDs unless the user manually re-runs `generate-workflow.sh`.
- Files: `scripts/provision.sh`, `SKILL.md`
- Fix approach: Add a `bash "$SCRIPT_DIR/generate-workflow.sh" "$YAML_PATH"` call at the end of `provision.sh` after writing back `coolify_app_ids`.
- Severity: **MEDIUM**

**No `env_vars` removal: deleted keys accumulate in Coolify:**
- Issue: `provision.sh` step 2e pushes `DOPPLER_TOKEN` + all `env_vars` keys to Coolify via bulk PATCH. If a key is removed from `coolify.yaml`, it is not deleted from the Coolify app — it persists until manually removed in the Coolify dashboard.
- Files: `scripts/provision.sh:145-164`
- Fix approach: Compare current Coolify env vars against the desired set and DELETE stale keys before the bulk PATCH.
- Severity: **LOW**

---

## Test Coverage Gaps

**`test_init.sh` does not test the idempotency guard for `deploy.yml` with a pre-existing `coolify.yaml`:**
- What's not tested: Test 7 only places a pre-existing `deploy.yml` (no `coolify.yaml`). No test covers the scenario where both files exist and `init.sh` should refuse.
- Files: `init/test_init.sh:121-128`
- Risk: Regression in the idempotency guard is not caught.
- Severity: **LOW**

**`test_init.sh` uses `((FAIL++))` without `set -e` protection:**
- Issue: `init/test_init.sh:8` sets `set -uo pipefail` but omits `-e`. Line 20: `((FAIL++))` — in bash, `(( expr ))` exits with status 1 when the result is zero (i.e., on the first failure increment from 0, `(( 0++ ))` returns exit status 1). With `-e` this would abort the test. Without `-e` it silently continues, which is intentional — but `((PASS++))` on line 18 has the same issue when PASS is 0. The script works only because the first test tends to pass before any failure.
- Files: `init/test_init.sh:18-20`
- Risk: If the very first test fails, `FAIL` increments from 0 to 1, and `(( FAIL++ ))` returns exit status 1. Without `-e` this is harmless, but the pattern is non-obvious and fragile.
- Fix approach: Use `FAIL=$((FAIL+1))` and `PASS=$((PASS+1))` (arithmetic expansion, always exit 0).
- Severity: **LOW**

**No unit tests for `lib-coolify-api.sh` or `lib-doppler-api.sh`:**
- What's not tested: All library functions (URL construction, JSON parsing, UUID extraction) are tested only through end-to-end integration runs. Logic bugs in name-matching (e.g., partial name match in `coolify_find_app_by_name`) would not be caught without a live Coolify instance.
- Files: `scripts/lib-coolify-api.sh`, `scripts/lib-doppler-api.sh`
- Risk: Silent name-collision bugs (e.g., `myapp` matching `myapp-staging`).
- Priority: Medium

**E2E test is hardcoded to a specific domain and org:**
- Issue: `test/e2e.sh` lines 256–257 hardcode `cicd.streamlinity.com` as the test domain. `E2E_IMAGE` defaults to `ghcr.io/streamlinity/...`. Running the E2E against a different Coolify server would produce test apps with unreachable FQDNs (the smoke test would fail at DNS/cert), making the test unreliable for contributors using other servers.
- Files: `test/e2e.sh:256-257`, `test/e2e.sh:38`
- Risk: E2E test is non-portable outside the original maintainer's infrastructure.
- Fix approach: Make the base domain configurable via an `E2E_BASE_DOMAIN` environment variable.
- Priority: Medium

---

*Concerns audit: 2026-05-21*
