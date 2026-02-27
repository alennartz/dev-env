#!/bin/bash
#
# Claude Code Sandbox - macOS Edition (FUSE-T Overlay + Seatbelt + pf + Netjail)
#
# Provides:
#   - Full host tools (native macOS execution, not containerized)
#   - Transparent network proxy (Squid with domain whitelist via pf)
#   - Ephemeral filesystem (FUSE-T overlay: writes outside workspace are discarded)
#   - File write confinement (Seatbelt restricts access to overlay mount)
#   - Automatic child process sandboxing (MCP servers inherit constraints)
#
# Requirements:
#   - macOS 13+ (Ventura or later)
#   - Docker Desktop (for netjail container)
#   - FUSE-T (brew install fuse-t) for ephemeral overlay filesystem
#   - overlay-fuse binary (built from cmd/overlay-fuse/)
#
# Usage:
#   ./claude-sandbox-macos.sh [workspace] [-- claude args...]
#   ./claude-sandbox-macos.sh ~/myproject
#   ./claude-sandbox-macos.sh ~/myproject -- --resume
#   ./claude-sandbox-macos.sh --stop      # Stop network jail + remove pf rules
#   ./claude-sandbox-macos.sh --status    # Check status
#
# See also: docs/adr/007-macos-seatbelt-pf-sandbox.md

set -e

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETJAIL_IMAGE="claude-netjail:latest"
NETJAIL_CONTAINER="claude-netjail-macos"
NETJAIL_VOLUME="claude-netjail-ssl"
PF_ANCHOR="claude-sandbox"

# Squid ports (mapped from Docker container to localhost)
SQUID_HTTP_PORT=3128
SQUID_HTTPS_PORT=3129

# Overlay filesystem
OVERLAY_FUSE_BIN="${OVERLAY_FUSE_BIN:-$SCRIPT_DIR/cmd/overlay-fuse/overlay-fuse}"
OVERLAY_DIR=""
OVERLAY_PID=""
NO_OVERLAY="${NO_OVERLAY:-}"  # Set to 1 to skip overlay (Phase 1 mode)

# Default whitelist location (can override with WHITELIST env var)
WHITELIST="${WHITELIST:-}"
if [ -z "$WHITELIST" ]; then
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

# === PLATFORM CHECK ===
check_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        err "This script is for macOS only. Use claude-sandbox-bwrap.sh on Linux."
        exit 1
    fi
}

# === DEPENDENCY CHECK ===
check_deps() {
    local missing=()

    for cmd in docker pfctl sandbox-exec; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing dependencies: ${missing[*]}"
        echo ""
        echo "pfctl and sandbox-exec are built into macOS."
        echo "Docker Desktop: https://www.docker.com/products/docker-desktop/"
        echo ""
        exit 1
    fi

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        err "Cannot connect to Docker. Is Docker Desktop running?"
        exit 1
    fi

    # Check overlay dependencies (unless disabled)
    if [ -z "$NO_OVERLAY" ]; then
        if [ ! -x "$OVERLAY_FUSE_BIN" ]; then
            warn "overlay-fuse binary not found at $OVERLAY_FUSE_BIN"
            warn "Build it with: cd cmd/overlay-fuse && go build -o overlay-fuse ."
            warn "Or set NO_OVERLAY=1 to run without ephemeral filesystem."
            warn ""
            warn "Falling back to Phase 1 mode (no ephemeral writes)."
            NO_OVERLAY=1
        fi
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

    log "Starting network jail container (port-mapped to localhost)..."

    local whitelist_mount=""
    if [ -n "$WHITELIST" ] && [ -f "$WHITELIST" ]; then
        whitelist_mount="-v $WHITELIST:/etc/squid/whitelist.txt:ro"
        info "Using whitelist: $WHITELIST"
    else
        warn "No whitelist found, using minimal default (anthropic.com only)"
    fi

    # Port-map Squid to localhost (unlike Linux bwrap which uses nsenter)
    # Docker Desktop runs in a VM, so Squid's outbound traffic doesn't
    # traverse host pf -- no redirect loop.
    docker run -d \
        --name "$NETJAIL_CONTAINER" \
        --cap-add NET_ADMIN \
        -p "127.0.0.1:${SQUID_HTTP_PORT}:3128" \
        -p "127.0.0.1:${SQUID_HTTPS_PORT}:3129" \
        $whitelist_mount \
        -v "$NETJAIL_VOLUME:/etc/squid/ssl" \
        "$NETJAIL_IMAGE"

    # Wait for squid to be ready
    log "Waiting for Squid proxy..."
    for i in $(seq 1 30); do
        if docker exec "$NETJAIL_CONTAINER" pgrep squid &>/dev/null; then
            log "Network jail ready (ports $SQUID_HTTP_PORT/$SQUID_HTTPS_PORT)."
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
        docker ps -f name="$NETJAIL_CONTAINER" --format "  Container: {{.Names}}\n  Status: {{.Status}}\n  Image: {{.Image}}\n  Ports: {{.Ports}}"
    else
        echo -e "${YELLOW}Network jail: stopped${NC}"
    fi
}

