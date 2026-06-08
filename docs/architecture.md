# Architecture & Setup Flow

Two repos and three external services work together to produce a same-image-promotion CI/CD pipeline. This document shows what you build and how the pieces connect.

---

## One-time setup flow

Run through these steps once per domain. Steps ①–③ and ⑤–⑦ are CLI commands; only step ④ (creating the Doppler project) requires a browser.

```
┌─── ① Install skill ─────────────────────────────────────────────────────┐
│  • Clone Streamlinity/claude-skills-deploy to                           │
│    ~/.claude/skills/setup-coolify/                                      │
│  • (Or fork first on GitHub if customizing scripts / workflow templates)│
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ② Configure machine credentials ─────────────────────────────────────┐
│  File: ~/.claude/coolify.json                                           │
│  • Coolify URL                                                          │
│  • API key                                                              │
│  • ssh_host  (alias in ~/.ssh/config)                                   │
│  • Doppler account                                                      │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ③ Bootstrap your app repo ───────────────────────────────────────────┐
│  bash ~/.claude/skills/setup-coolify/init/init.sh                       │
│  Writes two files:                                                      │
│  • coolify.yaml                 — deploy manifest, safe to commit       │
│  • .github/workflows/deploy.yml — CI pipeline                           │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ④ Create Doppler project  ⚠ browser step ────────────────────────────┐
│  • New project at dashboard.doppler.com                                 │
│  • Create two configs: staging · production                             │
│  • Add all secrets listed in coolify.yaml env_vars                      │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ⑤ Dry-run validate ──────────────────────────────────────────────────┐
│  /setup-coolify validate                                                │
│  • Checks Coolify API reachability                                      │
│  • Verifies every Doppler secret exists in staging + production         │
│  • No mutations                                                         │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ⑥ Provision ─────────────────────────────────────────────────────────┐
│  /setup-coolify                                                         │
│  • Coolify staging app created                                          │
│  • Coolify production app created                                       │
│  • Doppler service tokens generated + wired as DOPPLER_TOKEN            │
│  • Docker volume created on VPS for Doppler fallback cache              │
│  • App UUIDs written back to coolify.yaml                               │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─── ⑦ Go live ───────────────────────────────────────────────────────────┐
│  git add coolify.yaml .github/workflows/deploy.yml                      │
│  git commit -m 'ci: add Coolify deploy pipeline'                        │
│  git push                                                               │
│  GitHub Actions pipeline is now active                                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## End-state component architecture

Seven components work together once setup is complete. The overview below shows how they connect; the pipeline detail that follows zooms into the runtime deploy loop.

### Overview

```
  ┌─────────────────────┐  install   ┌──────────────────────────────────┐
  │     Skill Repo      │ ──────────▶│        Developer Machine         │
  │  claude-skills-     │            │  ~/.claude/skills/setup-coolify/ │
  │  deploy             │            │  ~/.claude/coolify.json          │
  └─────────────────────┘            └──────┬──────────┬────────────────┘
                                  generates │          │ provision
                                  (init.sh) │          │
                     ┌──────────────────────┘          │
                     ▼                                 │
  ┌─────────────────────┐                              │
  │      App Repo       │  git push                    │
  │  your-org/your-app  │ triggers                     ▼
  │  coolify.yaml       │ ──────────▶ ┌────────────────────────────────┐
  │  deploy.yml         │             │       GitHub Actions (CI)      │
  └─────────────────────┘             └────────┬────────────┬──────────┘
                                   push image  │            │ deploy API
                                               ▼            │
                                    ┌──────────────┐        │
                                    │     GHCR     │        │
                                    │ image registry│       │
                                    └──────┬───────┘        │
                                 pull image│                │
                                           ▼                ▼
  ┌─────────────────────┐         ┌──────────────────────────────────────┐
  │      Doppler        │ inject  │             Coolify  (VPS)           │
  │      secrets        │ secrets▶│  staging.example.com                 │
  └─────────────────────┘         │  your-app.example.com                │
                                  └──────────────────────────────────────┘
