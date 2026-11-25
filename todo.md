# Critical Review — envoy-rpi

> **Review scope:** Static review of the supplied `envoy-rpi-main` source archive.
> **Review date:** 2026-11-25
> **Audience:** Implementation agents.
>
> This review is based on the files present in the archive. The archive does not contain Git history, so history-dependent secret scanning and repository-state checks were not independently verifiable. No Docker image build or GitHub Actions run was executed. Treat findings as code-review findings, not proof that a production deployment is currently exploitable.

## Executive assessment

The repository has a clear purpose and a reasonably small build pipeline, but it is not yet as reproducible or security-hardened as its README and `AGENTS.md` claim. The most important problems are:

1. **The upstream version and build-toolchain inputs are not consistently resolved or validated.** Local builds and CI can use different builder images, and the builder/runtime images are not pinned by OCI digest.
2. **The build workflow accepts a manually supplied version through direct shell interpolation.** This is avoidable command-injection exposure in a workflow with broad write permissions.
3. **The vulnerability scan is informational by default.** High/critical findings do not currently fail the build.
4. **The release workflow can publish an image version that does not match the Git tag that triggered the workflow.**
5. **The automated upstream bump workflow is not robustly idempotent and uses `GITHUB_TOKEN` to create PRs, which commonly prevents the PR-triggered workflows from running.**
6. **The Renovate helper has unsafe/fragile operational behavior:** it suppresses failures in summary mode, trusts mutable container images, adds the container process to group 0, and has weak argument validation.

Do not spend effort adding features before resolving the P0/P1 items and adding meaningful build/release tests.

---

## P0 — Fix before relying on automated releases

### [x] P0.1 — Remove shell injection from the manual Envoy version input

**Evidence:** `.github/workflows/build.yml`, `Resolve Envoy version and build image tag` step. The workflow interpolates `${{ github.event.inputs.envoy_version }}` directly into a shell assignment.

**Problem:** A workflow-dispatch input is user-controlled text. Direct expression interpolation into a `run:` script is unsafe; shell metacharacters can alter the script. This is especially serious because the workflow has repository/package write permissions.

**Required change:**
- Pass the input through a step-level `env:` variable, then read it as a quoted shell variable.
- Validate the value before using it anywhere: require the exact expected Envoy tag syntax (currently `vMAJOR.MINOR.PATCH`, unless the project deliberately supports other formats).
- Reject whitespace, newlines, option-like values, and unexpected characters.
- Ensure the validated version is the only value passed to Docker build arguments and release/tag operations.

**Acceptance criteria:**
- No `${{ ... }}` untrusted input is embedded directly in shell source.
- A valid version such as `v1.36.13` is accepted.
- Inputs containing shell syntax, newlines, spaces, or an invalid tag are rejected before any build/publish step.
- Add a small automated validation test for accepted and rejected version strings.

### [x] P0.2 — Pin all production build inputs by immutable digest/commit

**Evidence:** `Dockerfile:3-4,29`; `.github/workflows/build.yml` action references.

**Problem:** The Dockerfile uses mutable image tags for both the builder and distroless runtime. The workflow also references several GitHub Actions by movable version tags (`actions/checkout@v7`, `docker/build-push-action@v7`, `anchore/sbom-action@v0`, etc.). A tag can be retargeted, which weakens reproducibility and supply-chain guarantees. The builder tag looks hash-like, but it is still an OCI tag, not a digest.

**Required change:**
- Pin `BUILD_BASE` and the distroless runtime image to `@sha256:<digest>`.
- Pin every third-party GitHub Action to a full commit SHA; retain a human-readable version comment.
- Configure Renovate to update pinned action digests and image digests.
- Keep the upstream Envoy source pinned to an immutable commit or verify the fetched tag resolves to an expected commit. Record the resolved commit in build metadata.

**Acceptance criteria:**
- No production `FROM` image is referenced only by a mutable tag.
- No third-party action in release/security workflows is referenced only by a mutable tag.
- Dependency automation can propose digest updates.
- The image can be rebuilt from recorded source/toolchain identities.

### [x] P0.3 — Make high/critical Trivy findings fail the build

**Evidence:** `.github/workflows/build.yml`, `Run Trivy vulnerability scan`.