# === PF (PACKET FILTER) RULES ===
# Uses a named anchor so rules can be added/removed without affecting
# the rest of the system's pf configuration.

setup_pf() {
    log "Configuring pf rules (requires sudo)..."

    # Generate pf rules for the anchor
    local pf_rules
    pf_rules=$(cat <<EOF
# Redirect HTTP to Squid transparent intercept
rdr pass on lo0 proto tcp from any to any port 80 -> 127.0.0.1 port $SQUID_HTTP_PORT
# Redirect HTTPS to Squid SSL bump
rdr pass on lo0 proto tcp from any to any port 443 -> 127.0.0.1 port $SQUID_HTTPS_PORT

# Allow loopback
pass quick on lo0 all

# Allow DNS (Squid needs it for domain resolution)
pass out quick proto udp to any port 53
pass out quick proto tcp to any port 53

# Allow traffic to localhost Squid ports
pass out quick proto tcp to 127.0.0.1 port $SQUID_HTTP_PORT
pass out quick proto tcp to 127.0.0.1 port $SQUID_HTTPS_PORT

# Allow established connections (return traffic)
pass out quick proto tcp flags A/A

# Block all other outbound TCP (HTTP/HTTPS already redirected above)
block out quick proto tcp to any port 80
block out quick proto tcp to any port 443
EOF
)

    # Load rules into the named anchor
    echo "$pf_rules" | sudo pfctl -a "$PF_ANCHOR" -f - 2>/dev/null

    # Enable pf if not already enabled, and load anchor reference
    # We add our anchor to the main ruleset if not already present
    local main_rules
    main_rules=$(sudo pfctl -sr 2>/dev/null || true)

    if ! echo "$main_rules" | grep -q "anchor \"$PF_ANCHOR\""; then
        # Add anchor references to main ruleset
        # We need both rdr-anchor and anchor for NAT + filter rules
        local current_rules
        current_rules=$(sudo pfctl -sr 2>/dev/null || true)
        {
            echo "rdr-anchor \"$PF_ANCHOR\""
            echo "anchor \"$PF_ANCHOR\""
            echo "$current_rules"
        } | sudo pfctl -f - 2>/dev/null
    fi

    # Enable pf
    sudo pfctl -e 2>/dev/null || true

    log "pf rules loaded in anchor '$PF_ANCHOR'."
}

cleanup_pf() {
    log "Removing pf rules..."

    # Flush rules from our anchor
    sudo pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true

    # Remove anchor references from main ruleset
    local current_rules
    current_rules=$(sudo pfctl -sr 2>/dev/null || true)
    if echo "$current_rules" | grep -q "anchor \"$PF_ANCHOR\""; then
        echo "$current_rules" | grep -v "$PF_ANCHOR" | sudo pfctl -f - 2>/dev/null || true
    fi

    log "pf rules cleaned up."
}