```

**What lives in each component:**

| Component | Contents |
|-----------|----------|
| **Skill Repo** | Upstream repository (Streamlinity/claude-skills-deploy) containing `SKILL.md`, `scripts/`, `init/`, `docs/`, `references/` |
| **Developer Machine** | `~/.claude/skills/setup-coolify/` (installed skill) · `~/.claude/coolify.json` (Coolify URL, API key, Doppler account, ssh_host) |
| **App Repo** | `coolify.yaml` (deploy manifest, committed, no secrets) · `.github/workflows/deploy.yml` (CI pipeline, committed) |
| **GitHub Actions** | Build job · deploy-staging job · smoke-test · deploy-production job (see pipeline detail below) |
| **GHCR** | Docker images tagged by git SHA — `your-app:abc1234`, `your-app:def5678`, … |
| **Coolify** | Staging app (`your-app-staging.example.com`) · Production app (`your-app.example.com`) · both with `DOPPLER_TOKEN` env var |
| **Doppler** | One project per app · `stg` config with service token A · `prd` config with service token B |

---

### Runtime pipeline detail

Every `git push` to `main` triggers this sequence. The image is built **once** and the same tag is promoted to production — no rebuild.

```
git push → main
    │
    ▼
┌─── GitHub Actions ───────────────────────────────────────────────────────┐
│                                                                          │
│  [1] build                                                               │
│      • docker build, tag sha-abc1234                                     │
│      • push sha-abc1234 → GHCR                               ┌─────────┐ │
│                                    image stored ──────────▶  │  GHCR   │ │
│           │                                                  │ sha-abc │ │
│           ▼                                                  └────┬────┘ │
│  [2] deploy-staging                                               │      │
│      • PATCH staging app → sha-abc1234                            │      │
│      • trigger Coolify deploy, poll until running                 │      │
│           │                                                       │      │
│           ▼                                                       │      │
│  [3] smoke-test                                                   │      │
│      • GET /api/health → HTTP 200 required to continue            │      │
│           │                                                       │      │
│           ▼                                                       │      │
│  [4] deploy-production                                            │      │
│      • PATCH production app → sha-abc1234  (same image, no rebuild)      │
│      • trigger Coolify deploy, poll until running                 │      │
│                                                                   │      │
└───────────────────────────────────────────────────────────────────┼──────┘
         │ deploy API                    │ deploy API               │ image pull
         ▼                              ▼                           ▼
┌─────────────────────┐    ┌───────────────────────┐       (same image
│  Coolify — staging  │    │  Coolify — production │        for both)
│  staging.example.com│    │  your-app.example.com │
└─────────────────────┘    └───────────────────────┘
         ▲                              ▲
         └──────────── Doppler ─────────┘
              DOPPLER_TOKEN set on each app
              secrets injected at container start
```

---

## What lives where after setup

| Location | Contents | Committed? |
|----------|----------|-----------|
| `~/.claude/skills/setup-coolify/` | Skill files — `SKILL.md`, `scripts/`, `init/`, `docs/` | No — local install |
| `~/.claude/coolify.json` | Coolify URL + API key + Doppler account + `ssh_host` | **Never** — contains secrets |
| `your-app/coolify.yaml` | Deploy manifest: project slug, server alias, domains, env var names | **Yes** — no secrets |
| `your-app/.github/workflows/deploy.yml` | GitHub Actions pipeline (build → GHCR → Coolify) | **Yes** |
| GHCR | Docker images tagged by git SHA; N most recent kept | N/A |
| Coolify (VPS) | Staging app + production app, each with `DOPPLER_TOKEN` env var | N/A |
| Doppler | One project per app; `stg` + `prd` configs with scoped service tokens | N/A |

---

## Next Steps

- Go to the [Setup Guide](./setup-guide.md) to stand up your pipeline step-by-step.
- Review the [Schema Reference](./schema.md) to understand the details of `coolify.yaml` and `coolify.json`.
