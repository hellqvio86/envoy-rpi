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
- **Distroless & hardened runtime** (`gcr.io/distroless/cc-debian12:nonroot`, UID `65532`) compatible with Kubernetes `restricted` Pod Security Standards (`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`).
- **Supply-chain security:** Trivy vulnerability scanning, CycloneDX SBOM generation, and GitHub SLSA build provenance attestations.

---

## 📦 Using the Image

```bash
docker pull ghcr.io/hellqvio86/envoy-rpi:v1.36.13
```

### Kubernetes Example (`restricted` Pod Security)
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

---

## 🔄 CI/CD & Automation

- **[`.github/workflows/build.yml`](.github/workflows/build.yml):**
  - Builds `linux/amd64` and `linux/arm64` natively in parallel.
  - Smoke-tests `envoy --version` and `envoy --mode validate` on both architectures.
  - Scans images with **Trivy** (`CRITICAL,HIGH`).
  - Merges into a multi-arch OCI manifest on `ghcr.io/hellqvio86/envoy-rpi`, attaches a CycloneDX SBOM, and generates SLSA build provenance attestations.
- **[`.github/workflows/check-upstream.yml`](.github/workflows/check-upstream.yml):**
  - Weekly scheduled check against `envoyproxy/envoy` releases; automatically opens a PR updating `VERSION` when a new stable release is published.

---

<p align="right">
  <a href="https://www.buymeacoffee.com/olofhellqvc">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="48">
  </a>
</p>
