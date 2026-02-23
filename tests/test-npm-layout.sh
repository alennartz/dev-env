#!/bin/bash
# Test that trust-proxy-ca.sh handles npm-installed Claude
set -e

echo "=== Testing npm layout entrypoint ==="

# Build the base image
docker build -t claude-sandbox-base:test ./images/base

# Create a fake npm package directory
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/npm-pkg"
cat > "$TMPDIR/npm-pkg/package.json" <<'EOF'
{"name":"@anthropic-ai/claude-code","bin":{"claude":"cli.mjs"}}
EOF
cat > "$TMPDIR/npm-pkg/cli.mjs" <<'EOF'
console.log("claude-npm-test-ok");
EOF

# Run the entrypoint with npm layout
OUTPUT=$(docker run --rm \
    -e CLAUDE_INSTALL_TYPE=npm \
    -v "$TMPDIR/npm-pkg:/home/developer/.local/share/claude-npm:ro" \
    claude-sandbox-base:test \
    /bin/sh -c "/usr/local/bin/trust-proxy-ca.sh gosu developer /home/developer/.local/bin/claude 2>&1 || true; gosu developer /home/developer/.local/bin/claude 2>&1 || true")

rm -rf "$TMPDIR"

if echo "$OUTPUT" | grep -q "claude-npm-test-ok"; then
    echo "  PASS: npm layout produces working claude binary"
else
    echo "  FAIL: expected 'claude-npm-test-ok' in output"
    echo "  Got: $OUTPUT"
    exit 1
fi

echo "=== npm layout test passed ==="
