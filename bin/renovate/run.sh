#!/usr/bin/env bash
set -Eeuo pipefail

# bin/renovate/run.sh - Run Renovate CLI locally via a hardened Docker container.
#
# Trust boundary: If .env exists in the repository root, it is sourced as shell
# code and must only be present when trusted by the operator. Ensure .env is
# listed in .gitignore and never committed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.env"
  set +a
fi

DEFAULT_RENOVATE_IMAGE="ghcr.io/renovatebot/renovate@sha256:3b72fc4274c56f65f53dcd4dcbed3143289358e0a2d96f7af215e6cf1923e5f6"
RENOVATE_IMAGE="${RENOVATE_IMAGE:-${DEFAULT_RENOVATE_IMAGE}}"
CACHE_DIR="${HOME}/.cache/renovate"
LOG_LEVEL="${LOG_LEVEL:-info}"
DRY_RUN="full"
PLATFORM=""
TOKEN="${RENOVATE_TOKEN:-${GITHUB_TOKEN:-}}"

DEFAULT_REPO_NAME="$(git config --get remote.origin.url 2>/dev/null | sed -E 's/.*[:\/]([^\/]+\/[^\/\.]+)(\.git)?$/\1/' || true)"
REPO_NAME="${REPO_NAME:-${DEFAULT_REPO_NAME:-hellqvio86/envoy-rpi}}"

SUMMARY="false"

show_help() {
  cat <<'EOF'
Usage: ./bin/renovate/run.sh [OPTIONS]

Run Renovate locally inside a hardened container against this repository.

Options:
  -s, --summary            Print a clean summary of proposed upgrade branches
  -w, --write, --apply     Live mode: create/update local git branches (--dry-run null)
  -d, --dry-run <mode>     Dry-run mode: 'full' (default), 'lookup', or 'null'
  -l, --log-level <level>  Log level: info (default), debug, warn, error, fatal
  -t, --token <token>      GitHub token (prefer GITHUB_TOKEN / RENOVATE_TOKEN env vars)
  -p, --platform <name>    Platform: 'local' (default without token) or 'github'
  --cache-dir <dir>        Directory to store Renovate cache (default: ~/.cache/renovate)
  -h, --help               Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -s|--summary)
      SUMMARY="true"
      LOG_LEVEL="debug"
      shift
      ;;
    -w|--write|--apply|--no-dry-run)
      DRY_RUN="null"
      shift
      ;;
    -d|--dry-run)
      [[ $# -ge 2 ]] || { echo "❌ Error: $1 requires a mode argument (full, lookup, null)." >&2; exit 2; }
      DRY_RUN="$2"
      shift 2
      ;;
    --dry-run=*)
      DRY_RUN="${1#*=}"
      shift
      ;;
    -l|--log-level)
      [[ $# -ge 2 ]] || { echo "❌ Error: $1 requires a level argument." >&2; exit 2; }
      LOG_LEVEL="$2"
      shift 2
      ;;
    --log-level=*)
      LOG_LEVEL="${1#*=}"
      shift
      ;;
    -t|--token)
      [[ $# -ge 2 ]] || { echo "❌ Error: $1 requires a token argument." >&2; exit 2; }
      TOKEN="$2"
      shift 2
      ;;
    --token=*)
      TOKEN="${1#*=}"
      shift
      ;;
    -p|--platform)
      [[ $# -ge 2 ]] || { echo "❌ Error: $1 requires a platform argument (local, github)." >&2; exit 2; }
      PLATFORM="$2"
      shift 2
      ;;
    --platform=*)
      PLATFORM="${1#*=}"
      shift
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { echo "❌ Error: $1 requires a directory path." >&2; exit 2; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --cache-dir=*)
      CACHE_DIR="${1#*=}"
      shift
      ;;
    *)
      echo "❌ Error: Unknown option: $1" >&2
      show_help >&2
      exit 2
      ;;
  esac
done

case "${DRY_RUN}" in
  full|lookup|null) ;;
  *)
    echo "❌ Error: Invalid --dry-run '${DRY_RUN}'. Expected: full, lookup, or null." >&2
    exit 2
    ;;
esac

case "${LOG_LEVEL}" in
  info|debug|warn|error|fatal) ;;
  *)
    echo "❌ Error: Invalid --log-level '${LOG_LEVEL}'. Expected: info, debug, warn, error, or fatal." >&2
    exit 2
    ;;
esac

if [[ -z "${CACHE_DIR}" ]]; then
  echo "❌ Error: --cache-dir cannot be empty." >&2
  exit 2
fi

