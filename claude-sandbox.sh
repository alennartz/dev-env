#!/bin/bash
# Launch Claude Code in a sandboxed environment from any repository
# Can be aliased in shell: alias claude-sandbox='/path/to/dev-env/claude-sandbox.sh'

set -e

# =============================================================================
# Path Resolution
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_ROOT="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[sandbox]${NC} $1"; }
warn() { echo -e "${YELLOW}[sandbox]${NC} $1"; }
error() { echo -e "${RED}[sandbox]${NC} $1"; }
info() { echo -e "${BLUE}[sandbox]${NC} $1"; }

# =============================================================================
# Usage / Help
# =============================================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Launch Claude Code in a sandboxed Docker environment.

Options:
    --repo PATH     Use PATH as the target repository (default: current directory)
    --status        Show status of running sandbox containers
    --stop          Stop running sandbox containers
    --help          Show this help message

Image Selection (automatic):
    1. If target repo has .devcontainer/ with proxy/sandbox services, use that
    2. If local Docker has claude-sandbox-* images, use those
    3. Fall back to GHCR images (ghcr.io/alennartz/claude-sandbox-*)

Whitelist Selection (automatic):
    1. Target repo's .devcontainer/whitelist.txt if exists
    2. Dev-env's local/whitelist.txt as fallback
    3. Image's built-in minimal whitelist

Examples:
    $(basename "$0")                    # Run in current directory
    $(basename "$0") --repo ~/myproject # Run with specific repo
    $(basename "$0") --status           # Check container status
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================
TARGET_REPO="$PWD"
ACTION="run"

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            TARGET_REPO="$2"
            shift 2
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Resolve to absolute path
TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
WORKSPACE_NAME=$(basename "$TARGET_REPO")

# Temp directory for generated compose file (persistent across runs for same repo)
REPO_HASH=$(echo "$TARGET_REPO" | md5sum | cut -c1-8)
TEMP_DIR="/tmp/claude-sandbox-$REPO_HASH"

# =============================================================================
# Detection Functions
# =============================================================================

# Check if target repo has a compatible .devcontainer setup
# Returns 0 if compatible setup found, 1 otherwise
has_local_devcontainer() {
    local compose_file="$TARGET_REPO/.devcontainer/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        # Check for both proxy: and sandbox: service definitions
        if grep -q "^[[:space:]]*proxy:" "$compose_file" && \
           grep -q "^[[:space:]]*sandbox:" "$compose_file"; then
            return 0
        fi
    fi
    return 1
}

# Check if local Docker has the sandbox images
# Returns 0 if images exist locally, 1 otherwise
has_local_images() {
    docker image inspect claude-sandbox-proxy:latest >/dev/null 2>&1 && \
    docker image inspect claude-sandbox-base:latest >/dev/null 2>&1
}

# Detect the image source to use
# Returns: "local-compose" | "local-images" | "ghcr"
detect_image_source() {
    if has_local_devcontainer; then
        echo "local-compose"
    elif has_local_images; then
        echo "local-images"
    else
        echo "ghcr"
    fi
}

# =============================================================================
# Whitelist Resolution
# =============================================================================

# Find the whitelist file to use
# Returns path to whitelist file, or empty if using image default
resolve_whitelist() {
    local target_whitelist="$TARGET_REPO/.devcontainer/whitelist.txt"
    local devenv_whitelist="$DEV_ENV_ROOT/local/whitelist.txt"

    if [[ -f "$target_whitelist" ]]; then
        echo "$target_whitelist"
    elif [[ -f "$devenv_whitelist" ]]; then
        echo "$devenv_whitelist"
    else
        echo ""  # Use image default
    fi
}

# =============================================================================
# Compose File Generation
# =============================================================================

