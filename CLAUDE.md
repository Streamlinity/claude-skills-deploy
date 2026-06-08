# claude-skills-deploy

Coolify + Doppler deployment skills for Claude Code.

## Available Skills

| Skill | Invoke | Purpose |
|-------|--------|---------|
| `setup-coolify` | `/setup-coolify` | Provision/update Coolify staging + production apps from coolify.yaml. Idempotent. |
| `setup-coolify init` | `/setup-coolify init` | Interactive setup of `~/.claude/coolify.json` for a new Coolify server alias. |
| `setup-coolify validate` | `/setup-coolify validate` | Dry-run check: verifies Doppler keys + Coolify API reachability. No mutations. |

## Install

```bash
git clone https://github.com/Streamlinity/claude-skills-deploy.git ~/.claude/skills/setup-coolify
```

No build step. `/setup-coolify` is immediately available in any new Claude Code session.

## Bootstrap a new repo

From the target repo's root directory:

```bash
bash ~/.claude/skills/setup-coolify/init/init.sh
```

The init script prompts for project name, server alias, Doppler project, GHCR registry image, staging/production domains, build paths, and env var keys. It writes `coolify.yaml` to the current directory.

Then:
```bash
/setup-coolify validate    # dry-run check
/setup-coolify             # provision Coolify + Doppler
bash ~/.claude/skills/setup-coolify/scripts/generate-workflow.sh
```

## Documentation

- **[README.md](./README.md)** — Top-level user guide
- **[docs/setup-guide.md](./docs/setup-guide.md)** — Per-domain Coolify + Doppler initial setup
- **[docs/fork-guide.md](./docs/fork-guide.md)** — How to use this skill for a new domain (strategem.ai example)
- **[docs/schema.md](./docs/schema.md)** — coolify.yaml + coolify.json schema reference
- **[references/api-reference.md](./references/api-reference.md)** — Coolify + Doppler REST API reference

## Design

Domain-agnostic by design. The `server:` field in `coolify.yaml` selects which Coolify instance and Doppler workspace to use. Per-machine credentials live in `~/.claude/coolify.json` (never committed). Adding a new domain requires zero script changes — only a new server entry in `coolify.json` and a new `coolify.yaml` in the target repo.

<!-- GSD:project-start source:PROJECT.md -->
## Project

**claude-skills-deploy**

A Claude Code skills repo that provides a standardized, domain-agnostic way to deploy any application onto a Coolify + Doppler managed CI/CD environment running on a VPS. The skill provisions staging and production apps, wires in Doppler secrets, and generates a same-image-promotion GitHub Actions pipeline — all from a single `coolify.yaml` manifest committed to the target repo. It is designed to be forked to support additional domains (e.g., `strategem.ai` alongside `streamlinity.com`) with zero script changes.

**Core Value:** A developer can clone this repo, run one command, see a working hello-world deployment on their Coolify server, and trust the skill is correct before using it for a real application.

### Constraints

