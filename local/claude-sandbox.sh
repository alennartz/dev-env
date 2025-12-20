#!/bin/bash
# Launch Claude Code in the sandbox environment
# Starts containers if not running, then execs into sandbox with claude in yolo mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[sandbox]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[sandbox]${NC} $1"
}

error() {
    echo -e "${RED}[sandbox]${NC} $1"
}

# Check if containers are running
is_running() {
    docker compose -f "$COMPOSE_FILE" ps --status running 2>/dev/null | grep -q sandbox
}

# Start containers if not running
start_containers() {
    if is_running; then
        log "Containers already running"
    else
        log "Starting containers..."

        # Generate .env file for compose
        WORKSPACE_NAME=$(basename "$REPO_ROOT")
        echo "LOCAL_WORKSPACE_FOLDER_BASENAME=$WORKSPACE_NAME" > "$REPO_ROOT/.devcontainer/.env"

        docker compose -f "$COMPOSE_FILE" up -d

        # Wait for proxy health check
        log "Waiting for proxy to be healthy..."
        for i in {1..30}; do
            if docker compose -f "$COMPOSE_FILE" ps --status running 2>/dev/null | grep -q "proxy.*healthy"; then
                log "Proxy is healthy"
                break
            fi
            sleep 1
        done
    fi
}

# Main
start_containers

log "Launching Claude Code in sandbox..."
docker compose -f "$COMPOSE_FILE" exec -u developer -it sandbox claude --dangerously-skip-permissions