generate_compose_file() {
    local image_source="$1"
    local whitelist_path="$2"

    mkdir -p "$TEMP_DIR"

    # Determine image references
    local proxy_image sandbox_image
    if [[ "$image_source" == "local-images" ]]; then
        proxy_image="claude-sandbox-proxy:latest"
        sandbox_image="claude-sandbox-base:latest"
    else
        proxy_image="ghcr.io/alennartz/claude-sandbox-proxy:latest"
        sandbox_image="ghcr.io/alennartz/claude-sandbox-base:latest"
    fi

    # Build whitelist volume mount
    local whitelist_volume=""
    if [[ -n "$whitelist_path" ]]; then
        whitelist_volume="- $whitelist_path:/etc/squid/whitelist.txt:ro"
    fi

    # Build git credentials mount (only if file exists)
    local git_credentials_volume=""
    if [[ -f "$HOME/.git-credentials" ]]; then
        git_credentials_volume="- \${HOME}/.git-credentials:/home/developer/.git-credentials:ro"
    fi

    # Generate compose file
    cat > "$TEMP_DIR/docker-compose.yml" <<EOF
# Auto-generated by claude-sandbox.sh
# Target repo: $TARGET_REPO
# Image source: $image_source

services:
  proxy:
    image: $proxy_image
    cap_add:
      - NET_ADMIN
    volumes:
      - squid-ssl:/etc/squid/ssl
      ${whitelist_volume:+$whitelist_volume}
    healthcheck:
      test: ["CMD", "squid", "-k", "check"]
      interval: 5s
      timeout: 5s
      retries: 3
      start_period: 10s

  sandbox:
    image: $sandbox_image
    network_mode: "service:proxy"
    depends_on:
      proxy:
        condition: service_healthy
    environment:
      - NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-ca-cert.pem
      - WORKSPACE_FOLDER=\${LOCAL_WORKSPACE_FOLDER_BASENAME}
    volumes:
      - squid-ssl:/etc/squid/ssl:ro
      - $TARGET_REPO:/workspaces/\${LOCAL_WORKSPACE_FOLDER_BASENAME}:cached
      # Mount Claude binary directory (entrypoint creates symlink in ~/.local/bin)
      - \${HOME}/.local/share/claude:/home/developer/.local/share/claude:ro
      # Mount Claude config directly (RW)
      - \${HOME}/.claude:/home/developer/.claude:cached
      - \${HOME}/.claude.json:/home/developer/.claude.json:cached
      # Mount git config for commits
      - \${HOME}/.gitconfig:/home/developer/.gitconfig:ro
      ${git_credentials_volume:+$git_credentials_volume}
    entrypoint: ["/bin/sh", "/usr/local/bin/trust-proxy-ca.sh"]
    command: ["sleep", "infinity"]
    healthcheck:
      test: ["CMD", "test", "-x", "/home/developer/.local/bin/claude"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s

volumes:
  squid-ssl:
EOF

    # Generate .env file
    echo "LOCAL_WORKSPACE_FOLDER_BASENAME=$WORKSPACE_NAME" > "$TEMP_DIR/.env"

    echo "$TEMP_DIR/docker-compose.yml"
}

# =============================================================================
# Container Management
# =============================================================================

get_compose_file() {
    local image_source
    image_source=$(detect_image_source)

    if [[ "$image_source" == "local-compose" ]]; then
        # Use target repo's own compose file
        echo "$TARGET_REPO/.devcontainer/docker-compose.yml"
    else
        # Generate compose file for this repo
        local whitelist_path
        whitelist_path=$(resolve_whitelist)
        generate_compose_file "$image_source" "$whitelist_path"
    fi
}

is_running() {
    local compose_file="$1"
    docker compose -f "$compose_file" ps --status running 2>/dev/null | grep -q sandbox
}

images_stale() {
    local compose_file="$1"
    local stale=1  # 1 = not stale (false), 0 = stale (true)

    local containers
    containers=$(docker compose -f "$compose_file" ps -q 2>/dev/null)

    if [[ -z "$containers" ]]; then
        return 1
    fi

    for container in $containers; do
        local running_image
        running_image=$(docker inspect "$container" --format '{{.Image}}' 2>/dev/null)

        local image_name
        image_name=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)

        local current_image
        current_image=$(docker image inspect "$image_name" --format '{{.Id}}' 2>/dev/null)

        if [[ -n "$running_image" && -n "$current_image" && "$running_image" != "$current_image" ]]; then
            local service_name
            service_name=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)
            warn "Image for '$service_name' is outdated"
            stale=0
        fi
    done

    return $stale
}

start_containers() {
    local compose_file="$1"

    if is_running "$compose_file"; then
        if images_stale "$compose_file"; then
            log "Detected outdated images, restarting containers..."
            docker compose -f "$compose_file" down
        else
            log "Containers already running"
            return
        fi
    fi

    log "Starting containers..."

    # For local-compose mode, generate .env in target repo
    local image_source
    image_source=$(detect_image_source)
    if [[ "$image_source" == "local-compose" ]]; then
        echo "LOCAL_WORKSPACE_FOLDER_BASENAME=$WORKSPACE_NAME" > "$TARGET_REPO/.devcontainer/.env"
    fi

    docker compose -f "$compose_file" up -d

    log "Waiting for sandbox to be ready..."
    for i in {1..30}; do
        # Check if sandbox service is healthy (look for line ending with "sandbox" service column and "(healthy)")
        if docker compose -f "$compose_file" ps 2>/dev/null | grep -E "sandbox[[:space:]].*\(healthy\)" | grep -qv "proxy"; then
            log "Sandbox is ready"
            break
        fi
        sleep 1
    done
}

stop_containers() {
    local compose_file="$1"

    if is_running "$compose_file"; then
        log "Stopping containers..."
        docker compose -f "$compose_file" down
        log "Containers stopped"
    else
        warn "No containers running"
    fi
}

show_status() {
    local compose_file="$1"
    local image_source
    image_source=$(detect_image_source)

    echo ""
    info "Target repo: $TARGET_REPO"
    info "Image source: $image_source"
    info "Compose file: $compose_file"

    local whitelist_path
    whitelist_path=$(resolve_whitelist)
    if [[ -n "$whitelist_path" ]]; then
        info "Whitelist: $whitelist_path"
    else
        info "Whitelist: (image default)"
    fi

    echo ""
    docker compose -f "$compose_file" ps 2>/dev/null || warn "No containers found"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local compose_file
    compose_file=$(get_compose_file)

    case "$ACTION" in
        status)
            show_status "$compose_file"
            ;;
        stop)
            stop_containers "$compose_file"
            ;;
        run)
            local image_source
            image_source=$(detect_image_source)
            info "Target repo: $TARGET_REPO"
            info "Image source: $image_source"

            start_containers "$compose_file"

            log "Launching Claude Code in sandbox..."
            docker compose -f "$compose_file" exec -u developer -w "/workspaces/$WORKSPACE_NAME" -it sandbox claude --dangerously-skip-permissions
            ;;
    esac
}

main