**Problem:** The Trivy action does not set `exit-code`. Its default behavior is not a policy gate, so the workflow can succeed while reporting HIGH/CRITICAL vulnerabilities. `ignore-unfixed: true` is a defensible policy choice, but it does not make the scan blocking.

**Required change:**
- Set an explicit non-zero `exit-code` for findings at the chosen severity.
- Keep SARIF output and upload behavior, but make the policy decision explicit.
- Document any exceptions and use a reviewed, time-bounded ignore mechanism rather than silently broadening exclusions.

**Acceptance criteria:**
- A fixture image or controlled test containing a known, non-ignored HIGH/CRITICAL vulnerability causes the scan step to fail.
- A clean image passes.
- The policy for unfixed vulnerabilities is documented.

### [x] P0.4 — Ensure release tag, Envoy source version, image tag, and release metadata agree

**Evidence:** `.github/workflows/build.yml`, `on.push.tags`, `Resolve Envoy version and build image tag`, manifest creation, and release steps.

**Problem:** A push of `vX.Y.Z` triggers the workflow, but the build version is taken from `VERSION` (unless workflow dispatch input is supplied). The pushed Git tag is not checked against that value. A mismatched tag can therefore publish an image under the `VERSION` value while creating/publishing a GitHub release for the triggering tag. This can produce misleading release metadata and confusing image tags.

**Required change:**
- On tag events, derive the expected version from `github.ref_name` and require it to equal `VERSION`, or explicitly define and document a different release policy.
- On workflow dispatch, build-only behavior should be the default; publishing/releasing an arbitrary version should require an explicit, separately guarded input/approval.
- Use one validated version output throughout build, manifest, SBOM, attestation, and release steps.
- Fail closed on any mismatch.

**Acceptance criteria:**
- A tag matching `VERSION` builds and publishes the matching image.
- A mismatched tag fails before login/push/release.
- A manual build cannot accidentally publish an unrelated release.
- Release notes, image tags, and attestation subject all refer to the same version/digest.

### [x] P0.5 — Restrict GitHub Actions permissions to the job and event that need them

**Evidence:** `.github/workflows/build.yml`, workflow-level `permissions`.

**Problem:** The workflow grants `contents: write`, `packages: write`, `id-token: write`, `attestations: write`, and `security-events: write` to every job/event, including pull requests. Most build jobs need read-only access; only publishing/attestation/release jobs need write permissions. Broad defaults increase the impact of a compromised action or workflow step.

**Required change:**
- Set workflow-level permissions to `contents: read`.
- Grant the minimum required permissions at job level:
  - build jobs: read-only unless a specific permission is demonstrably required;
  - manifest/publish job: packages write, id-token write, attestations write;
  - release job: contents write;
  - SARIF upload job: security-events write.
- Ensure fork PRs and ordinary PR builds cannot access write-capable credentials.
- Consider separating untrusted PR validation from privileged publishing into distinct workflows.

**Acceptance criteria:**
- Every job has only the permissions it actually uses.
- PR builds have no package, release, attestation, or repository write permission.
- Workflow documentation describes the trust boundary.

---

## P1 — Correctness, reproducibility, and release reliability

### [x] P1.1 — Use the same builder-image resolution logic for local and CI builds

**Evidence:** `Dockerfile:4`; `Makefile:26-35`; `.githooks/pre-push`; `.github/workflows/build.yml`, version-resolution step.

**Problem:** CI resolves the Envoy builder image from the target Envoy tag's `.bazelrc`, but `make build` and the pre-push hook simply read the static `BUILD_BASE` default from the Dockerfile. Local and CI builds can therefore use different build environments. This undermines the claim that local `make test` validates the CI build.

**Required change:**
- Move builder-image resolution into one shared script or make the Dockerfile consume a generated/explicit build input.
- Prefer failing if the upstream `.bazelrc` cannot be fetched or parsed; do not silently use a potentially stale fallback.
- Allow an explicit offline override, but make it visible in logs and documentation.
- Ensure CI and local commands invoke the same resolver.

**Acceptance criteria:**
- For a given Envoy version, local and CI resolve the same builder image digest.
- A missing or malformed upstream builder reference fails clearly.
- An intentional override is explicit and testable.

