.PHONY: lint build install-hooks

lint:
	yamllint .
	shellcheck -s bash bin/renovate/run.sh bin/install-hooks.sh .githooks/pre-push
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
	else \
		docker run --rm -i ghcr.io/hadolint/hadolint < Dockerfile; \
	fi

build:
	docker buildx build --load -t envoy-rpi:local .
	docker run --rm envoy-rpi:local --version

install-hooks:
	./bin/install-hooks.sh