pf_status() {
    echo ""
    echo "pf anchor '$PF_ANCHOR' rules:"
    sudo pfctl -a "$PF_ANCHOR" -sr 2>/dev/null || echo "  (no rules loaded)"
    echo ""
    echo "pf anchor '$PF_ANCHOR' NAT rules:"
    sudo pfctl -a "$PF_ANCHOR" -sn 2>/dev/null || echo "  (no NAT rules loaded)"
}

# === CA CERTIFICATE ===
CA_CERT_FILE=""

setup_ca_cert() {
    log "Extracting proxy CA certificate..."

    CA_CERT_FILE=$(mktemp /tmp/claude-sandbox-ca.XXXXXX.pem)

    docker cp "$NETJAIL_CONTAINER:/etc/squid/ssl/squid-ca-cert.pem" "$CA_CERT_FILE"
    chmod 644 "$CA_CERT_FILE"

    log "CA certificate extracted to $CA_CERT_FILE"
}

cleanup_ca_cert() {
    if [ -n "$CA_CERT_FILE" ] && [ -f "$CA_CERT_FILE" ]; then
        rm -f "$CA_CERT_FILE"
    fi
}

# === FUSE-T OVERLAY FILESYSTEM ===
# Provides ephemeral writes: the host filesystem is overlaid with a tmpdir
# upper layer. Writes outside bind-through paths go to the tmpdir and are
# discarded on exit. Bind-through paths (workspace, ~/.claude) persist.

setup_overlay() {
    local workspace="$1"

    if [ -n "$NO_OVERLAY" ]; then
        return 0
    fi

    OVERLAY_DIR=$(mktemp -d /tmp/claude-sandbox.XXXXXX)
    mkdir -p "$OVERLAY_DIR"/{upper,merged}
    chmod 755 "$OVERLAY_DIR" "$OVERLAY_DIR/upper" "$OVERLAY_DIR/merged"

    log "Setting up FUSE-T overlay at $OVERLAY_DIR..."

    # Build bind-through list: workspace + Claude config dirs
    local bind_paths="$workspace,$HOME/.claude"
    if [ -f "$HOME/.claude.json" ]; then
        bind_paths="$bind_paths,$HOME/.claude.json"
    fi

    # Start the overlay-fuse process in the background
    "$OVERLAY_FUSE_BIN" \
        -mountpoint "$OVERLAY_DIR/merged" \
        -lower "/" \
        -upper "$OVERLAY_DIR/upper" \
        -bind-through "$bind_paths" &
    OVERLAY_PID=$!

    # Wait for FUSE mount to become ready (overlay-fuse prints "READY" on stdout)
    local ready=0
    for i in $(seq 1 30); do
        if mountpoint -q "$OVERLAY_DIR/merged" 2>/dev/null; then
            ready=1
            break
        fi
        # Check if process died
        if ! kill -0 "$OVERLAY_PID" 2>/dev/null; then
            err "overlay-fuse process died. Check if FUSE-T is installed: brew install fuse-t"
            exit 1
        fi
        sleep 0.5
    done

    if [ $ready -eq 0 ]; then
        err "Overlay mount timed out at $OVERLAY_DIR/merged"
        kill "$OVERLAY_PID" 2>/dev/null || true
        exit 1
    fi

    log "Overlay mounted at $OVERLAY_DIR/merged"
}

setup_ca_cert_in_overlay() {
    if [ -n "$NO_OVERLAY" ] || [ -z "$OVERLAY_DIR" ]; then
        return 0
    fi

    log "Installing proxy CA certificate into overlay..."

    # The overlay's upper layer receives writes transparently.
    # We place the CA cert where macOS/Node.js tools expect system certs.
    local overlay_cert_dir="$OVERLAY_DIR/upper/etc/ssl/certs"
    mkdir -p "$overlay_cert_dir"

    # Copy the system cert bundle into upper, then append proxy CA
    local system_bundle="/etc/ssl/cert.pem"
    if [ -f "$system_bundle" ]; then
        cp "$system_bundle" "$overlay_cert_dir/ca-certificates.crt"
        echo "" >> "$overlay_cert_dir/ca-certificates.crt"
        echo "# Claude Sandbox Proxy CA" >> "$overlay_cert_dir/ca-certificates.crt"
        cat "$CA_CERT_FILE" >> "$overlay_cert_dir/ca-certificates.crt"
    fi

    # Also place the cert standalone for NODE_EXTRA_CA_CERTS
    local overlay_proxy_cert="$OVERLAY_DIR/upper/etc/ssl/claude-sandbox-proxy-ca.pem"
    mkdir -p "$(dirname "$overlay_proxy_cert")"
    cp "$CA_CERT_FILE" "$overlay_proxy_cert"

    log "CA certificate installed in overlay."
}

