# Upgrade Governance — CSD Deployment Drift

## Background

This document captures the architectural decisions made in June 2026 around keeping
target-repo deployments in sync with improvements in claude-skills-deploy (CSD).

The trigger was discovering that Coolify apps on several target repos had stale env
vars (e.g. `OPENAI_API_KEY`, `DATABASE_URL`) set directly in Coolify, silently
overriding the correct values from Doppler. This was the origin of **INV-01** (see
`docs/invariants.md`).

---

## The Upgrade Surface — Three Layers

Not all parts of a CSD-managed deployment need the same upgrade mechanism.

| Layer | What it is | How it stays current |
|-------|-----------|----------------------|
| **CSD scripts** | `provision.sh`, `validate.sh`, `lib-*.sh` (in `~/.claude/skills/setup-coolify/`) | Always current — scripts are never copied into target repos; every invocation uses the latest version |
| **Generated artifacts** | `deploy.yml` in each target repo | Regenerated on every `/setup-coolify` run (provision.sh step 4) — re-running the skill always refreshes this |
| **External state** | Coolify app config, Doppler token wiring, Docker volumes | Provision is idempotent — re-running applies current desired state (adds missing, removes stale) |

The implication: **the core upgrade mechanism is already "re-run provision."** Scripts are
always the latest version, and provision regenerates generated files and re-syncs external
state on every run.

The gap is not the mechanism — it is:
1. **Operators don't know when to re-run** (no signal from CSD that something changed)
2. **Ground rules lived in prose, not enforcement code** (the stale-vars rule was documented
   in architecture docs but never checked by validate.sh or provision.sh)
3. **No continuous monitoring** between provision runs (drift could accumulate for months)

---

## What Validate Does (and Doesn't)

`validate.sh` is a pre-flight check. It:
- Verifies coolify.yaml schema
- Checks Coolify API reachability
- Confirms all env_vars exist in Doppler (FAIL, blocking)
- Checks SSH connectivity
- Warns about missing coolify.json fields

Before this work, it did NOT:
- Check what env vars are actually set in live Coolify apps (only Doppler)
- Detect invariant violations in already-provisioned apps

After this work, validate also:
- Queries `/applications/{uuid}/envs` for each provisioned app (from coolify_app_ids)
- WARNs (non-blocking) if any key other than `DOPPLER_TOKEN` is found (INV-01)

It warns rather than fails because provision.sh can fix the violation — blocking provision
would prevent the fix.

---

## Skills-Based Approach vs. Deploy Product

During this discussion, the question arose: does the skills-based approach require more
maintenance than a separate deploy "product" (a central service managing all deployments)?

**Honest assessment:**

The skills approach has a structural weakness around *ongoing governance*:
- Rules are only enforced at invocation time — stable deployments can go months without a
  provision re-run
- There is no central registry of which repos use CSD, so "sweep all deployments" requires
  visiting each repo individually
- When a new ground rule is discovered, there is no push mechanism — operators must know to
  re-run the skill

**But a deploy product doesn't eliminate these problems — it displaces them:**
- The product itself must be maintained, deployed, and monitored
- The "new ground rule needs propagating" problem still exists in the product's codebase
- Central credential storage (to connect to all Coolify instances) adds a new attack surface
- For a small number of repos (< ~20), the per-repo maintenance burden is likely lower than
  the overhead of operating a central product

**What the skills approach needs (and what was added):**

The missing piece is **continuous monitoring between provision runs**. The additions in this
work address that without building a new service:

1. **Invariants in code, not prose** — validate.sh now checks live Coolify state (INV-01)
2. **Active enforcement in provision.sh** — stale vars are removed, not just reported
3. **Scheduled CI job** — the generated `deploy.yml` includes a weekly `drift-check` job
   that queries Coolify directly and fails CI if invariants are violated. This runs
   automatically in every target repo without any operator action beyond the next `/setup-coolify` run.

**What a deploy product would add that this doesn't:**

A push notification when a new invariant is added to CSD — operators can't see
"there's a new rule you should know about" unless they pull CSD updates and read the changelog.
The mitigation here is disciplined use of `[ACTION REQUIRED]` in `CHANGELOG.md` for any change
that requires a re-run of `/setup-coolify` on existing deployments.

---

## When to Upgrade an Existing Target Repo

**Always safe to re-run `/setup-coolify` at any time** — provision is idempotent. Re-running:
- Applies any new invariant enforcement (e.g. removes stale Coolify vars)
- Regenerates `deploy.yml` with the latest workflow template (including the new drift-check job)
- Re-syncs Coolify app settings to desired state
- Does NOT restart running containers unless you `git push` afterward

**Signals that a re-run is needed** (in priority order):
1. `drift-check` CI job fails (requires no action other than seeing the failure)
2. `CHANGELOG.md` entry tagged `[ACTION REQUIRED]` in a CSD update you pull
3. `validate.sh` warns about INV-01 when you run it manually

**Env var changes (e.g. switching from ANTHROPIC to OPENROUTER):**
This is NOT a CSD upgrade — it's a Doppler + redeploy workflow:
1. Add new key to Doppler staging and production (browser — new secret values require UI)
2. Update `env_vars` in `coolify.yaml` (source of truth for which keys the app expects)
3. Run `/setup-coolify validate` to confirm the new key is in Doppler
4. Trigger a redeploy in Coolify (the container fetches all secrets from Doppler at start)
5. Remove old key from Doppler once confirmed working
No `/setup-coolify` re-run needed — Coolify never held the key value directly.

---

## Testing Upgrade Behavior

The correct test for "does the upgrade work?" is not just "does E2E pass after the change?"
It is: **does provision detect and fix a violation that existed before the change?**

The E2E test (`test/e2e.sh`) now includes **Step 5b** which exercises this:
1. After provisioning a fresh deployment (Step 5), injects a stale env var via Coolify API
2. Runs `validate.sh` — expects an INV-01 warning
3. Runs `provision.sh` — expects the stale var to be deleted
4. Runs `validate.sh` again — expects a clean result

This step runs on every E2E execution, so any regression in INV-01 enforcement is caught
automatically.

For testing upgrade behavior on an existing deployment (not E2E):
1. Manually inject a stale env var via Coolify API or UI
2. Run `/setup-coolify validate` — should WARN about INV-01
3. Run `/setup-coolify` — should remove it and report "INV-01 enforced: removed N stale var(s)"
4. Run `/setup-coolify validate` — should show "INV-01 OK"

---

## Changelog Convention for Upgrade-Affecting Changes

Any CSD change that requires operators to re-run `/setup-coolify` on existing deployments
must be tagged in `CHANGELOG.md`:

```
## [ACTION REQUIRED] — short description of what operators must do

Target repos: all / repos using feature X
Action: run /setup-coolify in each affected repo
Why: explanation of what breaks if they don't
```

This is the lightweight "push signal" in the absence of a central registry.
