#!/usr/bin/env bash
# push-hello-world.sh — Build and push the E2E test image to GHCR.
# Run this once (or when test/hello-world/ changes) before running test/e2e.sh.
#
# Usage:
#   bash test/push-hello-world.sh
#   GHCR_ORG=my-org bash test/push-hello-world.sh   # override org
#
# GHCR_TOKEN resolution order:
#   1. GHCR_TOKEN env var (highest priority)
#   2. Doppler: claude-skills-deploy/stg GHCR_TOKEN secret
#   3. Error — see setup-guide.md for how to store the token in Doppler
#
# Requires: Docker, doppler CLI (authenticated), gh CLI (for visibility patch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHCR_ORG="${GHCR_ORG:-streamlinity}"
IMAGE="ghcr.io/${GHCR_ORG}/csd-hello-world"
TAG="${TAG:-latest}"

echo "=== Building E2E hello-world image ==="
echo "  image: ${IMAGE}:${TAG}"
echo "  source: $SCRIPT_DIR/hello-world/"

docker build \
  --platform linux/amd64 \
  -t "${IMAGE}:${TAG}" \
  "$SCRIPT_DIR/hello-world/"

echo ""
echo "=== Resolving GHCR_TOKEN ==="
# Resolution order: env var → Doppler claude-skills-deploy/stg → error
if [ -z "${GHCR_TOKEN:-}" ]; then
  GHCR_TOKEN=$(doppler secrets get GHCR_TOKEN \
    --project claude-skills-deploy --config stg --plain 2>/dev/null || true)
fi
if [ -z "${GHCR_TOKEN:-}" ]; then
  echo "ERROR: GHCR_TOKEN not found. Store it in Doppler:" >&2
  echo "  doppler secrets set GHCR_TOKEN --project claude-skills-deploy --config stg" >&2
  echo "  (PAT needs write:packages scope — see docs/setup-guide.md)" >&2
  exit 1
fi
echo "  ✓ token resolved"

echo ""
echo "=== Authenticating to GHCR ==="
echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-${GHCR_ORG}}" --password-stdin

echo ""
echo "=== Pushing ${IMAGE}:${TAG} ==="
docker push "${IMAGE}:${TAG}"

echo ""
echo "=== Making package public (so Coolify can pull without auth) ==="
# GHCR packages are private by default; make public so the Coolify VPS can pull it
REPO_NAME="csd-hello-world"
gh api \
  --method PATCH \
  "/user/packages/container/${REPO_NAME}" \
  -f visibility=public 2>/dev/null \
  && echo "  ✓ package visibility set to public" \
  || echo "  ⚠ could not set visibility via API — set manually at github.com/users/${GHCR_ORG}/packages"

echo ""
echo "Done. E2E image available at: ${IMAGE}:${TAG}"
echo "Run the E2E test: bash test/e2e.sh"
