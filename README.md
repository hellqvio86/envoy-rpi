# 🛡️ envoy-rpi — Multi-Arch Envoy Proxy for Raspberry Pi (`arm64`) & `amd64`

[![Build & Publish Multi-Arch Envoy](https://github.com/hellqvio86/envoy-rpi/actions/workflows/build.yml/badge.svg)](https://github.com/hellqvio86/envoy-rpi/actions/workflows/build.yml)
[![Check Upstream Envoy](https://github.com/hellqvio86/envoy-rpi/actions/workflows/check-upstream.yml/badge.svg)](https://github.com/hellqvio86/envoy-rpi/actions/workflows/check-upstream.yml)
[![GitHub Release](https://img.shields.io/github/v/release/hellqvio86/envoy-rpi)](https://github.com/hellqvio86/envoy-rpi/releases)
![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-blue)
![Distroless](https://img.shields.io/badge/distroless-nonroot%20(65532)-green)
[![License](https://img.shields.io/github/license/hellqvio86/envoy-rpi)](LICENSE)
![GitHub last commit](https://img.shields.io/github/last-commit/hellqvio86/envoy-rpi)

Hardened, distroless multi-architecture container images (`linux/arm64` + `linux/amd64`) of [Envoy Proxy](https://www.envoyproxy.io/) built from upstream source with **`--define tcmalloc=disabled`** so Envoy runs reliably on **Raspberry Pi 64-bit (`39-bit` VA) kernels** as well as standard `amd64` servers.

---

## ❓ Why This Repository Exists

The official upstream `envoyproxy/envoy` `arm64` Docker images are compiled with Google's modern **TCMalloc** allocator, which hardcodes an assumption that the Linux kernel provides a **48-bit virtual address space (`256 TiB`)**.

Most 64-bit Raspberry Pi kernels (Raspberry Pi OS / Debian `arm64`) use a **39-bit virtual address space (`512 GiB`)** to save a page-table level. As a result, running any official `envoyproxy/envoy` image on a Raspberry Pi crashes immediately on startup:

```text
MmapAligned() failed - unable to allocate with tag (hint=0xfc980000000, size=1073741824, alignment=1073741824)
Note: the allocation may have failed because TCMalloc assumes a 48-bit virtual address space size
CHECK in Alloc: FATAL ERROR: Out of memory trying to allocate internal tcmalloc data
```

### How `envoy-rpi` Solves It
- **Built from official upstream `envoyproxy/envoy` tags** (tracked in [`VERSION`](VERSION)).
- **Compiled with `--define tcmalloc=disabled`** so Envoy uses standard `glibc` `malloc`, which respects 39-bit `arm64` virtual memory layouts.
- **Native CI builds** on GitHub's `ubuntu-latest` (`amd64`) and `ubuntu-24.04-arm` (`arm64`) runners — no slow QEMU emulation.
- **Distroless & hardened runtime** (`gcr.io/distroless/cc-debian13:nonroot`, UID `65532`) compatible with Kubernetes `restricted` Pod Security Standards (`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`).
- **Supply-chain security:** Trivy vulnerability scanning, CycloneDX SBOM generation, and GitHub SLSA build provenance attestations.

---

## 📦 Using the Image

```bash
docker pull ghcr.io/hellqvio86/envoy-rpi:v1.36.13
```

### Kubernetes Container Fragment

> Note: This is a container/securityContext fragment; provide your own `Deployment`, `ConfigMap` (mounted at `/etc/envoy/envoy.yaml` — see [`examples/envoy.yaml`](examples/envoy.yaml)), `Service`, and probes.

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: envoy
    image: ghcr.io/hellqvio86/envoy-rpi:v1.36.13
    args: ["-c", "/etc/envoy/envoy.yaml"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

### Allocator Trade-Off & Validation

Compiling with `--define tcmalloc=disabled` replaces Google's 48-bit TCMalloc with standard `glibc` `malloc`. For homelab/edge proxy workloads this eliminates the `39-bit` ARM64 `MmapAligned()` crash, though high-concurrency throughput/RSS characteristics differ from upstream TCMalloc builds — validate resource limits against your target workload.

### Image Tags & Release Policy

- `vMAJOR.MINOR.PATCH` (e.g. `v1.36.13`): Multi-arch OCI manifest (`linux/amd64` + `linux/arm64`), published on matching Git tag push.
- `latest`: Tracks the latest published multi-arch manifest on `main`.
- `sha-<short>`: Commit-specific multi-arch manifest.

---

## 🔄 CI/CD & Automation

- **[`.github/workflows/build.yml`](.github/workflows/build.yml):**
  - Runs offline unit tests (`./tests/test_helpers.sh`), then builds `linux/amd64` and `linux/arm64` natively in parallel using `./bin/resolve-build-inputs.sh`.
  - Runs hardened runtime HTTP smoke tests (`--read-only --cap-drop=ALL --security-opt=no-new-privileges --user 65532:65532`) with [`examples/envoy.yaml`](examples/envoy.yaml) on both architectures.
  - Scans images with **Trivy** (`CRITICAL,HIGH`, `exit-code: 1`, `ignore-unfixed: true`, SARIF upload to GitHub Security).
  - Verifies both `linux/amd64` and `linux/arm64` platforms in the merged OCI manifest on `ghcr.io/hellqvio86/envoy-rpi`, attaches a CycloneDX SBOM, generates SLSA build provenance attestations, and manages Draft/Published GitHub Releases.
- **[`.github/workflows/security.yml`](.github/workflows/security.yml):** Daily + PR/push TruffleHog secret scan and Trivy filesystem scan.
- **[`.github/workflows/check-upstream.yml`](.github/workflows/check-upstream.yml):** Weekly idempotent check against `envoyproxy/envoy` releases.

---

<p align="right">
  <a href="https://www.buymeacoffee.com/olofhellqvc">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="48">
  </a>
</p>