### [x] P1.2 — Verify the upstream Envoy tag and source commit before building

**Evidence:** `Dockerfile:13`; `.github/workflows/build.yml`, version-resolution step.

**Problem:** The Dockerfile clones a tag by name with `git clone --depth 1 --branch`. Tags are mutable references and the build does not record or verify the resolved source commit. The tag string alone is not a complete source identity.

**Required change:**
- Resolve the tag to a commit before the build and pass the immutable commit to the Docker build.
- Verify the commit belongs to the expected upstream repository and corresponds to the requested tag.
- Record source commit, Envoy tag, builder digest, runtime digest, and build parameters in OCI labels/provenance.

**Acceptance criteria:**
- Build logs and image metadata identify the exact Envoy source commit.
- Rebuilding from the recorded inputs uses the same source revision.
- A missing or unexpected tag resolution fails closed.

### [x] P1.3 — Make the upstream update workflow idempotent and PR-triggering

**Evidence:** `.github/workflows/check-upstream.yml`.

**Problem:**
- The workflow always runs `git checkout -b` and `gh pr create`; reruns can fail if the branch already exists or a PR is already open.
- The release API response is not validated beyond assigning `.tag_name`; a JSON `null` result can become the literal string `null`.
- PRs created with the repository's `GITHUB_TOKEN` generally do not trigger subsequent workflow runs, so the version bump PR may not receive the normal build validation.
- The workflow has no concurrency protection.

**Required change:**
- Validate that the API response contains a non-empty tag matching the supported version format.
- Check whether the branch and PR already exist; update/reuse them rather than failing.
- Use a GitHub App installation token or appropriately scoped PAT if PR workflows must run, or explicitly trigger a trusted validation workflow by another supported mechanism.
- Add concurrency control keyed to the update workflow.
- Handle upstream API rate limits and transient errors with clear failure messages.

**Acceptance criteria:**
- Re-running the workflow with no new release is a successful no-op.
- Re-running after a partially completed update repairs/updates the existing branch/PR.
- The generated version PR receives the intended CI validation.
- Invalid API responses never create a branch or PR.

### [x] P1.4 — Make release publication atomic and race-resistant

**Evidence:** `.github/workflows/build.yml`, `build-arch` and `merge-manifest` jobs.

**Problem:** The manifest job assumes both architecture jobs have pushed the expected tags. Concurrent pushes or reruns for the same version can overwrite architecture tags or race while creating the manifest and `latest`. There is no workflow concurrency policy or immutable-release guard.

**Required change:**
- Add concurrency controls for publication by version/ref.
- Prevent overwriting an already published version tag unless an explicit recovery path is used.
- Verify both architecture image digests exist and correspond to the current workflow run before creating the manifest.
- Consider using unique staging tags tied to the commit/run, then promote to version/latest only after both builds and scans pass.

**Acceptance criteria:**
- Two runs for the same release cannot interleave and publish a mixed manifest.
- A missing architecture image prevents manifest publication.
- A published version cannot be silently overwritten by a later run.

### [x] P1.5 — Add a real runtime hardening smoke test

**Evidence:** `Dockerfile:29-41`; `.github/workflows/build.yml`, smoke-test step; README Kubernetes example.

**Problem:** CI validates `--version` and config syntax, but does not verify the image actually runs as UID/GID 65532 with a read-only root filesystem, no capabilities, and no privilege escalation. The README makes explicit hardened-runtime claims, but the workflow does not test them.

**Required change:**
- Add a runtime test using a minimal valid Envoy config.
- Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, and non-root UID/GID.
- Verify the process starts, binds an unprivileged port, serves a request, and exits cleanly.
- Test whether any required writable paths need explicit tmpfs mounts; do not weaken the image defaults without evidence.
- Run this on both amd64 and arm64 native runners.

**Acceptance criteria:**
- The hardened runtime test passes on both architectures.
- The test verifies actual HTTP behavior, not only config validation.
- Any required writable path is documented and narrowly scoped.

### [x] P1.6 — Add explicit architecture and image-manifest verification

**Evidence:** `.github/workflows/build.yml`, matrix and manifest job; README architecture claims.