cleanup_overlay() {
    if [ -n "$OVERLAY_PID" ] && kill -0 "$OVERLAY_PID" 2>/dev/null; then
        log "Stopping overlay filesystem..."
        kill "$OVERLAY_PID" 2>/dev/null || true
        # Wait for clean unmount
        for i in $(seq 1 10); do
            if ! kill -0 "$OVERLAY_PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        # Force kill if still alive
        kill -9 "$OVERLAY_PID" 2>/dev/null || true
    fi

    # Try to unmount if still mounted
    if [ -n "$OVERLAY_DIR" ] && mountpoint -q "$OVERLAY_DIR/merged" 2>/dev/null; then
        umount "$OVERLAY_DIR/merged" 2>/dev/null || \
            diskutil unmount force "$OVERLAY_DIR/merged" 2>/dev/null || true
    fi

    if [ -n "$OVERLAY_DIR" ] && [ -d "$OVERLAY_DIR" ]; then
        rm -rf "$OVERLAY_DIR"
        log "Overlay cleaned up."
    fi
}

# === SEATBELT PROFILE ===
SEATBELT_FILE=""

generate_seatbelt_profile() {
    local workspace="$1"

    SEATBELT_FILE=$(mktemp /tmp/claude-sandbox-seatbelt.XXXXXX.sb)

    # Detect Homebrew prefix
    local homebrew_prefix="/usr/local"
    if [ -d "/opt/homebrew" ]; then
        homebrew_prefix="/opt/homebrew"
    fi

    # When overlay is active, the overlay mount IS the filesystem view.
    # Bind-through paths (workspace, ~/.claude) still write to host directly
    # because the overlay passes them through.
    local overlay_active=""
    local overlay_mount=""
    if [ -z "$NO_OVERLAY" ] && [ -n "$OVERLAY_DIR" ]; then
        overlay_active=1
        overlay_mount="$OVERLAY_DIR/merged"
    fi

    cat > "$SEATBELT_FILE" <<SBEOF
(version 1)

;; Deny everything by default
(deny default)

;; === PROCESS EXECUTION ===
;; Allow executing programs (needed for Claude, MCP servers, shell commands)
(allow process-exec)
(allow process-fork)
(allow signal)

;; === MACH / IPC ===
;; Required for system frameworks, dyld, and inter-process communication
(allow mach-lookup)
(allow mach-register)
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow ipc-posix-shm-write-create)
(allow ipc-posix-sem-open)
(allow ipc-posix-sem-post)
(allow ipc-posix-sem-wait)

;; === SYSCTL ===
;; Required for basic system info queries
(allow sysctl-read)

;; === NETWORK ===
;; Allow localhost connections only (pf handles redirection)
(allow network* (remote ip "localhost:*"))
(allow network* (local ip "localhost:*"))
;; Allow DNS resolution
(allow network-outbound (remote unix-socket (path-literal "/var/run/mDNSResponder")))
;; Allow Unix domain sockets (used by various tools)
(allow network-outbound (remote unix-socket))
(allow network-inbound (local unix-socket))
(allow network* (local unix-socket))

