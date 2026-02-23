#!/bin/bash
#
# Claude Code Sandbox - Bubblewrap + Network Jail Edition
#
# Provides:
#   - Full host tools via overlay filesystem
#   - Transparent network proxy (Squid with domain whitelist)
#   - Ephemeral writes (overlay upper layer is tmpfs)
#   - Persistent workspace and Claude config
#
# Requirements:
#   - docker (for network jail container)
#   - bubblewrap (bwrap)
#   - fuse-overlayfs
#   - nsenter (usually in util-linux)
#
# Usage:
#   ./claude-sandbox-bwrap.sh [workspace] [-- claude args...]
#   ./claude-sandbox-bwrap.sh ~/myproject
#   ./claude-sandbox-bwrap.sh ~/myproject -- --resume
#   ./claude-sandbox-bwrap.sh --stop      # Stop network jail
#   ./claude-sandbox-bwrap.sh --status    # Check status
#

set -e

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETJAIL_IMAGE="claude-netjail:latest"
NETJAIL_CONTAINER="claude-netjail"
NETJAIL_VOLUME="claude-netjail-ssl"

# Default whitelist location (can override with WHITELIST env var)
WHITELIST="${WHITELIST:-}"
if [ -z "$WHITELIST" ]; then
    # Try to find whitelist in order of preference
    if [ -f "$PWD/.devcontainer/whitelist.txt" ]; then
        WHITELIST="$PWD/.devcontainer/whitelist.txt"
    elif [ -f "$HOME/.claude/whitelist.txt" ]; then
        WHITELIST="$HOME/.claude/whitelist.txt"
    elif [ -f "$SCRIPT_DIR/local/whitelist.txt" ]; then
        WHITELIST="$SCRIPT_DIR/local/whitelist.txt"
    fi
fi

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sandbox]${NC} $1"; }
warn() { echo -e "${YELLOW}[sandbox]${NC} $1"; }
err()  { echo -e "${RED}[sandbox]${NC} $1" >&2; }
info() { echo -e "${BLUE}[sandbox]${NC} $1"; }

# === DEPENDENCY CHECK ===
check_deps() {
    local missing=()

    for cmd in docker bwrap fuse-overlayfs nsenter; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  sudo apt install bubblewrap fuse-overlayfs util-linux"
        echo ""
        exit 1
    fi

    # Check if user can run docker
    if ! docker info &>/dev/null; then
        err "Cannot connect to Docker. Is the daemon running? Is user in docker group?"
        exit 1
    fi
}

# === NETJAIL CONTAINER MANAGEMENT ===
build_netjail() {
    log "Building network jail image..."
    docker build -t "$NETJAIL_IMAGE" "$SCRIPT_DIR/images/netjail"
}

start_netjail() {
    # Check if already running
    if docker ps -q -f name="$NETJAIL_CONTAINER" | grep -q .; then
        log "Network jail already running."
        return 0
    fi

    # Remove stopped container if exists
    docker rm "$NETJAIL_CONTAINER" 2>/dev/null || true

    # Build if image doesn't exist
    if ! docker image inspect "$NETJAIL_IMAGE" &>/dev/null; then
        build_netjail
    fi

    log "Starting network jail container..."

    local whitelist_mount=""
    if [ -n "$WHITELIST" ] && [ -f "$WHITELIST" ]; then
        whitelist_mount="-v $WHITELIST:/etc/squid/whitelist.txt:ro"
        info "Using whitelist: $WHITELIST"
    else
        warn "No whitelist found, using minimal default (anthropic.com only)"
    fi

    docker run -d \
        --name "$NETJAIL_CONTAINER" \
        --cap-add NET_ADMIN \
        $whitelist_mount \
        -v "$NETJAIL_VOLUME:/etc/squid/ssl" \
        "$NETJAIL_IMAGE"

    # Wait for squid to be ready
    log "Waiting for Squid proxy..."
    for i in $(seq 1 30); do
        if docker exec "$NETJAIL_CONTAINER" pgrep squid &>/dev/null; then
            log "Network jail ready."
            return 0
        fi
        sleep 0.5
    done

    err "Network jail failed to start. Check logs with: docker logs $NETJAIL_CONTAINER"
    exit 1
}

