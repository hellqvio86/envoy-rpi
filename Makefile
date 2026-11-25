.PHONY: help lint unit-test secrets build smoke-test test publish install-hooks renovate

CONTAINER_SELINUX_OPT ?=

help:
	@echo "Targets:"
	@echo "  lint           Run yamllint, shellcheck, hadolint, and secret scan"
	@echo "  unit-test      Run offline unit tests for helper scripts and parsers"
	@echo "  secrets        Run TruffleHog git + filesystem secret scan"
	@echo "  build          Build local envoy-rpi:local using resolved upstream inputs"
	@echo "  smoke-test     Run hardened runtime HTTP smoke test against envoy-rpi:local"
	@echo "  test           Run lint, unit-test, build, and smoke-test"
	@echo "  publish        Build and push to ghcr.io (via ./bin/publish.sh)"
	@echo "  install-hooks  Configure git core.hooksPath=.githooks"
	@echo "  renovate       Run Renovate summary locally"

lint:
	yamllint .
	shellcheck -s bash bin/resolve-build-inputs.sh bin/publish.sh bin/renovate/run.sh bin/install-hooks.sh .githooks/pre-push tests/test_helpers.sh
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
	else \
		docker run --rm -i ghcr.io/hadolint/hadolint < Dockerfile; \
	fi
	$(MAKE) secrets

unit-test:
	./tests/test_helpers.sh

secrets:
	@if command -v trufflehog >/dev/null 2>&1; then \
		trufflehog --no-update git "file://$$(pwd)" --only-verified --fail; \
		trufflehog --no-update filesystem "$$(pwd)" --only-verified --fail; \
	else \
		docker run --rm $(CONTAINER_SELINUX_OPT) -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' -v "$$(pwd):/src:ro" -w /src trufflesecurity/trufflehog:latest git file:///src --only-verified --fail && \
		docker run --rm $(CONTAINER_SELINUX_OPT) -v "$$(pwd):/src:ro" -w /src trufflesecurity/trufflehog:latest filesystem /src --only-verified --fail; \
	fi

build:
	@set -Eeuo pipefail; \
	RESOLVED="$$(./bin/resolve-build-inputs.sh)"; \
	ENVOY_VERSION="$$(printf '%s\n' "$${RESOLVED}" | awk -F= '/^ENVOY_VERSION=/{print $$2}')"; \
	ENVOY_COMMIT="$$(printf '%s\n' "$${RESOLVED}" | awk -F= '/^ENVOY_COMMIT=/{print $$2}')"; \
	BUILD_BASE="$$(printf '%s\n' "$${RESOLVED}" | awk -F= '/^BUILD_BASE=/{print $$2}')"; \
	docker buildx build --load \
		--build-arg "ENVOY_VERSION=$${ENVOY_VERSION}" \
		--build-arg "ENVOY_COMMIT=$${ENVOY_COMMIT}" \
		--build-arg "BUILD_BASE=$${BUILD_BASE}" \
		-t envoy-rpi:local .

smoke-test:
	@set -Eeuo pipefail; \
	docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges --user 65532:65532 envoy-rpi:local --version; \
	docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges --user 65532:65532 \
		-v "$$(pwd)/examples/envoy.yaml:/etc/envoy/envoy.yaml:ro" envoy-rpi:local --mode validate -c /etc/envoy/envoy.yaml; \
	CID="$$(docker run -d --read-only --cap-drop=ALL --security-opt=no-new-privileges --user 65532:65532 \
		-p 18080:8080 -v "$$(pwd)/examples/envoy.yaml:/etc/envoy/envoy.yaml:ro" envoy-rpi:local)"; \
	trap 'docker rm -f "$${CID}" >/dev/null 2>&1 || true' EXIT; \
	for _ in $$(seq 1 15); do \
		if curl -fsS http://127.0.0.1:18080/ | grep -qx 'ok'; then \
			echo "✅ Hardened runtime HTTP check passed."; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	docker logs "$${CID}" || true; \
	exit 1

publish: lint unit-test
	./bin/publish.sh

test: lint unit-test build smoke-test

install-hooks:
	./bin/install-hooks.sh

renovate:
	./bin/renovate/run.sh --summary