**Problem:** The workflow builds each platform natively, but does not explicitly assert the final manifest contains exactly the expected `linux/amd64` and `linux/arm64` entries. A successful manifest command alone is not sufficient proof of the published architecture set.

**Required change:**
- Inspect the final manifest and assert both expected platforms are present exactly once.
- Verify architecture-specific tags point to the expected platform.
- Record the final manifest digest in release output.

**Acceptance criteria:**
- CI fails if either architecture is missing or an unexpected architecture is published.
- Release metadata contains the verified manifest digest.

### [x] P1.7 — Avoid silent fallback to an outdated build image

**Evidence:** `.github/workflows/build.yml`, builder image resolution.

**Problem:** If `.bazelrc` parsing fails, CI silently selects a hard-coded builder image. A newly upgraded Envoy release may require a different compiler/toolchain, so this fallback can produce confusing build failures or, worse, a build that succeeds with an unintended toolchain.

**Required change:**
- Remove the silent fallback.
- If a fallback is operationally necessary, make it a versioned mapping with an explicit compatibility check and a prominent warning.
- Add a test for parsing the upstream `.bazelrc` format.

**Acceptance criteria:**
- An unrecognized upstream builder reference causes a clear failure.
- Every supported Envoy version maps to a known, tested builder digest.

### [x] P1.8 — Align the documented local test contract with what `make test` actually tests

**Evidence:** `AGENTS.md:13-16`; `Makefile`.

**Problem:** `make test` is only `lint` plus `build`; it does not run unit tests, runtime integration tests, manifest checks, or security-policy tests. `AGENTS.md` also describes checks as if they are comprehensive, which overstates the current test coverage.

**Required change:**
- Define explicit targets such as `lint`, `unit-test`, `build`, `smoke-test`, `security`, and `test`.
- Make `test` run the meaningful checks available locally, while documenting which checks require CI/native architecture runners.
- Keep local and CI behavior aligned where practical.
- Avoid describing a binary `--version` check as a full smoke/integration test.

**Acceptance criteria:**
- `make help` or README documents each target and prerequisites.
- `make test` runs the agreed test suite and fails on any required check failure.
- Agent instructions accurately describe what is and is not tested.

### [x] P1.9 — Fix the Makefile publish authentication and registry contract

**Evidence:** `Makefile`, `publish` target.

**Problem:**
- `REGISTRY` is configurable, but authentication is hard-coded around GitHub CLI (`gh auth token` and `gh api user`), so a non-GHCR registry is not actually supported.
- Supplying `GITHUB_TOKEN` avoids the `gh auth token` fallback, but the username still comes from `gh api user`; this makes the documented token override incomplete when `gh` is unavailable.
- The recipe is a long shell command with no explicit `set -euo pipefail`, so intermediate failures can be obscured by later commands depending on shell behavior.

**Required change:**
- Either explicitly support GHCR only and remove the misleading generic `REGISTRY` contract, or implement registry-specific authentication.
- Allow a documented username/token pair or use a clearly defined GHCR identity source.
- Use `set -Eeuo pipefail` in the recipe or move publish logic into a tested Bash script.
- Validate `PLATFORMS` and tag behavior before publishing.

**Acceptance criteria:**
- Publishing works with the documented authentication method in a clean environment.
- Missing credentials fail before build/push.
- Unsupported registries/platform values fail with a clear message.
- A failed login/build cannot be reported as a successful publish.

---

## P1 — Renovate helper safety and correctness

### [x] P1.10 — Do not suppress Renovate failures in summary mode

**Evidence:** `bin/renovate/run.sh:234-249`.

**Problem:** Summary mode uses `|| :`, discarding the Renovate exit status. If Docker fails, authentication fails, config parsing fails, or Renovate crashes, the script prints “No update branches proposed”, which is materially misleading.

**Required change:**
- Capture the command exit status and distinguish a successful empty result from a failed run.
- Preserve useful diagnostic output on failure.
- Use a cleanup trap for the temporary log.
- Parse Renovate output using a stable output format if available rather than depending on one exact log line.

**Acceptance criteria:**
- A successful run with no updates exits zero and reports no updates.
- A failed container/Renovate invocation exits non-zero and prints diagnostics.
- Temporary files are cleaned up on success, failure, and interruption.

### [x] P1.11 — Remove unnecessary root-group membership from the Renovate container

