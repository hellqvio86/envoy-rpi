#!/usr/bin/env bash
set -Eeuo pipefail

# tests/test_helpers.sh - Offline unit tests for helper scripts and parsers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "❌ FAIL: ${msg} (expected='${expected}', actual='${actual}')" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_fails() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "❌ FAIL: ${msg} (expected non-zero exit, got 0)" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- 1. resolve-build-inputs.sh tests ---
VALID_BAZELRC="${TMP_DIR}/valid.bazelrc"
cat > "${VALID_BAZELRC}" <<'EOF'
build --action_env=BAZEL_BUILD_IMAGE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c@sha256:1b3c82ca34c505c4951918b2e0a0c3db88cf266ebbf4196e4b0fba8fa137ada3
EOF

BAD_BAZELRC="${TMP_DIR}/bad.bazelrc"
echo "build --copt=-O2" > "${BAD_BAZELRC}"

OUT="$("${REPO_ROOT}/bin/resolve-build-inputs.sh" \
  --version v1.36.13 \
  --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 \
  --bazelrc "${VALID_BAZELRC}")"
assert_eq "ENVOY_VERSION=v1.36.13" "$(printf '%s\n' "${OUT}" | grep '^ENVOY_VERSION=')" "valid version output"
assert_eq "ENVOY_COMMIT=eb0a95ba450a3e29a9a8e75f672e2c294493eea2" "$(printf '%s\n' "${OUT}" | grep '^ENVOY_COMMIT=')" "valid commit output"
assert_eq "BUILD_BASE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c@sha256:1b3c82ca34c505c4951918b2e0a0c3db88cf266ebbf4196e4b0fba8fa137ada3" "$(printf '%s\n' "${OUT}" | grep '^BUILD_BASE=')" "parsed bazelrc builder"

# Reject invalid versions (shell injection, whitespace, option-like, missing patch)
assert_fails "reject shell metacharacters" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13;id' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${VALID_BAZELRC}"
assert_fails "reject whitespace" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13 ' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${VALID_BAZELRC}"
assert_fails "reject option-like version" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version '-flag' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${VALID_BAZELRC}"
assert_fails "reject short version" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${VALID_BAZELRC}"
assert_fails "reject invalid commit" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13' --envoy-commit 'deadbeef' --bazelrc "${VALID_BAZELRC}"
assert_fails "reject malformed bazelrc" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${BAD_BAZELRC}"

TAG_ONLY_BAZELRC="${TMP_DIR}/tag-only.bazelrc"
echo "build --action_env=BAZEL_BUILD_IMAGE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c" > "${TAG_ONLY_BAZELRC}"
assert_fails "reject tag-only bazelrc builder" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --bazelrc "${TAG_ONLY_BAZELRC}"
assert_fails "reject tag-only --build-base override" "${REPO_ROOT}/bin/resolve-build-inputs.sh" --version 'v1.36.13' --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 --build-base 'envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c'

OVERRIDE_OUT="$("${REPO_ROOT}/bin/resolve-build-inputs.sh" \
  --version v1.36.13 \
  --envoy-commit eb0a95ba450a3e29a9a8e75f672e2c294493eea2 \
  --build-base 'envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c@sha256:1b3c82ca34c505c4951918b2e0a0c3db88cf266ebbf4196e4b0fba8fa137ada3' 2>/dev/null)"
assert_eq "BUILD_BASE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c@sha256:1b3c82ca34c505c4951918b2e0a0c3db88cf266ebbf4196e4b0fba8fa137ada3" "$(printf '%s\n' "${OVERRIDE_OUT}" | grep '^BUILD_BASE=')" "accept digest-pinned --build-base override"

# --- 2. publish.sh tests ---
EMPTY_BIN="${TMP_DIR}/empty_bin"
mkdir -p "${EMPTY_BIN}"
for cmd in bash cat tr awk grep printf dirname cd pwd; do
  command -v "${cmd}" >/dev/null 2>&1 && ln -sf "$(command -v "${cmd}")" "${EMPTY_BIN}/${cmd}" || true
done
assert_fails "publish rejects non-ghcr registry" env REGISTRY=docker.io "${REPO_ROOT}/bin/publish.sh"
assert_fails "publish rejects invalid platforms" env PLATFORMS=linux/s390x "${REPO_ROOT}/bin/publish.sh"
assert_fails "publish fails without credentials" env -u GITHUB_TOKEN -u RENOVATE_TOKEN PATH="${EMPTY_BIN}" "${REPO_ROOT}/bin/publish.sh"

# --- 3. renovate/run.sh tests (mocked docker & gh) ---
MOCK_BIN="${TMP_DIR}/mock_bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_DOCKER_FAIL:-0}" == "1" ]]; then
  echo "mock docker failure" >&2
  exit 42
fi
printf '%s\n' "$@" > "${MOCK_DOCKER_ARGS_FILE:-/dev/null}"
echo '{"branchName": "renovate/test-dep"}'
EOF
cat > "${MOCK_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${MOCK_BIN}/docker" "${MOCK_BIN}/gh"

SPACE_CACHE="${TMP_DIR}/cache with spaces"
ARGS_FILE="${TMP_DIR}/docker_args.txt"
SUMMARY_OUT="$(env PATH="${MOCK_BIN}:${PATH}" MOCK_DOCKER_ARGS_FILE="${ARGS_FILE}" "${REPO_ROOT}/bin/renovate/run.sh" --summary --cache-dir "${SPACE_CACHE}")"
if printf '%s\n' "${SUMMARY_OUT}" | grep -q 'renovate/test-dep'; then
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "❌ FAIL: renovate summary did not report mocked branch" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Verify hardening flags and no --group-add 0
if grep -q -- '--cap-drop=ALL' "${ARGS_FILE}" && grep -q -- '--security-opt=no-new-privileges' "${ARGS_FILE}" && ! grep -q -- '--group-add' "${ARGS_FILE}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "❌ FAIL: renovate container missing hardening flags or still has --group-add" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

assert_fails "renovate summary propagates docker failure" env PATH="${MOCK_BIN}:${PATH}" MOCK_DOCKER_FAIL=1 "${REPO_ROOT}/bin/renovate/run.sh" --summary --cache-dir "${SPACE_CACHE}"
assert_fails "renovate rejects invalid platform" env PATH="${MOCK_BIN}:${PATH}" "${REPO_ROOT}/bin/renovate/run.sh" --platform invalid
assert_fails "renovate rejects invalid dry-run" env PATH="${MOCK_BIN}:${PATH}" "${REPO_ROOT}/bin/renovate/run.sh" --dry-run bogus
assert_fails "renovate rejects invalid log-level" env PATH="${MOCK_BIN}:${PATH}" "${REPO_ROOT}/bin/renovate/run.sh" --log-level trace
assert_fails "renovate rejects empty cache-dir" env PATH="${MOCK_BIN}:${PATH}" "${REPO_ROOT}/bin/renovate/run.sh" --cache-dir ""

echo "✅ Helper unit tests: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