;; === READABLE PATHS ===
;; System libraries and frameworks (required by dyld and all executables)
(allow file-read*
    (subpath "/usr/lib")
    (subpath "/usr/share")
    (subpath "/System/Library")
    (subpath "/Library")
    (subpath "/private/var/db")
    (subpath "/dev")
    (subpath "/etc")
    (subpath "/var")
    (subpath "/bin")
    (subpath "/usr/bin")
    (subpath "/sbin")
    (subpath "/usr/sbin")
    (subpath "/private/etc")
    (subpath "/private/tmp")
    (subpath "/private/var")
    (subpath "/tmp")
)

;; Homebrew tools
(allow file-read* (subpath "${homebrew_prefix}"))

;; User home directory - read access for configs, tools, etc.
(allow file-read* (subpath "$HOME"))
SBEOF

    if [ -n "$overlay_active" ]; then
        # Overlay mode: the FUSE mount is the primary filesystem view.
        # Allow read/write to the entire overlay mount (the overlay handles
        # routing writes to upper layer or bind-through paths).
        cat >> "$SEATBELT_FILE" <<SBEOF

;; === OVERLAY MODE ===
;; The FUSE overlay mount provides the merged filesystem view.
;; Writes go to the ephemeral upper layer unless the path is a
;; bind-through (workspace, ~/.claude), which writes to host directly.
(allow file-read* (subpath "${overlay_mount}"))
(allow file-write* (subpath "${overlay_mount}"))

;; Overlay upper layer (ephemeral tmpdir)
(allow file-read* (subpath "${OVERLAY_DIR}"))
(allow file-write* (subpath "${OVERLAY_DIR}"))
SBEOF
    fi

    # Both modes need these writable paths
    cat >> "$SEATBELT_FILE" <<SBEOF

;; === WRITABLE PATHS ===
;; Workspace directory - full read/write (this is where work happens)
(allow file-write* (subpath "${workspace}"))

;; Claude config directories - read/write
(allow file-write* (subpath "$HOME/.claude"))
(allow file-write* (literal "$HOME/.claude.json"))

;; Temp directories - needed by many tools
(allow file-write* (subpath "/tmp"))
(allow file-write* (subpath "/private/tmp"))
(allow file-write* (subpath "/private/var/folders"))
(allow file-write* (subpath "/var/folders"))
(allow file-write* (subpath "$HOME/Library/Caches"))
(allow file-write* (subpath "$HOME/Library/Logs"))

;; Node.js / npm cache paths
(allow file-write* (subpath "$HOME/.npm"))
(allow file-write* (subpath "$HOME/.node"))
(allow file-write* (subpath "$HOME/.config"))

;; Git operations may need to write lock files
(allow file-write* (subpath "$HOME/.gitconfig.lock"))

;; Allow writing to /dev/null, /dev/tty, etc.
(allow file-write*
    (literal "/dev/null")
    (literal "/dev/tty")
    (literal "/dev/dtracehelper")
)

;; === PROCESS INFO ===
(allow process-info*)

;; === PSEUDO-TERMINALS ===
;; Required for interactive terminal sessions
(allow pseudo-tty)
SBEOF

    log "Seatbelt profile generated: $SEATBELT_FILE"
}

cleanup_seatbelt() {
    if [ -n "$SEATBELT_FILE" ] && [ -f "$SEATBELT_FILE" ]; then
        rm -f "$SEATBELT_FILE"
    fi
}