- **No auto-cleanup**: E2E test must not tear down the deployment — new users need to see the result
- **Domain portability**: Any hardcoded `streamlinity.com` references in the test harness must become env vars — the test must run on any Coolify server
- **No GitHub API dependency**: Test framework must not require a live GitHub push or Actions run — runs standalone on the operator's machine
- **Bash + Python3 only**: No new language runtimes or package managers — the skill is pure shell + python3 (pyyaml); test tooling must stay in this stack
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Bash (POSIX + bash 4+) - All skill scripts, library files, init, test, and workflow generation
- Python 3 (3.6+) - Inline data processing embedded in bash scripts via `python3 -c` and heredoc `<<'PY'` blocks; used for YAML parsing, JSON construction, and config extraction
- YAML - Config format for `coolify.yaml` (per-repo manifest) and GitHub Actions workflow `deploy.yml`
- JSON - Machine-local credentials format (`~/.claude/coolify.json`)
## Runtime
- Linux (bash shell required; tested on Ubuntu via GitHub Actions `ubuntu-latest`)
- macOS compatible (bash 3 ships by default — scripts use `#!/usr/bin/env bash` with `set -euo pipefail`)
## Package Manager
- None — no `package.json`, `requirements.txt`, `Cargo.toml`, or `go.mod` present
- Lockfile: Not applicable
- Python dependency: `pyyaml` (PyPI) — required by `provision.sh`, `validate.sh`, `generate-workflow.sh`, and `test/e2e.sh`; installed by the consumer, not by this skill
## Frameworks
- None — skill is plain bash with no framework dependencies
- Custom bash test runner (`test/e2e.sh`) with inline pass/fail counters; no framework (no bats, no shunit2)
- None — no build step; scripts are executed directly
## Key Dependencies (External CLI Tools)
| Tool | Version Noted | Purpose |
|------|---------------|---------|
| `bash` | 4+ recommended | Script execution |
| `python3` | 3.6+ | YAML/JSON parsing (inline in all major scripts) |
| `pyyaml` | any | Python YAML library — `import yaml` in `provision.sh`, `validate.sh`, `generate-workflow.sh`, `test/e2e.sh` |
| `doppler` | CLI v3.76.0 (noted in `lib-doppler-api.sh`) | Secret management CLI; `doppler secrets`, `doppler configs tokens` |
| `curl` | any | Coolify REST API calls in `lib-coolify-api.sh` and generated `deploy.yml` |
| `ssh` | any | Docker volume creation on Coolify VPS via `provision.sh` |
| `docker` | any | Image pull check in `test/e2e.sh`; Docker volume management on remote server |
| Tool / Action | Version | Purpose |
|---------------|---------|---------|
| `actions/checkout` | v4 | Source checkout |
| `docker/login-action` | v3 | GHCR authentication |
| `docker/build-push-action` | v6 | Docker image build and push |
| `actions/delete-package-versions` | v5 | GHCR tag retention cleanup |
## Configuration
- No `.env` file used by the skill itself
- Credentials live in `~/.claude/coolify.json` (machine-local, never committed)
- Per-repo deployment config lives in `coolify.yaml` (committed, no secrets)
- Doppler service tokens are scoped per Coolify app and set as env vars by `provision.sh`
- `coolify.yaml` — per-repo manifest (template at `init/templates/coolify.yaml.tmpl`)
- `~/.claude/coolify.json` — machine-local credential registry (path overridable via `COOLIFY_REGISTRY` env var in `lib-coolify-api.sh` and `lib-doppler-api.sh`)
## Platform Requirements
- Linux or macOS
- `bash` 4+, `python3` with `pyyaml`, `doppler` CLI (authenticated), `curl`, `ssh`
- `~/.ssh/config` entry for the Coolify VPS (`ssh_host` alias in `coolify.json`)
- `~/.claude/coolify.json` populated via `/setup-coolify init`
- Recommended: $6–12/mo VPS (2 vCPU, 4 GB RAM minimum); Ubuntu 22.04 LTS tested
- Providers: Vultr, Hetzner, AWS EC2
- Coolify install: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash` (installs Docker + Coolify + systemd; 2–5 min)
- Coolify (self-hosted; single-node with server named `localhost`)
- Docker (for named volume management)
- HTTPS / Let's Encrypt (Coolify-managed; requires DNS A record pointing to VPS before enabling)
- `allowed_ips` in Coolify Settings → Security must be cleared (`*`) before API calls succeed
- GHCR image pull access (public images or GHCR PAT configured in Coolify)
- `ubuntu-latest` runner
- `COOLIFY_API_KEY` — Coolify Bearer token (GitHub Actions secret, set manually per repo)
- `COOLIFY_URL` — Coolify instance root URL (GitHub Actions secret, set via `gh secret set COOLIFY_URL`)
- `GITHUB_TOKEN` — automatic; needs `packages: write` for GHCR push (set via repo Settings → Actions → General → Workflow permissions → Read and write)
- `build.context` / `build.dockerfile` in `coolify.yaml` — optional; absent fields default to `.` and `./Dockerfile`. Existing files without the `build:` block continue to work.
- `ssh_host` in `coolify.json` — required as of Phase 8; Phase 7 implementations defaulted to `v_cicd_stream` when absent (fallback removed). Run `/setup-coolify init` to populate.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Shell Script Style
- All scripts use `#!/usr/bin/env bash` (never `/bin/bash`)
- All scripts open with `set -euo pipefail` — no exceptions
- Library files (`lib-*.sh`) also set this despite being sourced
- Every script opens with a `# filename — one-line purpose` comment on line 2
- Multi-line preamble blocks document: purpose, usage, prerequisites, important notes
- Example from `scripts/generate-workflow.sh`:
- All scripts resolve their own directory using:
- Top-level scripts in subdirectories (e.g. `init/init.sh`) use `..` to reach `SKILL_DIR`:
- All downstream paths are absolute, derived from these variables — never relative
## Naming Patterns
- Core executables: `verb.sh` (`provision.sh`, `validate.sh`, `generate-workflow.sh`)
- Shared libraries: `lib-noun-api.sh` (`lib-coolify-api.sh`, `lib-doppler-api.sh`)
- Test files: `test_noun.sh` for unit-style tests (`init/test_init.sh`), `noun.sh` for integration tests (`test/e2e.sh`)
- Helper scripts: `verb-noun.sh` (`push-hello-world.sh`)
- Library functions: `noun_verb` or `noun_verb_noun` with the service as prefix
- Test helper functions (in test scripts): lowercase short names — `pass()`, `fail()`, `step()`
- Global configuration: `SCREAMING_SNAKE_CASE` (`COOLIFY_URL`, `DOPPLER_ACCOUNT`, `SERVER_ALIAS`)
- Local variables in functions: `local lower_snake_case`
- Loop variables: `UPPER_SNAKE_CASE` when they derive from config, `lower_snake_case` otherwise
- UUID variables: `NOUN_UUID` suffix (`APP_UUID`, `PROJECT_UUID`, `SERVER_UUID`)
- Timestamp/counters in tests: `PASS`, `FAIL`, `RESULTS`
- Double-brace `{{UPPER_SNAKE_CASE}}` in `.tmpl` files (`{{PROJECT}}`, `{{SERVER}}`, `{{ENV_VARS_LIST}}`)
## Error Handling
- `exit 1` after every `echo "ERROR: ..." >&2` line
- Error messages always name the offending field: `"ERROR: $YAML_PATH not found"`, not `"file not found"`
- `validate.sh` collects errors via an `ERRORS` counter and `fail()` function before early exit:
- `provision.sh` and `init.sh` abort immediately on first error (no accumulation)
- `doppler_check_key` uses return code `2` to distinguish placeholder values from missing keys — non-zero means failure, `2` specifically means "present but `TODO_REPLACE_BEFORE_DEPLOY`"
- Non-critical failures use `|| true` to continue: `doppler_cmd ... || true`
- Optional API calls use `2>/dev/null || echo ""` fallback pattern
## Python Inline Scripting
- YAML parsing (PyYAML, never shell text munging for YAML)
- JSON manipulation
- Multi-field extraction from structured data
- `init.sh` uses Python for template rendering (not `sed`) to handle multiline values robustly — see `init/init.sh` lines 93-116
## YAML Conventions
- Every field has a `# CHANGE:` or `# LEAVE:` prefix comment explaining intent
- Multiline explanations use multiple `#` lines above the key
- Template uses `{{DOUBLE_BRACE}}` tokens, not `$SHELL` interpolation
- All generated YAML is validated with `python3 -c "import yaml; yaml.safe_load(open(...))"` immediately after generation
- Both `coolify.yaml` and `.github/workflows/deploy.yml` are validated after generation
## Generated File Headers
## Commit Message Convention
- `type`: `feat`, `fix`, `docs`, `test`, `chore`
- `scope`: optional, uses sprint-day notation `(08-04)` for dated changes, or filename slug
- `description`: imperative, lowercase, present tense
- `detail` after ` — `: expands on what/why, used when the subject alone is insufficient
## Documentation Conventions
- Section dividers use `# ── Section name ──────...─` (em-dash + underscores) for visual grouping in longer scripts
- Example from `test/e2e.sh`:
- Step labels use `# ── Step N: description ──` convention
- All `.md` docs have a single `#` H1, then `##` sections — no deeper than `###`
- Usage blocks always show the exact command first, then explanation
- Prerequisites listed explicitly before usage, never implied
## Idempotency Convention
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- No build step, no runtime daemon — the skill is executed procedurally by Claude on demand
- All domain-specific values are external to the skill (in `coolify.yaml` per-repo and `~/.claude/coolify.json` per-machine); the scripts contain zero hardcoded project names, URLs, or credentials
- Idempotent by design — every provisioning operation is a lookup-then-create-if-missing; re-running is safe
- Same-image promotion model: one Docker image is built, deployed to staging, smoke-tested, then promoted to production by pointer change (no rebuild)
## Layers
- Purpose: Claude Code reads `SKILL.md` to understand how to invoke the skill and which subcommand to route to
- Location: `SKILL.md`
- Contains: Skill metadata (`name`, `allowed-tools`, `argument-hint`), routing logic description, execution flow spec
- Depends on: Nothing — read by Claude, not executed
- Used by: Claude Code session when user runs `/setup-coolify [init|validate]`
- Purpose: High-level workflow controllers that sequence API calls and validate state
- Location: `scripts/provision.sh`, `scripts/validate.sh`, `scripts/generate-workflow.sh`
- Contains: YAML parsing (via inline `python3`), control flow, error handling, SSH calls
- Depends on: `scripts/lib-coolify-api.sh`, `scripts/lib-doppler-api.sh`, `~/.claude/coolify.json`, `./coolify.yaml`
- Used by: Claude (via `SKILL.md` instructions), `init/init.sh`, `test/e2e.sh`
- Purpose: Reusable Bash functions wrapping Coolify REST API and Doppler CLI
- Location: `scripts/lib-coolify-api.sh`, `scripts/lib-doppler-api.sh`
- Contains: `coolify_curl`, `coolify_upsert_project`, `coolify_find_app_by_name`, `coolify_set_app_envs`, `coolify_deploy_app`, `doppler_check_key`, `doppler_create_service_token`
- Depends on: `curl`, `doppler` CLI, `python3`, `~/.claude/coolify.json`
- Used by: `provision.sh`, `validate.sh`, `generate-workflow.sh`, `test/e2e.sh`
- Purpose: Interactive one-time setup for a new target repo — generates `coolify.yaml` and `.github/workflows/deploy.yml` from templates
- Location: `init/init.sh`, `init/templates/coolify.yaml.tmpl`
- Contains: Prompts for project parameters, Python-based template rendering, calls to `generate-workflow.sh`
- Depends on: `init/templates/coolify.yaml.tmpl`, `scripts/generate-workflow.sh`, Python3 + PyYAML
- Used by: Human operator (run once per new repo)
- Purpose: GitHub Actions workflow that implements the build-once / deploy-twice pipeline
- Location: Written to `<target-repo>/.github/workflows/deploy.yml` by `generate-workflow.sh`
- Contains: `build` job (Docker build + push to GHCR), `deploy-staging` job, `deploy-production` job (triggered only after staging smoke test), `ghcr-cleanup` job
- Depends on: `COOLIFY_API_KEY` GitHub secret, Coolify app UUIDs embedded at generation time from `coolify_app_ids` in `coolify.yaml`
- Used by: GitHub Actions on every push to `main`
## Data Flow
- `coolify_app_ids` in `coolify.yaml` is the only mutable state owned by this skill — written by `provision.sh` after first successful run to cache UUIDs and avoid repeated API lookups
- `~/.claude/coolify.json` is immutable from the skill's perspective (written only by `/setup-coolify init`)
- All other state lives in Coolify (app configs, deployment records) and Doppler (secret values, service tokens)
## Key Abstractions
- Purpose: Decouples repo config (`coolify.yaml`) from machine credentials (`~/.claude/coolify.json`). `server: vultr-stream` in `coolify.yaml` maps to the full URL, API key, Doppler account, and SSH host in `coolify.json`
- Pattern: String key lookup in `~/.claude/coolify.json servers` object
- Functions: `coolify_load_server "$SERVER_ALIAS"` (sets `COOLIFY_URL`, `COOLIFY_API_KEY`), `doppler_load_account "$SERVER_ALIAS"` (sets `DOPPLER_ACCOUNT`)
- Purpose: Makes scripts portable across Coolify instances and resilient to manual changes in the Coolify UI
- Pattern: `coolify_find_app_by_name "$APP_NAME"` returns UUID or empty string; caller creates if empty
- Applied to: project UUID, server UUID, destination UUID, app UUID
- Purpose: Ensures staging and production run byte-identical Docker images; prevents the "works on staging, breaks on prod" class of bugs caused by environment-specific builds
- Constraint: No `--build-arg` may reference env-specific values. `generate-workflow.sh` includes a guard that exits with error if `NEXT_PUBLIC_BASE_URL` appears as a build-arg in the generated YAML.
## One-Time Setup Flow
| Step | Action |
|------|--------|
| ① | `git clone claude-skills-deploy → ~/.claude/skills/setup-coolify/` |
| ② | Configure `~/.claude/coolify.json` (Coolify URL, API key, Doppler account, ssh_host) |
| ③ | `bash init/init.sh` in target repo → writes `coolify.yaml` + `.github/workflows/deploy.yml` |
| ④ | Create Doppler project + `staging`/`production` configs + seed secrets (**browser step**) |
| ⑤ | `/setup-coolify validate` — dry-run; no mutations |
| ⑥ | `/setup-coolify` — provisions Coolify apps, creates Docker volumes, wires Doppler tokens, writes back UUIDs |
| ⑦ | `git add coolify.yaml deploy.yml && git push` — activates GitHub Actions pipeline |
## What Lives Where After Setup
| Location | Contents | Committed? |
|----------|----------|-----------|
| `~/.claude/skills/setup-coolify/` | Skill files (SKILL.md, scripts, init, docs) | No — local install |
| `~/.claude/coolify.json` | Coolify URL + API key + Doppler account + `ssh_host` | **Never** — contains secrets |
| `<target-repo>/coolify.yaml` | Deploy manifest: project slug, server alias, domains, env var names | **Yes** — no secrets |
| `<target-repo>/.github/workflows/deploy.yml` | GitHub Actions pipeline (build → GHCR → Coolify) | **Yes** |
| GHCR | Docker images tagged by git SHA; last N tags retained | N/A |
| Coolify (VPS) | Staging + production apps with `DOPPLER_TOKEN` env var | N/A |
| Doppler | Project with `staging` + `production` configs; service tokens per env | N/A |
## Entry Points
- Location: `SKILL.md` + `scripts/provision.sh`
- Triggers: Claude Code user runs `/setup-coolify` with no arguments
- Responsibilities: Full idempotent provisioning — validate, upsert Coolify resources, create Docker volumes, wire Doppler tokens, write back UUIDs, trigger deploys
- Location: `SKILL.md` + `scripts/validate.sh`
- Triggers: Claude Code user runs `/setup-coolify validate`
- Responsibilities: Dry-run pre-flight — schema check, server alias lookup, Coolify API ping, Doppler key presence check. No mutations.
- Location: `SKILL.md`
- Triggers: Claude Code user runs `/setup-coolify init`
- Responsibilities: Interactive prompts to create/update `~/.claude/coolify.json` for a new server alias. Claude executes this directly without calling a script.
- Location: `init/init.sh`
- Triggers: Human runs `bash ~/.claude/skills/setup-coolify/init/init.sh` from target repo root
- Responsibilities: Prompts for project parameters, renders `coolify.yaml.tmpl`, calls `generate-workflow.sh`, validates output YAML
- Location: `test/e2e.sh`
- Triggers: Human or CI runs `bash test/e2e.sh [--server ALIAS] [--keep]`
- Responsibilities: Full end-to-end test — creates throwaway Coolify + Doppler project, provisions apps, deploys, smoke-tests live HTTPS URL, unconditional cleanup via `trap EXIT`
## Error Handling
- `set -euo pipefail` in all scripts — any unhandled non-zero exit propagates immediately
- `validate.sh` accumulates errors into a counter and prints all failures before exiting — gives the operator a complete list rather than stopping at the first missing key
- `provision.sh` runs `validate.sh` as its first step and aborts before touching Coolify if validation fails
- Volume mount round-trip verification: `provision.sh` reads back `custom_docker_run_options` after PATCH and hard-fails if the mount string is absent (Coolify version compatibility guard)
- `init.sh` validates generated YAML with `python3 yaml.safe_load` and checks for unsubstituted `{{` tokens before writing output
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD 1.x Workflow Enforcement

Do NOT use the `gsd` CLI tool (which belongs to GSD 2.x). Instead, strictly follow the GSD 1.x workflows defined in `~/.claude/get-shit-done/workflows/` (such as `execute-plan.md`, `discuss-phase.md`, `plan-phase.md`, etc.) for all planning, discussion, and execution.

For all execution:
1. **Load Context**: Read `.planning/STATE.md` at startup to load project context.
2. **Step Sequencing**: Sequentially follow the tasks in the active `*-PLAN.md` file under `.planning/phases/`.
3. **Task Gates**: Perform the mandatory `<read_first>` file reads before editing, and verify all `<acceptance_criteria>` upon task completion.
4. **State Management**: Update GSD 1.x project state, roadmap, and requirements exclusively using the helper script:
   `node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs"` (e.g., `state advance-plan`, `roadmap update-plan-progress`, `requirements mark-complete`).
5. **Commit Protocol**: After verifying each task, stage files individually and commit using the format: `{type}({phase}-{plan}): {description}`.
6. **Plan Summary**: Create `{phase}-{plan}-SUMMARY.md` in the phase directory upon completion.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