**Evidence:** `bin/renovate/run.sh:193-208`, especially `--group-add 0`.

**Problem:** The container is run as the invoking host UID/GID but is additionally placed in group 0. This grants membership in the container's root group and is not explained. The repository bind mount is already intended to be writable by the matching UID/GID.

**Required change:**
- Remove `--group-add 0`.
- If a specific mounted path requires an additional group, document the reason and use the narrowest actual group ID.
- Keep the container unprivileged and avoid mounting the Docker socket.

**Acceptance criteria:**
- Renovate can read/write the intended repository and cache without group 0.
- The container runs with only the caller's required UID/GID/groups.

### [x] P1.12 — Pin and validate the Renovate container image

**Evidence:** `bin/renovate/run.sh:21-22`; `docker run` construction.

**Problem:** The default image is `ghcr.io/renovatebot/renovate:latest`, a mutable tag. A local run can therefore change behavior without a repository change and may execute a newly published image.

**Required change:**
- Pin a tested Renovate version or digest by default.
- Permit explicit overrides for testing, but make the resolved image visible.
- Consider image signature/provenance verification if this helper is part of the trusted maintenance workflow.

**Acceptance criteria:**
- Default runs use a reviewed immutable image reference.
- Updating Renovate is an explicit dependency update.
- An override is documented and does not silently become the default.

### [x] P1.13 — Validate Renovate CLI options and prevent malformed platform/config values

**Evidence:** `bin/renovate/run.sh:64-145,156-163,215-232`.

**Problem:** `--platform` accepts any value; any non-`local` value follows the GitHub path. `--dry-run` accepts arbitrary strings. The script should reject unsupported values before starting Docker.

**Required change:**
- Validate platform against `local|github`.
- Validate dry-run against `full|lookup|null`.
- Validate log level against supported levels.
- Validate repository identifier format before constructing `RENOVATE_REPOSITORIES`.
- Reject empty cache paths and handle paths with spaces safely.
- Keep all values as distinct Docker arguments/environment values; do not construct JSON through unsafe string interpolation.

**Acceptance criteria:**
- Invalid values exit non-zero with a specific error and usage text.
- Valid options continue to work with spaces in cache paths.
- Repository input cannot break the JSON configuration passed to Renovate.

### [x] P1.14 — Remove the hard-coded personal Git author fallback

**Evidence:** `bin/renovate/run.sh:165-172`; `renovate.json:11`.

**Problem:** The helper falls back to a personal name/email when Git identity is missing, and Renovate config repeats that identity. This can create commits attributed to a person who did not configure that identity and makes the project less reusable.

**Required change:**
- Require a configured Git author for local write mode, or use a clearly documented bot identity.
- Avoid embedding a personal email address in shared automation configuration unless it is an intentional project policy.
- Keep read-only summary mode usable without a Git author.

**Acceptance criteria:**
- Summary mode works without a configured Git identity.
- Write mode fails clearly or uses an explicit bot identity.
- No personal author identity is silently injected.

### [x] P1.15 — Make `.env` loading an explicit, documented trust boundary

**Evidence:** `bin/renovate/run.sh:14-19`.

**Problem:** The script sources `.env` as shell code. This is not merely reading key/value data; it executes the file with the user's privileges. The behavior may be intentional, but it is not documented as a code-execution trust boundary.

**Required change:**
- Prefer exporting variables in the caller's environment or parse a deliberately limited dotenv format without `source`.
- If sourcing is retained, document that `.env` must be trusted executable shell code and ensure it is ignored by Git.
- Do not print secrets or include tokens in command-line arguments where avoidable.

**Acceptance criteria:**
- The documented behavior accurately describes whether `.env` is executed.
- Secret values are never printed.
- Token handling does not expose the token in the helper's own command-line arguments.

### [x] P1.16 — Add container hardening to the Renovate runner

**Evidence:** `bin/renovate/run.sh:193-209`.

**Problem:** The helper runs a third-party automation container with default Docker capabilities and writable access to the repository/cache mounts. It does not use `no-new-privileges`, drop capabilities, or a read-only root filesystem. Renovate needs network access and writable repository/cache mounts, but that does not require an otherwise unrestricted container.

