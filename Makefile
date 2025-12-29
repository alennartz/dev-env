.PHONY: build-proxy build-base build-base-podman build-all push test test-dind clean help

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
	@echo "  make test               Test both images (API connectivity + auth)"
	@echo "  make test-dind          Test Docker-in-Docker with Podman image"
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

# Build all images
build-all: build-proxy build-base build-base-podman

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

# Clean up
clean:
	docker compose -f .devcontainer/docker-compose.yml down -v 2>/dev/null || true
	docker rmi claude-sandbox-proxy:latest claude-sandbox-base:latest claude-sandbox-base-podman:latest 2>/dev/null || true
	@echo "Cleaned up containers and images"
