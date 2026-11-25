# AGENTS.md (envoy-rpi)

Instructions for AI/code agents working in this repository.

## Purpose

`envoy-rpi` builds hardened, distroless multi-architecture container images (`linux/arm64` + `linux/amd64`) of upstream `envoyproxy/envoy` compiled with `--define tcmalloc=disabled` so Envoy runs on Raspberry Pi 64-bit (`39-bit` VA) kernels as well as `amd64`.

## Ground Rules

- **Pull requests required:** `main` is branch-protected; always open a PR instead of pushing directly to `main`.
- **Mandatory local validation before pushing:**
  - Never bypass `.githooks/pre-push` (`--no-verify` is forbidden).
  - Run `make lint` (`yamllint .`, `shellcheck`, `hadolint`, `trufflehog` git + filesystem scans) and `make unit-test` (`./tests/test_helpers.sh`).
  - `make build` resolves `ENVOY_VERSION`, `ENVOY_COMMIT`, and `BUILD_BASE` via `./bin/resolve-build-inputs.sh` and builds `envoy-rpi:local` for the host architecture.
  - `make smoke-test` runs `envoy-rpi:local` with `--read-only --cap-drop=ALL --security-opt=no-new-privileges --user 65532:65532` serving `examples/envoy.yaml`.
  - `make test` runs `lint`, `unit-test`, `build`, and `smoke-test`. Note: local `build`/`smoke-test` cover the host architecture (`linux/amd64` on x86_64); multi-arch `linux/amd64` + `linux/arm64` native builds and manifest verification run in CI.
  - `make publish` runs `lint` + `unit-test` and invokes `./bin/publish.sh` to push to `ghcr.io`.
  - `make install-hooks` configures `core.hooksPath=.githooks`.
- **Never commit secrets** (`GITHUB_TOKEN`, `.env`, private keys, etc.).
- **Keep runtime hardened & pinned:** Keep `BUILD_BASE` and `gcr.io/distroless/cc-debian13:nonroot` pinned by `@sha256:` digest, keep `ENVOY_COMMIT` verified, and keep all third-party GitHub Actions pinned to full commit SHAs.
- **Dependency ownership:** Renovate (`renovate.json`) owns `Dockerfile` digests, GitHub Action SHAs, `bin/renovate/run.sh` digest, and `VERSION`; `.github/dependabot.yml` is intentionally omitted to avoid duplicate PRs.