**Required change:**
- Add `--cap-drop=ALL` and `--security-opt=no-new-privileges`.
- Use `--read-only` with explicit writable tmpfs/cache/repository mounts as needed.
- Set resource limits where practical.
- Keep network access only because Renovate requires it; do not mount host credentials or Docker socket unnecessarily.
- Verify compatibility before enforcing a restrictive seccomp profile.

**Acceptance criteria:**
- Renovate works with the hardened container settings.
- Only repository/cache and explicitly required temporary paths are writable.
- No Docker socket or host root filesystem is mounted.

---

## P2 — Maintainability, documentation, and defense in depth

### [x] P2.1 — Resolve overlap between Dependabot and Renovate

**Evidence:** `.github/dependabot.yml`; `renovate.json`.

**Problem:** Both tools are configured to update Dockerfile dependencies and GitHub Actions. This can create duplicate PRs, competing branches, and unclear ownership of dependency policy.

**Required change:**
- Choose one owner for Dockerfile and GitHub Actions updates, or split responsibilities explicitly.
- Remove overlapping ecosystem configuration.
- Document which tool owns Envoy `VERSION`, builder/runtime images, and action digests.

**Acceptance criteria:**
- A single dependency update produces one intended PR.
- Every dependency class has an explicit owner.

### [x] P2.2 — Make the secret-scanning policy meaningful and consistent

**Evidence:** `Makefile:17-24`; `.githooks/pre-push`; `.github/workflows/security.yml`.

**Problem:** Local scans use `--only-verified`, which detects only verified credentials and can miss unverified but still sensitive material. The local and CI scan configurations differ. In addition, the supplied archive has no `.git` directory, so the Git-history scan could not be validated from this review.

**Required change:**
- Decide whether the policy is to detect all likely secrets or only verified credentials; do not present verified-only scanning as comprehensive.
- Align local and CI scan policy and document false-positive handling.
- Ensure the CI scan covers the intended commit range/history.
- Keep secret scanning read-only and avoid unnecessary container privileges.

**Acceptance criteria:**
- A known test secret fixture is detected by the chosen scanner mode.
- Local and CI policies are documented and consistent.
- Scanner failures fail the relevant check.

### [x] P2.3 — Remove unnecessary SELinux label disabling from the TruffleHog container invocation

**Evidence:** `Makefile:22-23`; `.githooks/pre-push`.

**Problem:** The Docker fallback uses `--security-opt label=disable`. Disabling container SELinux labeling weakens host isolation and appears unnecessary for read-only bind mounts. It may have been added to work around a local environment issue, but that trade-off is not documented.

**Required change:**
- Remove the option and test on supported SELinux hosts.
- If a host-specific workaround is genuinely required, make it opt-in and document the reduced isolation.

**Acceptance criteria:**
- Secret scanning works with normal container labeling on supported hosts.
- No default path disables SELinux labeling.

### [x] P2.4 — Add automated tests for shell helpers and version resolution

**Evidence:** `bin/renovate/run.sh`, `bin/install-hooks.sh`, Makefile, and workflows; no test files are present in the archive.

**Problem:** The scripts contain argument parsing, environment detection, Docker argument construction, and output parsing but have no automated tests. Regressions in these paths are easy to introduce and difficult to catch through lint alone.

**Required change:**
- Add Bats or another lightweight shell test framework.
- Test help, invalid options, missing option values, local/GitHub platform selection, token detection, summary failure handling, repository parsing, and cache paths with spaces.
- Test the Envoy version and `.bazelrc` builder-image parsers independently.
- Mock Docker/GitHub CLI rather than requiring network access in unit tests.

**Acceptance criteria:**
- Tests run in CI without credentials or a Docker daemon.
- Error paths and successful paths are covered.
- The tests verify exit codes and constructed arguments, not only output strings.

### [x] P2.5 — Improve build metadata and OCI labels

**Evidence:** `Dockerfile:31-34`.

**Problem:** The image has a few useful labels but omits useful provenance fields such as version, source revision, build date, and upstream source commit. The description is static and can become inaccurate if build settings change.

**Required change:**
- Add standard OCI version, revision, created, source, and documentation labels.
- Pass values from the validated workflow metadata.
- Avoid embedding secrets or non-deterministic values that prevent reproducible builds.