if [[ ! "${REPO_NAME}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "❌ Error: Invalid REPO_NAME '${REPO_NAME}'. Expected owner/repo." >&2
  exit 2
fi

GH_SOURCE="manual"
if [[ -z "${TOKEN}" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
  if [[ -n "${TOKEN}" ]]; then
    GH_SOURCE="gh-cli"
  fi
fi

if [[ -z "${PLATFORM}" ]]; then
  if [[ -n "${TOKEN}" ]]; then
    PLATFORM="github"
  else
    PLATFORM="local"
  fi
fi

case "${PLATFORM}" in
  local|github) ;;
  *)
    echo "❌ Error: Invalid --platform '${PLATFORM}'. Expected: local or github." >&2
    exit 2
    ;;
esac

GIT_AUTHOR_NAME="$(git config user.name 2>/dev/null || true)"
GIT_AUTHOR_EMAIL="$(git config user.email 2>/dev/null || true)"
if [[ -n "${GIT_AUTHOR_NAME}" && -n "${GIT_AUTHOR_EMAIL}" ]]; then
  GIT_AUTHOR="${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>"
elif [[ "${DRY_RUN}" == "null" ]]; then
  echo "❌ Error: Write mode (--dry-run null) requires git user.name and user.email to be configured." >&2
  exit 1
else
  GIT_AUTHOR="renovate[bot] <renovate[bot]@users.noreply.github.com>"
fi

mkdir -p "${CACHE_DIR}"

echo "=== 🚀 Running Renovate Locally ==="
echo "Repository: ${REPO_NAME}"
echo "Platform:   ${PLATFORM}"
if [[ "${PLATFORM}" == "github" ]]; then
  if [[ "${GH_SOURCE}" == "gh-cli" ]]; then
    echo "Auth:       GitHub CLI (auto-detected via gh)"
  else
    echo "Auth:       Environment/CLI token"
  fi
fi
echo "Git Author: ${GIT_AUTHOR}"
echo "Dry Run:    ${DRY_RUN}"
echo "Log Level:  ${LOG_LEVEL}"
echo "Cache Dir:  ${CACHE_DIR}"
echo "Image:      ${RENOVATE_IMAGE}"
if [[ "${RENOVATE_IMAGE}" != "${DEFAULT_RENOVATE_IMAGE}" ]]; then
  echo "⚠️ Using custom RENOVATE_IMAGE override."
fi

DOCKER_ARGS=(
  docker run --rm -i
  --user "$(id -u):$(id -g)"
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --read-only
  "--tmpfs=/tmp:rw,noexec,nosuid,size=256m"
  --memory=2g
  --cpus=2
  -e "HOME=/tmp"
  -e "LOG_LEVEL=${LOG_LEVEL}"
  -e "RENOVATE_DRY_RUN=${DRY_RUN}"
  -e "RENOVATE_PLATFORM=${PLATFORM}"
  -e "RENOVATE_GIT_AUTHOR=${GIT_AUTHOR}"
  -e "RENOVATE_CACHE_DIR=/tmp/renovate-cache"
  -e "RENOVATE_CONFIG_FILE=/usr/src/app/renovate.json"
  -e "RENOVATE_REQUIRE_CONFIG=ignored"
  -e "RENOVATE_ONBOARDING=false"
  -v "${CACHE_DIR}:/tmp/renovate-cache:z"
  -v "${REPO_ROOT}:/usr/src/app:z"
  -w "/usr/src/app"
)

if [[ -t 0 ]]; then
  DOCKER_ARGS+=(-t)
fi

if [[ "${PLATFORM}" == "local" ]]; then
  DOCKER_ARGS+=(
    "${RENOVATE_IMAGE}"
    renovate --platform=local
  )
else
  if [[ -z "${TOKEN}" ]]; then
    echo "❌ Error: Platform is '${PLATFORM}' but no GitHub token was provided." >&2
    exit 1
  fi
  REPO_JSON="$(printf '["%s"]' "${REPO_NAME}")"
  DOCKER_ARGS+=(
    -e "RENOVATE_TOKEN=${TOKEN}"
    -e "RENOVATE_REPOSITORIES=${REPO_JSON}"
    "${RENOVATE_IMAGE}"
    renovate
  )
fi

if [[ "${SUMMARY}" == "true" ]]; then
  echo "Scanning dependencies and evaluating upgrades..."
  TMP_LOG="$(mktemp)"
  cleanup_summary() {
    rm -f "${TMP_LOG}"
  }
  trap cleanup_summary EXIT

  set +e
  "${DOCKER_ARGS[@]}" > "${TMP_LOG}" 2>&1
  RC=$?
  set -e

  if [[ "${RC}" -ne 0 ]]; then
    echo "❌ Error: Renovate exited with status ${RC}." >&2
    tail -n 40 "${TMP_LOG}" >&2 || true
    exit "${RC}"
  fi

  echo
  echo "=== 📋 Detected Renovate Upgrade Branches ==="
  BRANCHES="$(grep -E '"branchName": "renovate/' "${TMP_LOG}" | sed -E 's/.*"branchName": "(.*)".*/  - \1/' | sort -u || true)"
  if [[ -n "${BRANCHES}" ]]; then
    echo "${BRANCHES}"
    echo
    echo "Tip: Run './bin/renovate/run.sh --write' to create these branches and open PRs."
  else
    echo "  (No update branches proposed)"
  fi
else
  "${DOCKER_ARGS[@]}"
fi
