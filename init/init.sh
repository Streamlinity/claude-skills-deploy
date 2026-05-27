#!/usr/bin/env bash
# init.sh — Bootstrap a target repo with coolify.yaml AND .github/workflows/deploy.yml.
# Run from the target repo's root directory. Writes ./coolify.yaml and ./.github/workflows/deploy.yml.
# Idempotent guard: refuses to overwrite an existing coolify.yaml or existing deploy.yml.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/init/templates/coolify.yaml.tmpl"
GENERATE_WORKFLOW="$SKILL_DIR/scripts/generate-workflow.sh"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

if [ ! -f "$GENERATE_WORKFLOW" ]; then
  echo "ERROR: generate-workflow.sh not found at $GENERATE_WORKFLOW" >&2
  exit 1
fi

if [ -f "./coolify.yaml" ]; then
  echo "ERROR: ./coolify.yaml already exists in $(pwd)" >&2
  echo "Delete it first if you want to reinitialize." >&2
  exit 1
fi

if [ -f "./.github/workflows/deploy.yml" ]; then
  echo "ERROR: ./.github/workflows/deploy.yml already exists in $(pwd)" >&2
  echo "Delete it first if you want to reinitialize." >&2
  exit 1
fi

# Verify PyYAML available (needed by validate.sh / provision.sh downstream)
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "WARNING: PyYAML not installed. Install with: pip3 install pyyaml" >&2
fi

echo "=== claude-skills-deploy: bootstrap coolify.yaml + deploy.yml ==="
echo ""
echo "You will be prompted for the values that go into ./coolify.yaml."
echo "Defaults shown in [brackets]. Press Enter to accept the default."
echo ""

# Default PROJECT to the current directory name (covers 90% of cases)
DIR_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
read -rp "Project name (Coolify project + Doppler slug) [$DIR_NAME]: " PROJECT
PROJECT="${PROJECT:-$DIR_NAME}"

read -rp "Server alias (key in ~/.claude/coolify.json, e.g. vultr-stream): " SERVER
[ -n "$SERVER" ] || { echo "ERROR: server alias required" >&2; exit 1; }

read -rp "Doppler project slug [$PROJECT]: " DOPPLER_PROJECT
DOPPLER_PROJECT="${DOPPLER_PROJECT:-$PROJECT}"

# Auto-derive REGISTRY_IMAGE from the GitHub remote so users don't need to know the format.
# github.com/org/repo  →  ghcr.io/org/repo  (lowercased, no .git suffix)
ORIGIN=$(git remote get-url origin 2>/dev/null | sed 's/\.git$//' || echo "")
DERIVED_IMAGE=$(echo "$ORIGIN" | sed 's|.*github\.com[:/]||' | tr '[:upper:]' '[:lower:]')
if [ -n "$DERIVED_IMAGE" ] && [ "$DERIVED_IMAGE" != "$ORIGIN" ]; then
  DERIVED_IMAGE="ghcr.io/$DERIVED_IMAGE"
else
  DERIVED_IMAGE="ghcr.io/your-org/${PROJECT}"
fi
echo "  (GHCR image path — no tag; the CI workflow appends the git SHA tag automatically)"
read -rp "Registry image [$DERIVED_IMAGE]: " REGISTRY_IMAGE
REGISTRY_IMAGE="${REGISTRY_IMAGE:-$DERIVED_IMAGE}"

read -rp "Staging domain (no protocol) [e.g. ${PROJECT}-staging.example.com]: " STAGING_DOMAIN
[ -n "$STAGING_DOMAIN" ] || { echo "ERROR: staging domain required" >&2; exit 1; }

read -rp "Production domain (no protocol) [e.g. ${PROJECT}.example.com]: " PROD_DOMAIN
[ -n "$PROD_DOMAIN" ] || { echo "ERROR: production domain required" >&2; exit 1; }

echo ""
echo "DNS provisioning (automated A record creation — optional but recommended)."
echo "When enabled, /setup-coolify creates DNS records so Let's Encrypt can issue"
echo "certificates without a manual DNS step."
echo ""
read -rp "DNS provider for automated A record creation (cloudflare/none) [cloudflare]: " DNS_PROVIDER
DNS_PROVIDER="${DNS_PROVIDER:-cloudflare}"

