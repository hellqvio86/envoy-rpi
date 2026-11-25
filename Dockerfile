# syntax=docker/dockerfile:1

ARG ENVOY_VERSION=v1.36.13
ARG ENVOY_COMMIT=eb0a95ba450a3e29a9a8e75f672e2c294493eea2
ARG BUILD_BASE=envoyproxy/envoy-build-ubuntu:86873047235e9b8232df989a5999b9bebf9db69c@sha256:1b3c82ca34c505c4951918b2e0a0c3db88cf266ebbf4196e4b0fba8fa137ada3
ARG BUILD_DATE=""
ARG VCS_REF=""

FROM ${BUILD_BASE} AS builder

ARG ENVOY_VERSION
ARG ENVOY_COMMIT
ARG TARGETARCH

WORKDIR /src/envoy

# Fetch and verify the exact upstream Envoy commit SHA (never trust a mutable tag alone).
RUN git init && \
    git remote add origin https://github.com/envoyproxy/envoy.git && \
    git fetch --depth 1 origin "${ENVOY_COMMIT}" && \
    git checkout --detach FETCH_HEAD && \
    RESOLVED_SHA="$(git rev-parse HEAD)" && \
    test "${RESOLVED_SHA}" = "${ENVOY_COMMIT}"

# Disable Google TCMalloc (which assumes 48-bit VA) so Envoy runs on 39-bit arm64 Raspberry Pi kernels.
RUN --mount=type=cache,target=/root/.cache/bazel,id=bazel-${TARGETARCH} \
    ./bazel/setup_clang.sh /opt/llvm && \
    export PATH="/opt/llvm/bin:${PATH}" CC=clang CXX=clang++ && \
    bazel build \
      --config=clang \
      --define tcmalloc=disabled \
      -c opt \
      //source/exe:envoy-static && \
    cp bazel-bin/source/exe/envoy-static /usr/local/bin/envoy && \
    strip --strip-unneeded /usr/local/bin/envoy

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:532c7a94f9e96ba9db75eb9388f4227751131c7cb0a411d1a8521af4096135de

ARG ENVOY_VERSION
ARG ENVOY_COMMIT
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="envoy-rpi" \
      org.opencontainers.image.description="Multi-arch distroless Envoy Proxy compiled with --define tcmalloc=disabled for Raspberry Pi (39-bit arm64) and amd64" \
      org.opencontainers.image.version="${ENVOY_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/hellqvio86/envoy-rpi" \
      org.opencontainers.image.documentation="https://github.com/hellqvio86/envoy-rpi/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.envoyproxy.source.commit="${ENVOY_COMMIT}"

COPY --from=builder /usr/local/bin/envoy /usr/local/bin/envoy

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]
