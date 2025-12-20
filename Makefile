.PHONY: build-proxy build-base build-base-alpine build-all push test test-image clean help

# Registry and owner for pushing images
REGISTRY ?= ghcr.io
OWNER ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+)/.*|\1|' || echo "OWNER")

help:
	@echo "Claude Code Sandbox - Build Commands"
	@echo ""
	@echo "Local Development:"
	@echo "  make build-all          Build all images locally"
	@echo "  make build-proxy        Build proxy image"
	@echo "  make build-base         Build base sandbox image (Debian slim)"
	@echo "  make build-base-alpine  Build base sandbox image (Alpine)"
	@echo "  make test               Test both images (API connectivity + auth)"
	@echo "  make clean              Remove containers and images"
	@echo ""
	@echo "Publishing (requires docker login to GHCR):"
	@echo "  make push               Push all images to GHCR"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  OWNER=$(OWNER)"

# Build individual images
build-proxy:
	docker build -t claude-sandbox-proxy:latest ./images/proxy

build-base:
	docker build -t claude-sandbox-base:latest ./images/base

build-base-alpine:
	docker build -t claude-sandbox-base:alpine -f ./images/base/Dockerfile.alpine ./images/base

# Build all images
build-all: build-proxy build-base build-base-alpine

# Push to GHCR (requires docker login)
push: build-all
	docker tag claude-sandbox-proxy:latest $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker tag claude-sandbox-base:latest $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest
	docker tag claude-sandbox-base:alpine $(REGISTRY)/$(OWNER)/claude-sandbox-base:alpine
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-base:alpine

# Test the setup - tests both Debian and Alpine images
test: build-all
	@echo "=== Starting proxy ==="
	docker compose -f .devcontainer/docker-compose.yml up -d proxy
	@echo "Waiting for proxy CA certificate..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		docker compose -f .devcontainer/docker-compose.yml exec -T proxy test -f /etc/squid/ssl/squid-ca-cert.pem && break || sleep 1; \
	done
	@echo ""
	@echo "=== Testing Debian image (claude-sandbox-base:latest) ==="
	@$(MAKE) --no-print-directory test-image IMAGE=claude-sandbox-base:latest SHELL_CMD=/bin/bash
	@echo ""
	@echo "=== Testing Alpine image (claude-sandbox-base:alpine) ==="
	@$(MAKE) --no-print-directory test-image IMAGE=claude-sandbox-base:alpine SHELL_CMD=/bin/sh
	@echo ""
	@echo "=== Stopping containers ==="
	docker compose -f .devcontainer/docker-compose.yml down
	@echo ""
	@echo "All tests passed!"

# Test a single image (used by test target)
test-image:
	@PROXY_ID=$$(docker compose -f .devcontainer/docker-compose.yml ps -q proxy) && \
	VOLUME_NAME=$$(docker inspect $$PROXY_ID --format '{{range .Mounts}}{{if eq .Destination "/etc/squid/ssl"}}{{.Name}}{{end}}{{end}}') && \
	echo "Starting container with $(IMAGE)..." && \
	CONTAINER=$$(docker run --rm -d \
		--network container:$$PROXY_ID \
		-e NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-ca-cert.pem \
		-v $$VOLUME_NAME:/etc/squid/ssl:ro \
		-v $(HOME)/.claude/.credentials.json:/tmp/claude-creds/.credentials.json:ro \
		-v $(HOME)/.claude/settings.json:/tmp/claude-creds/settings.json:ro \
		--entrypoint $(SHELL_CMD) \
		$(IMAGE) \
		/usr/local/bin/trust-proxy-ca.sh sleep infinity) && \
	sleep 2 && \
	echo "  Checking Claude version..." && \
	docker exec -u developer $$CONTAINER claude --version && \
	echo "  Testing API connectivity and authentication..." && \
	docker exec -u developer $$CONTAINER claude -p "Reply with only: TEST_OK" --max-turns 1 2>&1 | grep -q "TEST_OK" && \
	echo "  ✓ $(IMAGE) passed all tests" && \
	docker stop $$CONTAINER > /dev/null || \
	(echo "  ✗ $(IMAGE) failed" && docker stop $$CONTAINER 2>/dev/null; exit 1)

# Clean up
clean:
	docker compose -f .devcontainer/docker-compose.yml down -v 2>/dev/null || true
	docker rmi claude-sandbox-proxy:latest claude-sandbox-base:latest claude-sandbox-base:alpine 2>/dev/null || true
	@echo "Cleaned up containers and images"