if [ "$DNS_PROVIDER" = "cloudflare" ]; then
  # Derive default zone from production domain (last two labels: example.com from sub.example.com)
  DEFAULT_ZONE=$(echo "$PROD_DOMAIN" | awk -F. '{n=NF; printf "%s.%s", $(n-1), $n}')
  read -rp "DNS zone name (root zone — suffix of staging+prod domains) [$DEFAULT_ZONE]: " DNS_ZONE_NAME
  DNS_ZONE_NAME="${DNS_ZONE_NAME:-$DEFAULT_ZONE}"
  read -rp "Where is the Cloudflare API token stored? (doppler/coolify_json) [doppler]: " DNS_CREDENTIAL_SOURCE
  DNS_CREDENTIAL_SOURCE="${DNS_CREDENTIAL_SOURCE:-doppler}"
  if [ "$DNS_CREDENTIAL_SOURCE" = "doppler" ]; then
    read -rp "Doppler secret name holding the token [CLOUDFLARE_API_TOKEN]: " DNS_CREDENTIAL_KEY
    DNS_CREDENTIAL_KEY="${DNS_CREDENTIAL_KEY:-CLOUDFLARE_API_TOKEN}"
  else
    read -rp "coolify.json server field name holding the token [cloudflare_api_token]: " DNS_CREDENTIAL_KEY
    DNS_CREDENTIAL_KEY="${DNS_CREDENTIAL_KEY:-cloudflare_api_token}"
  fi
else
  # provider: none — leave zone + credential fields empty; template renders them as empty strings
  DNS_ZONE_NAME=""
  DNS_CREDENTIAL_SOURCE="doppler"
  DNS_CREDENTIAL_KEY=""
fi
echo ""

read -rp "Build context (path to Docker context relative to repo root) [.]: " BUILD_CONTEXT
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"

read -rp "Dockerfile path (relative to repo root) [./Dockerfile]: " BUILD_DOCKERFILE
BUILD_DOCKERFILE="${BUILD_DOCKERFILE:-./Dockerfile}"

read -rp "Env var keys (space-separated, e.g. DATABASE_URL ANTHROPIC_API_KEY): " ENV_VARS_INPUT
[ -n "$ENV_VARS_INPUT" ] || { echo "ERROR: at least one env var required" >&2; exit 1; }

# Build the env_vars YAML list block (each entry as "  - KEY" on its own line)
ENV_VARS_LIST=""
for k in $ENV_VARS_INPUT; do
  ENV_VARS_LIST+="  - $k"$'\n'
done
# Trim trailing newline
ENV_VARS_LIST="${ENV_VARS_LIST%$'\n'}"

# Render template via python3 for robust multiline substitution.
python3 - "$TEMPLATE" "$PROJECT" "$SERVER" "$DOPPLER_PROJECT" "$REGISTRY_IMAGE" \
                      "$STAGING_DOMAIN" "$PROD_DOMAIN" "$BUILD_CONTEXT" "$BUILD_DOCKERFILE" \
                      "$ENV_VARS_LIST" \
                      "$DNS_PROVIDER" "$DNS_ZONE_NAME" "$DNS_CREDENTIAL_SOURCE" "$DNS_CREDENTIAL_KEY" \
                      > ./coolify.yaml <<'PY'
import sys
tmpl_path = sys.argv[1]
project, server, doppler_proj, registry_img, staging_domain, prod_domain, \
    build_ctx, build_df, env_vars_list, \
    dns_provider, dns_zone_name, dns_cred_source, dns_cred_key = sys.argv[2:15]
with open(tmpl_path) as f:
    content = f.read()
