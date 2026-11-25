# AGENTS.md (envoy-rpi)

Instructions for AI/code agents working in this repository.

## Purpose

`envoy-rpi` builds hardened, distroless multi-architecture container images (`linux/arm64` + `linux/amd64`) of upstream `envoyproxy/envoy` compiled with `--define tcmalloc=disabled` so Envoy runs on Raspberry Pi 64-bit (`39-bit` VA) kernels as well as `amd64`.

## Ground Rules

- **Pull requests required:** `main` is branch-protected; always open a PR instead of pushing directly to `main`.
- **Lint & local build before pushing:**
  - `make lint` runs `yamllint .`, `shellcheck`, and `hadolint` on `Dockerfile`.
  - `make build` runs `docker buildx build --load -t envoy-rpi:local .` and smoke-tests `envoy --version`.
  - `make install-hooks` configures `core.hooksPath=.githooks`.
  - `.githooks/pre-push` automatically runs `yamllint`, `shellcheck`, `hadolint`, and the local `docker buildx build` + smoke test on every `git push`.
- **Never commit secrets** (`GITHUB_TOKEN`, `.env`, private keys, etc.).
- **Keep runtime hardened:** Keep the runtime stage distroless non-root (`gcr.io/distroless/cc-debian12:nonroot`, UID/GID `65532`).
- **Keep release & Renovate workflows intact:**
  - `VERSION` tracks the upstream `envoyproxy/envoy` tag.
  - `.github/workflows/build.yml` resolves `BUILD_BASE` from upstream `.bazelrc`, builds `amd64` + `arm64` natively, runs Trivy + smoke tests, publishes to `ghcr.io/hellqvio86/envoy-rpi`, attaches `sbom.cdx.json` + SLSA provenance, and creates/updates the GitHub Draft Release (or publishes on `v*` tags).
  - Run `./bin/renovate/run.sh --summary` to inspect Renovate updates locally.