**Acceptance criteria:**
- `docker inspect` exposes the expected OCI metadata.
- The image version/revision agrees with the release metadata.

### [x] P2.6 — Document the operational contract and limitations

**Evidence:** `README.md`; `AGENTS.md`.

**Problem:** Documentation claims native multi-arch builds, hardened runtime compatibility, supply-chain controls, and smoke tests, but does not explain release semantics, mutable tags, supported Envoy version policy, local prerequisites, or what is actually tested. The Kubernetes example is only a container fragment and is not a complete workload.

**Required change:**
- Document supported architectures and the Raspberry Pi kernel/VA-space assumption precisely.
- Explain that disabling TCMalloc changes allocator behavior and that users should validate performance/memory behavior for their workload.
- Document image tags (`version`, architecture-specific tags, `latest`, commit tag) and whether version tags are immutable.
- Document local prerequisites and the difference between local single-architecture builds and CI native multi-architecture builds.
- Clearly label the Kubernetes snippet as a container fragment, or provide a complete minimal Deployment/ConfigMap example with probes and resource settings.
- Keep `AGENTS.md` aligned with actual Makefile targets and CI behavior.

**Acceptance criteria:**
- A new user can select the correct tag and run a minimal Envoy configuration.
- Documentation does not claim tests or controls that are not implemented.
- Release and support policy is explicit.

### [x] P2.7 — Add resource and performance validation for the allocator change

**Evidence:** `Dockerfile:17-27`; README rationale.

**Problem:** The central product differentiator is disabling TCMalloc, but CI only verifies that Envoy starts and validates a config. There is no benchmark or resource regression check to demonstrate the trade-off or detect a major regression in memory use/latency.

**Required change:**
- Add a small, repeatable benchmark or documented manual validation procedure on representative Raspberry Pi hardware.
- Measure startup, RSS, throughput, and latency for a representative proxy workload.
- Compare against the upstream image where it can run, and clearly state when comparison is not possible.
- Do not gate every PR on noisy hardware benchmarks; run them on demand or on scheduled hardware.

**Acceptance criteria:**
- A reproducible benchmark procedure and baseline results are documented.
- Results identify hardware, kernel, Envoy version, and workload.
- Any performance claim in README is supported by measurements.

### [x] P2.8 — Add an explicit container entrypoint/configuration behavior test

**Evidence:** `Dockerfile:36-41`; README Kubernetes example.

**Problem:** The image defaults to `/etc/envoy/envoy.yaml`, but the repository does not provide a sample config file or test that verifies the documented mount/argument behavior. Users may pull the image successfully but fail at runtime due to a missing configuration.

**Required change:**
- Add a minimal sample Envoy configuration under a clearly documented path.
- Test the default entrypoint and explicit `-c` override.
- Document that the config must be supplied by the user (if that is the intended contract).

**Acceptance criteria:**
- The default behavior is intentional and documented.
- The sample config passes Envoy validation.
- CI verifies the expected configuration path and override behavior.

---

## Suggested implementation order

1. **P0.1–P0.5:** Close workflow injection, mutable supply-chain inputs, non-blocking vulnerability scans, release-version mismatch, and excessive permissions.
2. **P1.1–P1.4:** Make build inputs consistent and immutable; make upstream updates and publication safe to rerun.
3. **P1.5–P1.9:** Test the actual hardened runtime, verify the manifest, align test claims, and fix publishing.
4. **P1.10–P1.16:** Harden and correct the Renovate helper.
5. **P2.1–P2.8:** Remove automation overlap, improve tests/documentation/metadata, and validate the allocator trade-off.

## Review notes / items not asserted

- The archive does not include Git metadata, so this review does not claim that repository history is clean or that TruffleHog history scanning succeeds.
- The review does not establish that the stated Raspberry Pi 39-bit virtual-address-space failure is universal across all Pi kernels or all Envoy builds. The project should document the exact hardware/kernel configurations on which the failure and workaround were reproduced.
- The review does not claim that every floating GitHub Action tag is currently compromised; the issue is mutable dependency identity and the resulting supply-chain/reproducibility risk.
- No external vulnerability database lookup was performed. Findings about Trivy behavior concern the workflow configuration, not the current CVE state of the image.
