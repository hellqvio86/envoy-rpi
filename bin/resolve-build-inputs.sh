#!/usr/bin/env bash
set -Eeuo pipefail

# bin/resolve-build-inputs.sh - Validate Envoy version and resolve immutable source commit & builder image.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVOY_VERSION=""
ENVOY_COMMIT_OVERRIDE=""
BUILD_BASE_OVERRIDE=""
BAZELRC_FILE=""
GITHUB_OUTPUT_MODE="false"

show_help() {
  cat <<'EOF'
Usage: ./bin/resolve-build-inputs.sh [OPTIONS]

Validates the Envoy version tag (vMAJOR.MINOR.PATCH) and resolves the immutable
upstream Envoy commit SHA and builder image from upstream .bazelrc.

Options:
  --version <tag>       Envoy version tag (defaults to VERSION file)
  --envoy-commit <sha>  Explicit 40-char commit SHA override (offline/testing)
  --build-base <image>  Explicit builder image override (offline/testing)
  --bazelrc <path>      Local .bazelrc file to parse instead of fetching upstream
  --github-output       Write outputs in GITHUB_OUTPUT format
  -h, --help            Show this help message and exit
EOF
}

validate_version() {
  local ver="$1"
  if [[ ! "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Error: Invalid Envoy version '${ver}'. Expected exact format vMAJOR.MINOR.PATCH (e.g. v1.36.13)." >&2
    return 1
  fi
}

validate_commit() {
  local sha="$1"
  if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "❌ Error: Invalid Envoy commit SHA '${sha}'. Expected 40 lowercase hex characters." >&2
    return 1
  fi
}

parse_bazelrc_builder() {
  local bazelrc_path="$1"
  local match
  match="$(grep -Eo 'envoyproxy/envoy-build-ubuntu:[a-f0-9]+(@sha256:[a-f0-9]{64})?' "${bazelrc_path}" | sort -u || true)"
  if [[ -z "${match}" ]]; then
    echo "❌ Error: Could not find 'envoyproxy/envoy-build-ubuntu:<tag>' in ${bazelrc_path}." >&2
    return 1
  fi
  local line_count
  line_count="$(printf '%s\n' "${match}" | wc -l | tr -d ' ')"
  if [[ "${line_count}" -ne 1 ]]; then
    echo "❌ Error: Ambiguous envoyproxy/envoy-build-ubuntu references in ${bazelrc_path}:" >&2
    printf '%s\n' "${match}" >&2
    return 1
  fi
  printf '%s\n' "${match}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "❌ Error: --version requires an argument." >&2; exit 2; }
      ENVOY_VERSION="$2"
      shift 2
      ;;
    --envoy-commit)
      [[ $# -ge 2 ]] || { echo "❌ Error: --envoy-commit requires an argument." >&2; exit 2; }
      ENVOY_COMMIT_OVERRIDE="$2"
      shift 2
      ;;
    --build-base)
      [[ $# -ge 2 ]] || { echo "❌ Error: --build-base requires an argument." >&2; exit 2; }
      BUILD_BASE_OVERRIDE="$2"
      shift 2
      ;;
    --bazelrc)
      [[ $# -ge 2 ]] || { echo "❌ Error: --bazelrc requires an argument." >&2; exit 2; }
      BAZELRC_FILE="$2"
      shift 2
      ;;
    --github-output)
      GITHUB_OUTPUT_MODE="true"
      shift
      ;;
    *)
      echo "❌ Error: Unknown option: $1" >&2
      show_help >&2
      exit 2
      ;;
  esac
done

if [[ -z "${ENVOY_VERSION}" ]]; then
  ENVOY_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
fi

validate_version "${ENVOY_VERSION}"

if [[ -n "${ENVOY_COMMIT_OVERRIDE}" ]]; then
  validate_commit "${ENVOY_COMMIT_OVERRIDE}"
  ENVOY_COMMIT="${ENVOY_COMMIT_OVERRIDE}"
else
  # Prefer dereferenced annotated tag commit (^{}), fall back to lightweight tag commit.
  TAG_REFS="$(git ls-remote --tags https://github.com/envoyproxy/envoy.git "refs/tags/${ENVOY_VERSION}" "refs/tags/${ENVOY_VERSION}^{}" 2>/dev/null || true)"
  ENVOY_COMMIT="$(printf '%s\n' "${TAG_REFS}" | awk '/\^\{\}$/ {print $1}' | head -n 1)"
  if [[ -z "${ENVOY_COMMIT}" ]]; then
    ENVOY_COMMIT="$(printf '%s\n' "${TAG_REFS}" | awk '{print $1}' | head -n 1)"
  fi
  validate_commit "${ENVOY_COMMIT}"
fi

if [[ -n "${BUILD_BASE_OVERRIDE}" ]]; then
  if [[ ! "${BUILD_BASE_OVERRIDE}" =~ ^envoyproxy/envoy-build-ubuntu:[a-f0-9]+(@sha256:[a-f0-9]{64})?$ ]]; then
    echo "❌ Error: Invalid --build-base override '${BUILD_BASE_OVERRIDE}'." >&2
    exit 1
  fi
  BUILD_BASE="${BUILD_BASE_OVERRIDE}"
  echo "⚠️ Using explicit BUILD_BASE override: ${BUILD_BASE}" >&2
else
  TMP_BAZELRC=""
  cleanup() {
    if [[ -n "${TMP_BAZELRC}" && -f "${TMP_BAZELRC}" ]]; then
      rm -f "${TMP_BAZELRC}"
    fi
  }
  trap cleanup EXIT

  if [[ -n "${BAZELRC_FILE}" ]]; then
    [[ -f "${BAZELRC_FILE}" ]] || { echo "❌ Error: .bazelrc file not found: ${BAZELRC_FILE}" >&2; exit 1; }
    BUILD_BASE="$(parse_bazelrc_builder "${BAZELRC_FILE}")"
  else
    TMP_BAZELRC="$(mktemp)"
    if ! curl -fsSL "https://raw.githubusercontent.com/envoyproxy/envoy/${ENVOY_COMMIT}/.bazelrc" -o "${TMP_BAZELRC}"; then
      echo "❌ Error: Failed to fetch upstream .bazelrc for Envoy ${ENVOY_VERSION} (${ENVOY_COMMIT})." >&2
      exit 1
    fi
    BUILD_BASE="$(parse_bazelrc_builder "${TMP_BAZELRC}")"
  fi
fi

if [[ "${GITHUB_OUTPUT_MODE}" == "true" ]]; then
  {
    echo "version=${ENVOY_VERSION}"
    echo "envoy_commit=${ENVOY_COMMIT}"
    echo "build_base=${BUILD_BASE}"
  } >> "${GITHUB_OUTPUT}"
else
  echo "ENVOY_VERSION=${ENVOY_VERSION}"
  echo "ENVOY_COMMIT=${ENVOY_COMMIT}"
  echo "BUILD_BASE=${BUILD_BASE}"
fi
