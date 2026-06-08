# Fork Guide: Adapting for a New Domain

How to use this skill for a new domain. The short answer: you almost certainly do NOT
need to fork the repository. You only need to change configuration.

---

## When to fork vs. just configure (Multi-Domain Rules)

To manage deployments across different domains and organizations without documentation circularity, follow these three simple rules:

1. **Same-Domain Development (e.g. `streamlinity.com`):** A direct **clone** of the upstream repository (`Streamlinity/claude-skills-deploy`) is the correct approach. No fork is needed.
2. **First Repo in a Different Domain/Org (e.g. `strategem.ai`):** You should **fork** `claude-skills-deploy` to your organization's GitHub namespace. This establishes a master copy where you can:
   * Customize the generated GitHub Actions deploy workflows (`init/deploy.yml.template`) to match the new domain's compliance, build systems, or security rules.
   * Modify bootstrapper defaults (e.g., in `init/init.sh`) so developers aren't entering the same server arguments repeatedly during setup.
3. **Subsequent Repos in the Same New Domain:** These do **not** require new forks. Developers or CI systems simply **clone** your organization's existing fork.

For a developer working on a second domain under their own account, simple configuration changes (no fork) is all that is required. For organization-wide standards, forking for the first repo is the recommended pathway.

---

## Configuration delta for a new domain (no fork required)

The complete set of changes when adapting to a new domain:

| Item | Where it lives | What changes |
|------|----------------|--------------|
| `server:` in coolify.yaml | Per-repo, committed | New alias name (e.g. `hetzner-strategem`) |
| `environments.*.domain` in coolify.yaml | Per-repo, committed | New domains (e.g. `staging.strategem.ai`) |
| `registry.image` in coolify.yaml | Per-repo, committed | New GHCR org/repo path |
| `~/.claude/coolify.json` entry | Machine-local, never committed | New URL, API key, doppler_account, ssh_host |
| Doppler project | Doppler dashboard | New project (potentially new workspace) |
| SSH alias | `~/.ssh/config` | New entry for new Coolify server |

Everything in the scripts (`lib-coolify-api.sh`, `provision.sh`, `generate-workflow.sh`,
`validate.sh`) is already domain-agnostic. **Zero script changes required.**

---

## Concrete walkthrough: strategem.ai

This section walks through deploying `strategem-website` (at `www.strategem.ai`) using
the same skill. All values are concrete — no `<placeholder>` ambiguity.

### Step 1 — Stand up the Coolify instance (or reuse existing)

