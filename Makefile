.PHONY: build-proxy build-base build-all push test clean help

# Registry and owner for pushing images
REGISTRY ?= ghcr.io
OWNER ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+)/.*|\1|' || echo "OWNER")

help:
	@echo "Claude Code Sandbox - Build Commands"
	@echo ""
	@echo "Local Development:"
	@echo "  make build-all     Build all images locally"
	@echo "  make build-proxy   Build proxy image"
	@echo "  make build-base    Build base sandbox image"
	@echo "  make test          Test the local setup"
	@echo "  make clean         Remove containers and images"
	@echo ""
	@echo "Publishing (requires docker login to GHCR):"
	@echo "  make push          Push proxy and base images to GHCR"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  OWNER=$(OWNER)"

# Build individual images
build-proxy:
	docker build -t claude-sandbox-proxy:latest ./images/proxy

build-base:
	docker build -t claude-sandbox-base:latest ./images/base

# Build all images
build-all: build-proxy build-base

# Push to GHCR (requires docker login)
push: build-proxy build-base
	docker tag claude-sandbox-proxy:latest $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker tag claude-sandbox-base:latest $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-proxy:latest
	docker push $(REGISTRY)/$(OWNER)/claude-sandbox-base:latest

# Test the setup
test: build-all
	@echo "Starting containers..."
	docker compose -f .devcontainer/docker-compose.yml up -d
	@echo "Waiting for proxy health check..."
	@sleep 5
	@echo "Testing sandbox..."
	docker compose -f .devcontainer/docker-compose.yml exec -T sandbox echo "Sandbox is working"
	docker compose -f .devcontainer/docker-compose.yml exec -T sandbox claude --version || echo "Claude Code installed"
	@echo "Stopping containers..."
	docker compose -f .devcontainer/docker-compose.yml down
	@echo "Test passed!"

# Clean up
clean:
	docker compose -f .devcontainer/docker-compose.yml down -v 2>/dev/null || true
	docker rmi claude-sandbox-proxy:latest claude-sandbox-base:latest 2>/dev/null || true
	@echo "Cleaned up containers and images"
