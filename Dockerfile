# syntax=docker/dockerfile:1

ARG ENVOY_VERSION=v1.36.13
ARG BUILD_BASE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c

FROM ${BUILD_BASE} AS builder

ARG ENVOY_VERSION
ARG TARGETARCH

WORKDIR /src

RUN git clone --depth 1 --branch "${ENVOY_VERSION}" https://github.com/envoyproxy/envoy.git /src/envoy

WORKDIR /src/envoy

# Disable Google TCMalloc (which assumes 48-bit VA) so Envoy runs on 39-bit arm64 Raspberry Pi kernels.
RUN --mount=type=cache,target=/root/.cache/bazel,id=bazel-${TARGETARCH} \
    bazel build \
      --config=clang \
      --define tcmalloc=disabled \
      -c opt \
      //source/exe:envoy-static && \
    cp bazel-bin/source/exe/envoy-static /usr/local/bin/envoy && \
    strip --strip-unneeded /usr/local/bin/envoy

FROM gcr.io/distroless/cc-debian12:nonroot

LABEL org.opencontainers.image.title="envoy-rpi" \
      org.opencontainers.image.description="Multi-arch distroless Envoy Proxy compiled with --define tcmalloc=disabled for Raspberry Pi (39-bit arm64) and amd64" \
      org.opencontainers.image.source="https://github.com/hellqvio86/envoy-rpi" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /usr/local/bin/envoy /usr/local/bin/envoy

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]
