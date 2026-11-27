#!/usr/bin/env bash
set -Eeuo pipefail

# bin/publish.sh - Build and publish envoy-rpi to GitHub Container Registry (ghcr.io).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-hellqvio86/envoy-rpi}"
PLATFORMS="${PLATFORMS:-linux/amd64}"

show_help() {
  cat <<'EOF'
Usage: ./bin/publish.sh [OPTIONS]

Builds and pushes envoy-rpi to GitHub Container Registry (ghcr.io).

Environment variables:
  REGISTRY      Must be 'ghcr.io' (default: ghcr.io)
  IMAGE_NAME    Repository path (default: hellqvio86/envoy-rpi)
  PLATFORMS     linux/amd64 (default), linux/arm64, or linux/amd64,linux/arm64
  GITHUB_TOKEN  Token with write:packages (or falls back to 'gh auth token')
  GITHUB_ACTOR  GHCR username (or falls back to 'gh api user -q .login')
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

if [[ "${REGISTRY}" != "ghcr.io" ]]; then
  echo "❌ Error: Unsupported REGISTRY '${REGISTRY}'. Only 'ghcr.io' is supported." >&2
  exit 1
fi

case "${PLATFORMS}" in
  linux/amd64)
    TAG_SUFFIX="-amd64"
    ;;
  linux/arm64)
    TAG_SUFFIX="-arm64"
    ;;
  linux/amd64,linux/arm64|linux/arm64,linux/amd64)
    TAG_SUFFIX=""
    ;;
  *)
    echo "❌ Error: Unsupported PLATFORMS '${PLATFORMS}'. Expected linux/amd64, linux/arm64, or linux/amd64,linux/arm64." >&2
    exit 1
    ;;
esac

TOKEN="${GITHUB_TOKEN:-${RENOVATE_TOKEN:-}}"
if [[ -z "${TOKEN}" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "${TOKEN}" ]]; then
  echo "❌ Error: Missing GHCR credentials. Set GITHUB_TOKEN (with write:packages) or authenticate with 'gh auth login'." >&2
  exit 1
fi

ACTOR="${GITHUB_ACTOR:-}"
if [[ -z "${ACTOR}" ]] && command -v gh >/dev/null 2>&1; then
  ACTOR="$(gh api user -q .login 2>/dev/null || true)"
fi
if [[ -z "${ACTOR}" ]]; then
  echo "❌ Error: Missing GHCR username. Set GITHUB_ACTOR or authenticate with 'gh auth login'." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain -- VERSION 2>/dev/null)" ]]; then
  echo "❌ Error: VERSION has uncommitted changes. Commit VERSION before publishing." >&2
  exit 1
fi

RESOLVED="$("${SCRIPT_DIR}/resolve-build-inputs.sh")"
ENVOY_VERSION="$(printf '%s\n' "${RESOLVED}" | awk -F= '/^ENVOY_VERSION=/{print $2}')"
ENVOY_COMMIT="$(printf '%s\n' "${RESOLVED}" | awk -F= '/^ENVOY_COMMIT=/{print $2}')"
BUILD_BASE="$(printf '%s\n' "${RESOLVED}" | awk -F= '/^BUILD_BASE=/{print $2}')"

TAG="${REGISTRY}/${IMAGE_NAME}:${ENVOY_VERSION}${TAG_SUFFIX}"

echo "🔐 Logging into ${REGISTRY} as ${ACTOR}..."
printf '%s' "${TOKEN}" | docker login "${REGISTRY}" -u "${ACTOR}" --password-stdin

if [[ "${ALLOW_OVERWRITE:-false}" != "true" ]] && docker buildx imagetools inspect "${TAG}" >/dev/null 2>&1; then
  echo "❌ Error: ${TAG} already exists in ${REGISTRY}. Set ALLOW_OVERWRITE=true to overwrite." >&2
  exit 1
fi

echo "🚀 Building and publishing ${TAG} (${PLATFORMS}, commit ${ENVOY_COMMIT})..."
docker buildx build \
  --platform "${PLATFORMS}" \
  --push \
  --build-arg "ENVOY_VERSION=${ENVOY_VERSION}" \
  --build-arg "ENVOY_COMMIT=${ENVOY_COMMIT}" \
  --build-arg "BUILD_BASE=${BUILD_BASE}" \
  -t "${TAG}" \
  .