# === SANDBOX EXECUTION ===
run_sandbox() {
    local workspace="$1"
    shift
    local claude_args=("$@")

    info "Workspace: $workspace"
    info "Network: pf -> localhost Squid (ports $SQUID_HTTP_PORT/$SQUID_HTTPS_PORT)"
    if [ -z "$NO_OVERLAY" ] && [ -n "$OVERLAY_DIR" ]; then
        info "Filesystem: FUSE-T overlay (ephemeral writes outside workspace)"
        info "Overlay mount: $OVERLAY_DIR/merged"
    else
        info "Filesystem: direct (Seatbelt write confinement only)"
    fi
    info "Confinement: Seatbelt profile"
    echo ""

    # Determine what command to run
    local cmd="claude"
    local cmd_args=("--dangerously-skip-permissions")
    if [ "${SANDBOX_SHELL:-}" = "1" ]; then
        cmd="bash"
        cmd_args=()
        claude_args=()
    fi

    # Build environment: CA cert paths
    local env_args=(
        "NODE_EXTRA_CA_CERTS=$CA_CERT_FILE"
        "SSL_CERT_FILE=$CA_CERT_FILE"
    )

    # When overlay is active, point to the CA cert inside the overlay
    if [ -z "$NO_OVERLAY" ] && [ -n "$OVERLAY_DIR" ]; then
        local overlay_ca="$OVERLAY_DIR/merged/etc/ssl/claude-sandbox-proxy-ca.pem"
        if [ -f "$overlay_ca" ]; then
            env_args=(
                "NODE_EXTRA_CA_CERTS=$overlay_ca"
                "SSL_CERT_FILE=$OVERLAY_DIR/merged/etc/ssl/certs/ca-certificates.crt"
            )
        fi
    fi

    log "Entering sandbox..."
    echo ""

    # sandbox-exec runs the process under the Seatbelt profile
    # Child processes (including MCP servers) inherit the profile
    env "${env_args[@]}" \
        sandbox-exec -f "$SEATBELT_FILE" \
        "$cmd" "${cmd_args[@]}" "${claude_args[@]}"
}

# === CLEANUP HANDLER ===
cleanup() {
    local exit_code=$?
    cleanup_overlay
    cleanup_pf
    cleanup_ca_cert
    cleanup_seatbelt
    # Note: we don't stop netjail on exit - it can be reused
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then
        err "Sandbox exited with code $exit_code"
    fi
}

# === MAIN ===
main() {
    check_macos

    # Handle special commands
    case "${1:-}" in
        --stop)
            cleanup_pf
            stop_netjail
            exit 0
            ;;
        --status)
            netjail_status
            pf_status
            exit 0
            ;;
        --build)
            build_netjail
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [workspace] [-- claude args...]"
            echo ""
            echo "Sandboxes Claude Code on macOS using FUSE-T overlay + Seatbelt + pf."
            echo ""
            echo "Commands:"
            echo "  --stop     Stop network jail + remove pf rules"
            echo "  --status   Show network jail and pf status"
            echo "  --build    Rebuild the network jail image"
            echo "  --help     Show this help"
            echo ""
            echo "Environment:"
            echo "  WHITELIST        Path to domain whitelist file"
            echo "  SANDBOX_SHELL=1  Start a bash shell instead of Claude"
            echo "  NO_OVERLAY=1     Skip FUSE overlay (Phase 1 mode)"
            echo "  OVERLAY_FUSE_BIN Path to overlay-fuse binary"
            echo ""
            echo "Examples:"
            echo "  $0                        # Current directory"
            echo "  $0 ~/myproject            # Specific workspace"
            echo "  $0 ~/myproject -- -p      # Pass args to claude"
            echo "  SANDBOX_SHELL=1 $0        # Shell for testing"
            echo "  NO_OVERLAY=1 $0           # Without ephemeral filesystem"
            echo ""
            echo "Requires: macOS 13+, Docker Desktop, FUSE-T, sudo (for pfctl)"
            echo "Build overlay: cd cmd/overlay-fuse && go build -o overlay-fuse ."
            echo "See: docs/adr/007-macos-seatbelt-pf-sandbox.md"
            echo ""
            exit 0
            ;;
    esac

    check_deps

    # Parse arguments
    local workspace="${1:-.}"
    workspace="$(cd "$workspace" && pwd)"
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

    # Setup pf rules for transparent network interception
    setup_pf

    # Extract CA certificate from netjail container
    setup_ca_cert

    # Setup FUSE-T overlay filesystem (if available)
    setup_overlay "$workspace"

    # Install CA cert into overlay (if overlay is active)
    setup_ca_cert_in_overlay

    # Generate Seatbelt profile for file confinement
    generate_seatbelt_profile "$workspace"

    # Run sandbox
    run_sandbox "$workspace" "${claude_args[@]}"
}

main "$@"
