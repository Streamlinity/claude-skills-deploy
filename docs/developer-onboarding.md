# Developer Onboarding

How to get secrets working locally when you join a project that already uses this
skill. The infrastructure (Coolify, Doppler project, GitHub Actions) is already running
— you just need to wire up your laptop.

This guide is for **team members joining an existing project**. If you are setting up
Coolify + Doppler for the first time, start with
[docs/setup-guide.md](./setup-guide.md) instead.

---

## What you need (and what you don't)

**You need:**
- Doppler CLI installed and authenticated
- Access to the team's Doppler project (ask the operator to invite you)

**You do not need:**
- `~/.claude/coolify.json` — that file is only for the person running `/setup-coolify`
- Access to the Coolify dashboard
- A `.env.local` file — Doppler replaces it

---

## Step 1: Install the Doppler CLI

```bash
curl -Ls --tlsv1.2 --proto "=https" https://cli.doppler.com/install.sh | sh
doppler --version   # 3.76.0 or later
```

---

## Step 2: Authenticate

```bash
doppler login
```

This opens a browser OAuth flow. Complete it and return to the terminal. Your
credentials are stored at `~/.doppler/.doppler.yaml` and persist across sessions.

---

## Step 3: Connect the repo to Doppler

Run this once from the repo root:

```bash
doppler setup
```

The CLI prompts you to select the project and config. For local development, choose:
- **Project:** the project slug (same as the `doppler_project` value in `coolify.yaml`)
- **Config:** `dev` (shared team defaults) or `dev_personal` (your personal overrides)

This writes a `.doppler.yaml` file at the repo root that records the project + config
selection. The file is already in `.gitignore` — it is per-developer and not committed.

> If `doppler setup` does not list the project, you have not been invited to it yet.
> Ask the operator to add you via Doppler → Your Project → Team → Invite.

---

## Step 4: Run the app with secrets injected

Instead of sourcing a `.env` file, prefix your start command with `doppler run`:

```bash
doppler run -- npm run dev
doppler run -- python manage.py runserver
doppler run -- go run ./cmd/server
```

Doppler fetches all secrets from the `dev` config and injects them as environment
variables into the child process. No file is written to disk.

---

## Step 5: Personal overrides with dev_personal

`dev_personal` inherits all values from `dev` but lets you override individual keys
without affecting your teammates. Use it for things like a local database URL,
a personal API key for a third-party service, or a feature flag you want to flip
independently.

Switch your local setup to `dev_personal`:

```bash
doppler setup   # re-run and select dev_personal this time
```

Set a personal override:

```bash
doppler secrets set DATABASE_URL="postgresql://localhost/myapp_local"
```

The override is scoped to `dev_personal`. Everyone else on `dev` is unaffected.

To check which config your repo is currently pointing at:

```bash
doppler configure
```

---

## Working with tools that require a .env file

Some tools (certain IDE plugins, `docker compose`, legacy scripts) read a `.env` file
and cannot use `doppler run`. Export secrets to a file on demand:

```bash
doppler secrets download --format env --no-file > .env.local
```

Run this whenever secrets change. Do not commit `.env.local` — it should already be
in `.gitignore`. Treat it as a local cache of Doppler secrets, not a source of truth.

---

## Checking what secrets are available

List all keys and values in your active config:

```bash
doppler secrets
```

Check a single key:

```bash
doppler secrets get DATABASE_URL
```

See which project + config is active for the repo:

```bash
doppler configure
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `doppler run` exits with `project not found` | Not invited to the Doppler project | Ask operator to invite you via Doppler dashboard |
| App starts but env vars are missing | `.doppler.yaml` in repo points to wrong config | Re-run `doppler setup` and select `dev` or `dev_personal` |
| `doppler login` succeeds but `doppler setup` lists no projects | Authenticated to wrong Doppler account | Run `doppler logout`, then `doppler login` with the correct account |
| Secret value is stale | You exported to `.env.local` and haven't refreshed | Re-run `doppler secrets download --format env --no-file > .env.local` |
| `doppler run` returns error: `config not found: dev_personal` | Your account has not been added to the Doppler project yet | Use `dev` config until the operator invites you; then switch to `dev_personal` |
