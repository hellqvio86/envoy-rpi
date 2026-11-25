.PHONY: lint build test secrets install-hooks renovate

lint:
	yamllint .
	shellcheck -s bash bin/renovate/run.sh bin/install-hooks.sh .githooks/pre-push
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
	else \
		docker run --rm -i ghcr.io/hadolint/hadolint < Dockerfile; \
	fi
	$(MAKE) secrets

secrets:
	@if command -v trufflehog >/dev/null 2>&1; then \
		trufflehog --no-update git "file://$$(pwd)" --only-verified --fail; \
		trufflehog --no-update filesystem "$$(pwd)" --only-verified --fail; \
	else \
		docker run --rm --security-opt label=disable -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' -v "$$(pwd):/src:ro" -w /src trufflesecurity/trufflehog:latest git file:///src --only-verified --fail && \
		docker run --rm --security-opt label=disable -v "$$(pwd):/src:ro" -w /src trufflesecurity/trufflehog:latest filesystem /src --only-verified --fail; \
	fi

build:
	@ENVOY_VERSION="$$(tr -d '[:space:]' < VERSION)"; \
	BUILD_BASE="$$(grep -E '^ARG BUILD_BASE=' Dockerfile | head -n 1 | cut -d= -f2-)"; \
	docker buildx build --load \
		--build-arg "ENVOY_VERSION=$${ENVOY_VERSION}" \
		--build-arg "BUILD_BASE=$${BUILD_BASE}" \
		-t envoy-rpi:local .
	docker run --rm envoy-rpi:local --version

test: lint build

install-hooks:
	./bin/install-hooks.sh

renovate:
	./bin/renovate/run.sh --summary