stop_netjail() {
    log "Stopping network jail..."
    docker stop "$NETJAIL_CONTAINER" 2>/dev/null || true
    docker rm "$NETJAIL_CONTAINER" 2>/dev/null || true
    log "Network jail stopped."
}

netjail_status() {
    if docker ps -q -f name="$NETJAIL_CONTAINER" | grep -q .; then
        echo -e "${GREEN}Network jail: running${NC}"
        docker ps -f name="$NETJAIL_CONTAINER" --format "  Container: {{.Names}}\n  Status: {{.Status}}\n  Image: {{.Image}}"
    else
        echo -e "${YELLOW}Network jail: stopped${NC}"
    fi
}

get_netjail_pid() {
    docker inspect -f '{{.State.Pid}}' "$NETJAIL_CONTAINER" 2>/dev/null
}

# === OVERLAY FILESYSTEM ===
# Note: fuse-overlayfs on / requires root for copy-up operations
# We use sudo for the mount, then run claude as regular user
OVERLAY_DIR=""

setup_overlay() {
    OVERLAY_DIR=$(mktemp -d /tmp/claude-sandbox.XXXXXX)
    mkdir -p "$OVERLAY_DIR"/{upper,work,merged}
    chmod 755 "$OVERLAY_DIR" "$OVERLAY_DIR/upper" "$OVERLAY_DIR/work" "$OVERLAY_DIR/merged"

    log "Setting up root overlay at $OVERLAY_DIR (requires sudo)"

    # Mount overlay of entire root filesystem
    # Requires sudo for copy-up operations to work
    sudo fuse-overlayfs \
        -o "lowerdir=/" \
        -o "upperdir=$OVERLAY_DIR/upper" \
        -o "workdir=$OVERLAY_DIR/work" \
        -o "allow_other" \
        "$OVERLAY_DIR/merged"

    # Fix ownership so regular user can access
    sudo chown -R "$USER:$(id -gn)" "$OVERLAY_DIR/upper"

    log "Root overlay mounted."
}

cleanup_overlay() {
    if [ -n "$OVERLAY_DIR" ] && [ -d "$OVERLAY_DIR" ]; then
        log "Cleaning up overlay..."

        # Unmount overlay (may need sudo since we mounted with sudo)
        if mountpoint -q "$OVERLAY_DIR/merged" 2>/dev/null; then
            sudo fusermount -u "$OVERLAY_DIR/merged" 2>/dev/null || \
                sudo umount "$OVERLAY_DIR/merged" 2>/dev/null || true
        fi

        sudo rm -rf "$OVERLAY_DIR"
        log "Overlay cleaned up."
    fi
}

# === CA CERTIFICATE ===
setup_ca_cert() {
    log "Installing proxy CA certificate into overlay..."

    # Copy CA cert from container
    docker cp "$NETJAIL_CONTAINER:/etc/squid/ssl/squid-ca-cert.pem" "$OVERLAY_DIR/ca-cert.pem"

    # Install into the overlay's certificate directory
    # This writes to the overlay upper layer, not the host
    local cert_dir="$OVERLAY_DIR/merged/usr/local/share/ca-certificates"
    sudo mkdir -p "$cert_dir"
    sudo cp "$OVERLAY_DIR/ca-cert.pem" "$cert_dir/claude-sandbox-proxy.crt"
    sudo chmod 644 "$cert_dir/claude-sandbox-proxy.crt"

    # Append cert directly to the system CA bundle in the overlay
    # This is more reliable than chroot update-ca-certificates
    local ca_bundle="$OVERLAY_DIR/merged/etc/ssl/certs/ca-certificates.crt"
    if [ -f "$ca_bundle" ]; then
        log "Appending proxy cert to system CA bundle..."
        echo "" | sudo tee -a "$ca_bundle" >/dev/null
        echo "# Claude Sandbox Proxy CA" | sudo tee -a "$ca_bundle" >/dev/null
        sudo cat "$OVERLAY_DIR/ca-cert.pem" | sudo tee -a "$ca_bundle" >/dev/null
    else
        warn "System CA bundle not found at $ca_bundle"
    fi

    log "CA certificate installed."
}