If the strategem org already has a Coolify instance running, skip this step. Otherwise
follow [docs/setup-guide.md Step 1](./setup-guide.md#step-1-stand-up-a-coolify-instance)
to provision a new VPS and install Coolify.

For this example the Coolify instance will be at `https://coolify.cicd.strategem.ai`
on a Hetzner server.

### Step 2 — Add the new server entry to ~/.claude/coolify.json

Extend your existing `~/.claude/coolify.json` with a new server entry. Do NOT replace
the existing entry — multiple server entries coexist in the same file:

```json
{
  "servers": {
    "vultr-stream": {
      "url": "https://coolify.cicd.streamlinity.com",
      "api_key": "<existing streamlinity key>",
      "doppler_account": "streamlinity",
      "ssh_host": "v_cicd_stream"
    },
    "hetzner-strategem": {
      "url": "https://coolify.cicd.strategem.ai",
      "api_key": "<from strategem Coolify UI>",
      "doppler_account": "strategem",
      "ssh_host": "hetzner-strategem"
    }
  }
}
```

```bash
chmod 0600 ~/.claude/coolify.json
```

Or use the interactive flow: `/setup-coolify init` — it merges the new entry without
overwriting existing ones.

### Step 3 — Add the SSH alias to ~/.ssh/config

```
Host hetzner-strategem
  HostName <ip-of-hetzner-vps>
  User root
  IdentityFile ~/.ssh/id_ed25519
```

Confirm it works:
```bash
ssh -o BatchMode=yes hetzner-strategem 'echo ok'
```

### Step 4 — Authenticate Doppler for the strategem workspace

```bash
doppler login    # follow browser prompts, select the strategem workspace
doppler projects create strategem-website
```

Or create the project via the Doppler dashboard. Then verify the `stg` and
`prd` configs exist (Doppler's actual defaults):
```bash
doppler configs --project strategem-website
```

### Step 5 — Bootstrap coolify.yaml + deploy.yml in the strategem-website repo

```bash
cd ~/development/strategem/website
bash ~/.claude/skills/setup-coolify/init/init.sh
```

The init.sh script writes BOTH `coolify.yaml` AND `.github/workflows/deploy.yml` in one
command. When prompted, answer:

- **Project name:** `strategem-website`
- **Server alias:** `hetzner-strategem`
- **Doppler project:** `strategem-website`
- **Registry image:** `ghcr.io/StrategemAI/strategem-website`
- **Staging domain:** `staging.strategem.ai`
- **Production domain:** `www.strategem.ai`
- **Build context:** `.` (strategem-website has the app at repo root — default)
- **Dockerfile:** `./Dockerfile` (default)
- **Env var keys:** `DATABASE_URL OPENAI_API_KEY STRIPE_SECRET_KEY` (strategem-specific keys)

### Step 6 — Seed Doppler secrets

```bash
doppler secrets set --project strategem-website --config stg DATABASE_URL=postgres://...
doppler secrets set --project strategem-website --config stg OPENAI_API_KEY=sk-...
doppler secrets set --project strategem-website --config prd DATABASE_URL=postgres://...
doppler secrets set --project strategem-website --config prd OPENAI_API_KEY=sk-...
```

Repeat for every key your application needs in both configs.

### Step 7 — Validate + provision

```bash
/setup-coolify validate    # dry-run: checks Doppler keys + Coolify API
/setup-coolify             # provisions staging + production apps
```

### Step 8 — Commit and push

```bash
git add coolify.yaml .github/workflows/deploy.yml
git commit -m "ci: add Coolify deploy pipeline"
git push
```

Push to `main` triggers: build → GHCR → staging deploy → smoke test → production deploy.

---

## Resulting strategem-website/coolify.yaml

The final `coolify.yaml` written by init.sh and committed to the `strategem-website`
repo. Notice that only the config values differ from the skillmap reference — the
structure and all script behavior are identical:

```yaml
project: strategem-website
server: hetzner-strategem
doppler_project: strategem-website

registry:
  image: ghcr.io/StrategemAI/strategem-website
  retention_tags: 5

build:
  context: .
  dockerfile: ./Dockerfile

environments:
  staging:
    domain: staging.strategem.ai
    doppler_environment: stg
  production:
    domain: www.strategem.ai
    doppler_environment: prd

env_vars:
  - DATABASE_URL
  - OPENAI_API_KEY
  # add strategem-specific keys here

coolify_app_ids:
  staging: ~
  production: ~
```

Zero script changes between skillmap and strategem-website. The only diff is config.

Compare with the skillmap reference at `examples/skillmap/coolify.yaml` — the schema is
identical, only the values differ. This is the design intent.

---

## When you DO want a true fork

Fork the repository if you need any of the following:

- **Custom lib functions** — e.g., a new Coolify API wrapper that conflicts with the
  upstream design direction
- **Different init.sh defaults** — e.g., your org always uses a specific Doppler account
  slug as the default suggestion
- **A different skill name** — e.g., you want `/setup-strategem-coolify` instead of
  `/setup-coolify` to avoid naming conflicts if both skills are installed simultaneously

Steps to fork:

1. Fork the repo on GitHub:
   ```bash
   gh repo fork Streamlinity/claude-skills-deploy --org StrategemAI --clone
   ```

2. Clone YOUR fork into the skill directory (not upstream):
   ```bash
   git clone git@github.com:StrategemAI/claude-skills-deploy.git ~/.claude/skills/setup-coolify
   ```

3. If you want a different skill name, edit `SKILL.md` and change the `name:` field in
   the frontmatter. Claude Code uses this as the invocation name.

4. Push changes to your fork. To pull upstream updates:
   ```bash
   git remote add upstream git@github.com:Streamlinity/claude-skills-deploy.git
   git fetch upstream && git merge upstream/main
   ```

---

## Next Steps

- **Return to the Setup Guide:** Go back to **[docs/setup-guide.md](./setup-guide.md)** to continue bootstrapping your application repositories.
- **Review Field Schemas:** Refer to **[docs/schema.md](./schema.md)** for a full field-by-field reference of `coolify.yaml` and `coolify.json`.