subs = {
    '{{PROJECT}}': project,
    '{{SERVER}}': server,
    '{{DOPPLER_PROJECT}}': doppler_proj,
    '{{REGISTRY_IMAGE}}': registry_img,
    '{{STAGING_DOMAIN}}': staging_domain,
    '{{PROD_DOMAIN}}': prod_domain,
    '{{BUILD_CONTEXT}}': build_ctx,
    '{{BUILD_DOCKERFILE}}': build_df,
    '{{ENV_VARS_LIST}}': env_vars_list,
    '{{DNS_PROVIDER}}': dns_provider,
    '{{DNS_ZONE_NAME}}': dns_zone_name,
    '{{DNS_CREDENTIAL_SOURCE}}': dns_cred_source,
    '{{DNS_CREDENTIAL_KEY}}': dns_cred_key,
}
for tok, val in subs.items():
    content = content.replace(tok, val)
sys.stdout.write(content)
PY

# Validate the output parses as YAML
if ! python3 -c "import yaml; yaml.safe_load(open('./coolify.yaml'))" 2>/dev/null; then
  echo "ERROR: generated coolify.yaml is not valid YAML. Inspect ./coolify.yaml" >&2
  exit 1
fi

# Verify all {{ tokens were substituted
if grep -q '{{' ./coolify.yaml; then
  echo "ERROR: unsubstituted tokens remain in ./coolify.yaml:" >&2
  grep -n '{{' ./coolify.yaml >&2
  exit 1
fi

echo ""
echo "WROTE ./coolify.yaml"
echo ""

# FINAL STEP: invoke generate-workflow.sh to produce .github/workflows/deploy.yml.
# Per SKILLS-04: one command bootstraps coolify.yaml AND .github/workflows/deploy.yml.
# generate-workflow.sh accepts the coolify.yaml path as its first argument and writes
# .github/workflows/deploy.yml relative to the directory containing coolify.yaml.
echo "=== Generating .github/workflows/deploy.yml ==="
if ! bash "$GENERATE_WORKFLOW" ./coolify.yaml 2>&1; then
  echo "ERROR: generate-workflow.sh failed. coolify.yaml was written, but deploy.yml was not." >&2
  echo "After fixing the issue, rerun: bash $GENERATE_WORKFLOW ./coolify.yaml" >&2
  exit 1
fi

# Sanity: deploy.yml parses as valid YAML
if ! python3 -c "import yaml; yaml.safe_load(open('./.github/workflows/deploy.yml'))" 2>/dev/null; then
  echo "ERROR: generated .github/workflows/deploy.yml is not valid YAML. Inspect the file." >&2
  exit 1
fi

echo ""
echo "WROTE ./coolify.yaml"
echo "WROTE ./.github/workflows/deploy.yml"
echo ""
echo "Next steps (credentials only — no more files to generate):"
echo "  1. If '$SERVER' is a new Coolify server, run: /setup-coolify init"
echo "     (configures ~/.claude/coolify.json with url, api_key, doppler_account, ssh_host)"
echo "  2. Create the Doppler project '$DOPPLER_PROJECT' with stg + prd configs"
echo "     (browser flow — requires Doppler dashboard access)."
echo "     docs/setup-guide.md Step 4 has the exact commands once you've authenticated."
if [ "$DNS_PROVIDER" != "none" ] && [ -n "$DNS_CREDENTIAL_KEY" ]; then
  echo "  2b. Store the $DNS_PROVIDER API token in $DNS_CREDENTIAL_SOURCE before running validate:"
  if [ "$DNS_CREDENTIAL_SOURCE" = "doppler" ]; then
    echo "      doppler secrets set $DNS_CREDENTIAL_KEY --project $DOPPLER_PROJECT --config stg"
  else
    echo "      Add '$DNS_CREDENTIAL_KEY' to servers.$SERVER in ~/.claude/coolify.json"
  fi
  echo "      The token needs Zone:DNS:Edit scope on zone '$DNS_ZONE_NAME'."
fi
echo "  3. Run: /setup-coolify validate    (dry-run sanity check of Doppler + Coolify + DNS)"
echo "  4. Run: /setup-coolify             (provision Coolify apps + Doppler secret injection + DNS A records)"
echo "  5. Commit and push:"
echo "     git add coolify.yaml .github/workflows/deploy.yml"
echo "     git commit -m 'ci: add Coolify deploy pipeline' && git push"
echo ""
echo "If your repo doesn't have a Dockerfile yet, see:"
echo "  $SKILL_DIR/init/templates/Dockerfile.doppler.snippet"