# === SANDBOX EXECUTION ===
run_sandbox() {
    local workspace="$1"
    shift
    local claude_args=("$@")

    local netjail_pid
    netjail_pid=$(get_netjail_pid)

    if [ -z "$netjail_pid" ] || [ "$netjail_pid" = "0" ]; then
        err "Could not get network jail PID. Is it running?"
        exit 1
    fi

    local netns_path="/proc/$netjail_pid/ns/net"

    # Check if namespace exists (need sudo to read the symlink)
    if ! sudo test -e "$netns_path"; then
        err "Network namespace not found at $netns_path"
        exit 1
    fi

    info "Workspace: $workspace"
    info "Network namespace: PID $netjail_pid"
    info "Root overlay: $OVERLAY_DIR/merged"
    echo ""

    # Build bwrap arguments
    # The overlay gives us the full host filesystem with ephemeral writes
    # We bind-mount specific paths for true persistence
    local bwrap_args=(
        # Root is the overlay (full host filesystem, writes are ephemeral)
        --bind "$OVERLAY_DIR/merged" /

        # Workspace - true RW (bypasses overlay, persists to host)
        --bind "$workspace" "$workspace"

        # Claude config - true RW (persists to host)
        --bind "$HOME/.claude" "$HOME/.claude"
    )

    # Bind .claude.json if it exists
    if [ -f "$HOME/.claude.json" ]; then
        bwrap_args+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    fi

    bwrap_args+=(
        # Essential filesystems (need fresh mounts, not from overlay)
        --dev-bind /dev /dev
        --proc /proc

        # Start in workspace
        --chdir "$workspace"

        # Die with parent
        --die-with-parent
    )

    # Pass through ALL environment variables from current shell
    while IFS='=' read -r name value; do
        # Skip empty names and readonly vars
        [[ -z "$name" ]] && continue
        bwrap_args+=(--setenv "$name" "$value")
    done < <(env)

    # Override specific vars for sandbox
    bwrap_args+=(
        --setenv NODE_EXTRA_CA_CERTS "/usr/local/share/ca-certificates/claude-sandbox-proxy.crt"
        --setenv PATH "$HOME/.local/bin:$PATH"
    )

    log "Entering sandbox..."
    echo ""

    # Determine what command to run
    local cmd="claude"
    if [ "${SANDBOX_SHELL:-}" = "1" ]; then
        cmd="bash"
        claude_args=()
    fi

    # nsenter joins the network namespace, then bwrap handles the rest
    # We need sudo for nsenter to access /proc/PID/ns/net
    sudo nsenter --net="$netns_path" --preserve-credentials \
        sudo -u "$USER" -E \
        bwrap "${bwrap_args[@]}" \
        -- $cmd "${claude_args[@]}"
}

# === CLEANUP HANDLER ===
cleanup() {
    cleanup_overlay
    # Note: we don't stop netjail on exit - it can be reused
}

# === MAIN ===
main() {
    # Handle special commands
    case "${1:-}" in
        --stop)
            stop_netjail
            exit 0
            ;;
        --status)
            netjail_status
            exit 0
            ;;
        --build)
            build_netjail
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [workspace] [-- claude args...]"
            echo ""
            echo "Commands:"
            echo "  --stop     Stop the network jail container"
            echo "  --status   Show network jail status"
            echo "  --build    Rebuild the network jail image"
            echo "  --help     Show this help"
            echo ""
            echo "Environment:"
            echo "  WHITELIST  Path to domain whitelist file"
            echo ""
            echo "Examples:"
            echo "  $0                        # Current directory"
            echo "  $0 ~/myproject            # Specific workspace"
            echo "  $0 ~/myproject -- -p      # Pass args to claude"
            echo ""
            exit 0
            ;;
    esac

    check_deps

    # Parse arguments
    local workspace="${1:-.}"
    workspace="$(realpath "$workspace")"
    shift || true

    # Handle -- separator for claude args
    local claude_args=()
    if [ "${1:-}" = "--" ]; then
        shift
        claude_args=("$@")
    fi

    # Setup cleanup trap
    trap cleanup EXIT

    # Start network jail (if not already running)
    start_netjail

    # Setup overlay filesystem
    setup_overlay

    # Install CA certificate
    setup_ca_cert

    # Run sandbox
    run_sandbox "$workspace" "${claude_args[@]}"
}

main "$@"
