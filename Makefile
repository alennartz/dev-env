.PHONY: build-proxy build-base build-base-podman build-netjail build-all push test test-dind test-bwrap test-macos clean help

# Registry and owner for pushing images
REGISTRY ?= ghcr.io
OWNER ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+)/.*|\1|' || echo "OWNER")

# Build options
NO_CACHE ?=
CACHE_FLAG := $(if $(NO_CACHE),--no-cache,)

help:
	@echo "Claude Code Sandbox - Build Commands"
	@echo ""
	@echo "Local Development:"
	@echo "  make build-all          Build all images locally"
	@echo "  make build-proxy        Build proxy image"
	@echo "  make build-base         Build base sandbox image"
	@echo "  make build-base-podman  Build Podman-enabled sandbox image"
	@echo "  make build-netjail      Build network jail image (for bwrap mode)"
	@echo "  make test               Test both images (API connectivity + auth)"
	@echo "  make test-dind          Test Docker-in-Docker with Podman image"
	@echo "  make test-bwrap         Test bubblewrap sandbox mode"
	@echo "  make test-macos         Test macOS sandbox mode (macOS only)"
	@echo "  make clean              Remove containers and images"
	@echo ""
	@echo "Publishing (requires docker login to GHCR):"
	@echo "  make push               Push all images to GHCR"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  OWNER=$(OWNER)"
	@echo "  NO_CACHE=1              Skip Docker build cache"

# Build individual images
build-proxy:
	docker build $(CACHE_FLAG) -t claude-sandbox-proxy:latest ./images/proxy

build-base:
	docker build $(CACHE_FLAG) -t claude-sandbox-base:latest ./images/base

build-base-podman: build-base
	docker build $(CACHE_FLAG) -t claude-sandbox-base-podman:latest ./images/base-podman

build-netjail:
	docker build $(CACHE_FLAG) -t claude-netjail:latest ./images/netjail

# Build all images
build-all: build-proxy build-base build-base-podman build-netjail

# Push to GHCR (requires docker login)
push: build-all
	docker tag claude-sandbox-proxy:latest $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker tag claude-sandbox-base:latest $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest
	docker tag claude-sandbox-base-podman:latest $(REGISTRY)/$(OWNER)/claude-sandbox-base-podman:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-base-podman:latest

# Test the setup using docker compose (uses .devcontainer/docker-compose.yml directly)
test: build-all
	@echo "=== Starting containers ==="
	docker compose -f .devcontainer/docker-compose.yml up -d
	@echo "Waiting for containers to be ready..."
	@sleep 3
	@echo ""
	@echo "=== Running tests ==="
	@echo "  Checking Claude version..."
	docker compose -f .devcontainer/docker-compose.yml exec -T -u developer sandbox claude --version
	@echo "  Testing API connectivity and authentication..."
	@docker compose -f .devcontainer/docker-compose.yml exec -T -u developer sandbox claude -p "Reply with only: TEST_OK" --max-turns 1 2>&1 | grep -q "TEST_OK" && \
		echo "  ✓ All tests passed" || \
		(echo "  ✗ Tests failed" && exit 1)
	@echo ""
	@echo "=== Stopping containers ==="
	docker compose -f .devcontainer/docker-compose.yml down

# Test Docker-in-Docker with Podman image
test-dind: build-all
	@echo "=== Starting Podman-enabled containers ==="
	LOCAL_WORKSPACE_FOLDER_BASENAME=dev-env docker compose -f .devcontainer/docker-compose.yml up -d sandbox-podman proxy
	@echo "Waiting for containers to be ready..."
	@sleep 5
	@echo ""
	@echo "=== Testing Podman functionality ==="
	@echo "  Testing podman run with alpine..."
	docker compose -f .devcontainer/docker-compose.yml exec -T sandbox-podman gosu developer podman run --rm docker.io/library/alpine echo "SUCCESS: Podman works"
	@echo ""
	@echo "  Testing docker alias..."
	docker compose -f .devcontainer/docker-compose.yml exec -T sandbox-podman gosu developer bash -c 'source ~/.profile && docker run --rm docker.io/library/alpine echo "SUCCESS: docker alias works"'
	@echo ""
	@echo "=== Stopping containers ==="
	docker compose -f .devcontainer/docker-compose.yml down

# Test bubblewrap sandbox mode
test-bwrap: build-netjail
	@echo "=== Testing bubblewrap sandbox mode ==="
	@echo "Note: Requires bubblewrap, fuse-overlayfs installed on host"
	@command -v bwrap >/dev/null || (echo "Error: bubblewrap not installed" && exit 1)
	@command -v fuse-overlayfs >/dev/null || (echo "Error: fuse-overlayfs not installed" && exit 1)
	@echo ""
	@echo "Starting network jail..."
	./claude-sandbox-bwrap.sh --stop 2>/dev/null || true
	docker run -d --name claude-netjail --cap-add NET_ADMIN -v claude-netjail-ssl:/etc/squid/ssl claude-netjail:latest
	@sleep 3
	@echo ""
	@echo "Testing network jail is running..."
	docker exec claude-netjail pgrep squid && echo "  ✓ Squid running" || (echo "  ✗ Squid not running" && exit 1)
	@echo ""
	@echo "Stopping network jail..."
	./claude-sandbox-bwrap.sh --stop
	@echo ""
	@echo "=== Basic tests passed ==="
	@echo "To run full test: ./claude-sandbox-bwrap.sh ~/some-project"

# Test macOS sandbox mode
test-macos: build-netjail
	@echo "=== Testing macOS sandbox mode ==="
	@test "$$(uname -s)" = "Darwin" || (echo "Error: macOS only" && exit 1)
	@echo ""
	@echo "Starting network jail (port-mapped)..."
	./claude-sandbox-macos.sh --stop 2>/dev/null || true
	docker run -d --name claude-netjail-macos --cap-add NET_ADMIN \
		-p 127.0.0.1:3128:3128 -p 127.0.0.1:3129:3129 \
		-v claude-netjail-ssl:/etc/squid/ssl claude-netjail:latest
	@sleep 3
	@echo ""
	@echo "Testing network jail is running..."
	docker exec claude-netjail-macos pgrep squid && echo "  ✓ Squid running" || (echo "  ✗ Squid not running" && exit 1)
	@echo ""
	@echo "Testing Squid is listening on mapped ports..."
	@curl -sf --max-time 2 -o /dev/null http://127.0.0.1:3128/ 2>/dev/null; \
		if [ $$? -ne 0 ] && [ $$? -ne 56 ]; then \
			echo "  ✗ Port 3128 not responding"; exit 1; \
		else echo "  ✓ Port 3128 responding"; fi
	@echo ""
	@echo "Stopping network jail..."
	./claude-sandbox-macos.sh --stop
	@echo ""
	@echo "=== Basic tests passed ==="
	@echo "To run full test: ./claude-sandbox-macos.sh ~/some-project"

# Clean up
clean:
	docker compose -f .devcontainer/docker-compose.yml down -v 2>/dev/null || true
	./claude-sandbox-bwrap.sh --stop 2>/dev/null || true
	./claude-sandbox-macos.sh --stop 2>/dev/null || true
	docker rmi claude-sandbox-proxy:latest claude-sandbox-base:latest claude-sandbox-base-podman:latest claude-netjail:latest 2>/dev/null || true
	@echo "Cleaned up containers and images"
