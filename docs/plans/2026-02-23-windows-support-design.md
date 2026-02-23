# Windows Native Support for Dev Container Mode

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable Windows-native developers (PowerShell + Docker Desktop) to use both the CLI sandbox script and VS Code Dev Containers without touching WSL directly.

**Architecture:** A native PowerShell script (`claude-sandbox.ps1`) reimplements the bash script's logic using PowerShell idioms. The container entrypoint gains npm-layout support. The VS Code template becomes cross-platform via a Node.js init script.

**Tech Stack:** PowerShell 5.1+, Docker Compose, Node.js (for setup-env.js), POSIX shell (entrypoint)

---

## Design Reference

See the design sections in git history (commit `25ede1f`) for full rationale on each decision.

---

### Task 1: Extend entrypoint to handle npm-installed Claude

**Files:**
- Modify: `images/base/trust-proxy-ca.sh:36-50`
- Test: manual Docker test (described below)

**Step 1: Write the test script**

Create `tests/test-npm-layout.sh`:

```bash
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
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-npm-layout.sh`
Expected: FAIL — the entrypoint doesn't know about npm layout yet

**Step 3: Implement npm layout support in trust-proxy-ca.sh**

Replace the Claude binary setup block (lines 36-50) with:

```sh
# Create Claude symlink from mounted versions directory
# Host symlink uses absolute path with wrong username, so we create a new one
CLAUDE_DIR="/home/developer/.local/share/claude"
CLAUDE_BIN="/home/developer/.local/bin/claude"

if [ -d "$CLAUDE_DIR/versions" ] && [ "$(id -u)" = "0" ]; then
    LATEST=$(ls -t "$CLAUDE_DIR/versions" 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        echo "Setting up Claude binary (version $LATEST)..."
        ln -sf "$CLAUDE_DIR/versions/$LATEST" "$CLAUDE_BIN"
        chown -h "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
    else
        echo "WARNING: No Claude versions found in $CLAUDE_DIR/versions"
    fi
# npm global install layout (Windows / npm i -g @anthropic-ai/claude-code)
elif [ "${CLAUDE_INSTALL_TYPE:-}" = "npm" ] && [ "$(id -u)" = "0" ]; then
    NPM_DIR="/home/developer/.local/share/claude-npm"
    if [ -d "$NPM_DIR" ]; then
        # Discover entry point from package.json bin field
        ENTRY=$(node -e "const p=require('$NPM_DIR/package.json'); const b=Object.values(p.bin||{})[0]||p.main||'cli.mjs'; console.log(b)" 2>/dev/null || echo "cli.mjs")
        echo "Setting up Claude binary (npm package, entry: $ENTRY)..."
        cat > "$CLAUDE_BIN" <<WRAPPER
#!/bin/sh
exec node "$NPM_DIR/$ENTRY" "\$@"
WRAPPER
        chmod +x "$CLAUDE_BIN"
        chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
    else
        echo "WARNING: CLAUDE_INSTALL_TYPE=npm but no package found at $NPM_DIR"
    fi
fi
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-npm-layout.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add images/base/trust-proxy-ca.sh tests/test-npm-layout.sh
git commit -m "feat: support npm-installed Claude in container entrypoint"
```

---

### Task 2: Create cross-platform setup-env.js for VS Code Dev Containers

**Files:**
- Create: `template/setup-env.js`
- Modify: `template/devcontainer.json`
- Test: `tests/test-setup-env.js`

**Step 1: Write the failing test**

Create `tests/test-setup-env.js`:

```js
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Run setup-env.js with a test workspace name
const scriptPath = path.join(__dirname, '..', 'template', 'setup-env.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-env-test-'));
const envFile = path.join(tmpDir, '.env');

// Copy the script to tmp so it writes .env there
const testScript = path.join(tmpDir, 'setup-env.js');
try {
    fs.copyFileSync(scriptPath, testScript);
} catch (e) {
    console.log('FAIL: setup-env.js does not exist yet');
    process.exit(1);
}

execSync(`node "${testScript}" my-project`, { cwd: tmpDir });

const content = fs.readFileSync(envFile, 'utf8');

// Check LOCAL_WORKSPACE_FOLDER_BASENAME
if (!content.includes('LOCAL_WORKSPACE_FOLDER_BASENAME=my-project')) {
    console.log('FAIL: missing LOCAL_WORKSPACE_FOLDER_BASENAME');
    console.log('Got:', content);
    process.exit(1);
}

// Check HOME is set to os.homedir()
const home = os.homedir();
if (!content.includes(`HOME=${home}`)) {
    console.log(`FAIL: expected HOME=${home}`);
    console.log('Got:', content);
    process.exit(1);
}

// Cleanup
fs.rmSync(tmpDir, { recursive: true });
console.log('PASS: setup-env.js produces correct .env');
```

**Step 2: Run test to verify it fails**

Run: `node tests/test-setup-env.js`
Expected: FAIL — `setup-env.js does not exist yet`

**Step 3: Create setup-env.js**

Create `template/setup-env.js`:

```js
// Cross-platform .env generator for VS Code Dev Containers
// Called by devcontainer.json initializeCommand
// Usage: node setup-env.js <workspace-folder-basename>
const fs = require('fs');
const path = require('path');
const os = require('os');

const workspaceName = process.argv[2] || 'project';
const envFile = path.join(__dirname, '.env');

const lines = [
    `LOCAL_WORKSPACE_FOLDER_BASENAME=${workspaceName}`,
    `HOME=${os.homedir()}`,
];

fs.writeFileSync(envFile, lines.join('\n') + '\n');
```

**Step 4: Run test to verify it passes**

Run: `node tests/test-setup-env.js`
Expected: PASS

**Step 5: Update template/devcontainer.json**

Replace the full content of `template/devcontainer.json`:

```json
{
  "name": "Claude Code Sandbox",
  "dockerComposeFile": "docker-compose.yml",
  "service": "sandbox",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "remoteUser": "developer",
  "initializeCommand": "node ${localWorkspaceFolder}/.devcontainer/setup-env.js ${localWorkspaceFolderBasename}"
}
```

**Step 6: Commit**

```bash
git add template/setup-env.js template/devcontainer.json tests/test-setup-env.js
git commit -m "feat: cross-platform setup-env.js for VS Code Dev Containers"
```

---

### Task 3: Create claude-sandbox.ps1 — parameter parsing and helpers

**Files:**
- Create: `claude-sandbox.ps1`

This task creates the script skeleton with parameter parsing, logging helpers, path resolution, and hashing — everything up to but not including compose generation.

**Step 1: Create the script skeleton**

Create `claude-sandbox.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Launch Claude Code in a sandboxed Docker environment.
.DESCRIPTION
    PowerShell equivalent of claude-sandbox.sh for Windows-native developers.
    Uses Docker Desktop to run Claude in a network-isolated container.
.PARAMETER Repo
    Path to the target repository (default: current directory)
.PARAMETER Status
    Show status of running sandbox containers for this repo
.PARAMETER Stop
    Stop running sandbox containers for this repo
.PARAMETER StopAll
    Stop ALL running sandbox instances across all repos
.PARAMETER List
    List all running sandbox instances
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Status')]
    [Parameter(ParameterSetName = 'Stop')]
    [string]$Repo = $PWD.Path,

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Stop', Mandatory)]
    [switch]$Stop,

    [Parameter(ParameterSetName = 'StopAll', Mandatory)]
    [switch]$StopAll,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# Path Resolution
# =============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DevEnvRoot = $ScriptDir

# =============================================================================
# Logging Helpers
# =============================================================================
function Write-Log { param([string]$Msg) Write-Host "[sandbox] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[sandbox] $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "[sandbox] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "[sandbox] $Msg" -ForegroundColor Cyan }

# =============================================================================
# Resolve Target Repo
# =============================================================================
$TargetRepo = (Resolve-Path $Repo).Path
$WorkspaceName = Split-Path -Leaf $TargetRepo

# =============================================================================
# Project Name and Hash
# =============================================================================
$md5 = [System.Security.Cryptography.MD5]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($TargetRepo)
$hashBytes = $md5.ComputeHash($bytes)
$RepoHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 8).ToLower()

$SanitizedName = ($WorkspaceName.ToLower() -replace '[^a-z0-9]', '-' -replace '-+', '-').Trim('-')
$ProjectName = "sandbox-$SanitizedName-$RepoHash"

# Temp directory for generated compose file
$TempDir = Join-Path $env:TEMP "claude-sandbox-$RepoHash"

# =============================================================================
# Claude Binary Discovery
# =============================================================================
function Find-ClaudeBinary {
    <#
    .OUTPUTS
    Hashtable with keys: Type ('shell'|'npm'), Path (directory path)
    #>

    # 1. Shell installer layout
    $shellPath = Join-Path $env:USERPROFILE '.local\share\claude\versions'
    if (Test-Path $shellPath) {
        $latest = Get-ChildItem $shellPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            return @{ Type = 'shell'; Path = Join-Path $env:USERPROFILE '.local\share\claude' }
        }
    }

    # 2. npm global install
    try {
        $npmRoot = (npm root -g 2>$null).Trim()
        $npmPkg = Join-Path $npmRoot '@anthropic-ai\claude-code'
        if (Test-Path $npmPkg) {
            return @{ Type = 'npm'; Path = $npmPkg }
        }
    } catch {
        # npm not available, skip
    }

    # 3. Not found
    Write-Err "Claude Code installation not found."
    Write-Err ""
    Write-Err "Install Claude Code using one of:"
    Write-Err "  npm install -g @anthropic-ai/claude-code"
    Write-Err ""
    Write-Err "Then run 'claude login' to authenticate."
    exit 1
}

# =============================================================================
# Credential Resolution
# =============================================================================
function Resolve-Credentials {
    <#
    .OUTPUTS
    Hashtable with keys: ClaudeDir, ClaudeJson, GitConfig, GitCredentials (or $null)
    #>
    $home = $env:USERPROFILE

    $claudeDir = Join-Path $home '.claude'
    if (-not (Test-Path $claudeDir)) {
        Write-Err "Claude config directory not found: $claudeDir"
        Write-Err "Run 'claude login' first to create it."
        exit 1
    }

    $claudeJson = Join-Path $home '.claude.json'
    if (-not (Test-Path $claudeJson)) {
        Write-Err "Claude settings file not found: $claudeJson"
        Write-Err "Create it with: New-Item -Path '$claudeJson' -ItemType File"
        exit 1
    }

    $gitConfig = Join-Path $home '.gitconfig'
    if (-not (Test-Path $gitConfig)) {
        Write-Err "Git config not found: $gitConfig"
        Write-Err "Run 'git config --global user.name ...' and 'git config --global user.email ...' first."
        exit 1
    }

    $gitCreds = Join-Path $home '.git-credentials'
    $gitCredsResult = if (Test-Path $gitCreds) { $gitCreds } else { $null }

    return @{
        ClaudeDir      = $claudeDir
        ClaudeJson     = $claudeJson
        GitConfig      = $gitConfig
        GitCredentials = $gitCredsResult
    }
}

# =============================================================================
# Detection Functions
# =============================================================================
function Test-LocalDevcontainer {
    $composeFile = Join-Path $TargetRepo '.devcontainer\docker-compose.yml'
    if (Test-Path $composeFile) {
        $content = Get-Content $composeFile -Raw
        if ($content -match '(?m)^\s*proxy:' -and $content -match '(?m)^\s*sandbox:') {
            return $true
        }
    }
    return $false
}

function Test-LocalImages {
    $proxy = docker image inspect claude-sandbox-proxy:latest 2>$null
    $base = docker image inspect claude-sandbox-base:latest 2>$null
    return ($proxy -and $base)
}

function Get-ImageSource {
    if (Test-LocalDevcontainer) { return 'local-compose' }
    if (Test-LocalImages) { return 'local-images' }
    return 'ghcr'
}

# =============================================================================
# Whitelist Resolution
# =============================================================================
function Resolve-Whitelist {
    $targetWl = Join-Path $TargetRepo '.devcontainer\whitelist.txt'
    if (Test-Path $targetWl) { return $targetWl }

    $devenvWl = Join-Path $DevEnvRoot 'local\whitelist.txt'
    if (Test-Path $devenvWl) { return $devenvWl }

    return $null  # Use image default
}
```

**Step 2: Verify script parses without error**

This can be tested on Linux with `pwsh` if available, or noted for Windows testing. For now, commit the skeleton.

**Step 3: Commit**

```bash
git add claude-sandbox.ps1
git commit -m "feat: add claude-sandbox.ps1 skeleton with helpers"
```

---

### Task 4: Create claude-sandbox.ps1 — compose generation and container management

**Files:**
- Modify: `claude-sandbox.ps1` (append remaining functions)

**Step 1: Add compose generation and container management functions**

Append to `claude-sandbox.ps1`:

```powershell
# =============================================================================
# Compose File Generation
# =============================================================================
function New-ComposeFile {
    param(
        [string]$ImageSource,
        [string]$WhitelistPath,
        [hashtable]$Claude,
        [hashtable]$Creds
    )

    if (-not (Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }

    # Determine image references
    if ($ImageSource -eq 'local-images') {
        $proxyImage = 'claude-sandbox-proxy:latest'
        $sandboxImage = 'claude-sandbox-base:latest'
    } else {
        $proxyImage = 'ghcr.io/alennartz/claude-sandbox-proxy:latest'
        $sandboxImage = 'ghcr.io/alennartz/claude-sandbox-base:latest'
    }

    # Build whitelist volume line
    $whitelistVolume = ''
    if ($WhitelistPath) {
        $whitelistVolume = "      - ${WhitelistPath}:/etc/squid/whitelist.txt:ro"
    }

    # Build Claude binary mount
    if ($Claude.Type -eq 'npm') {
        $claudeMount = "      - $($Claude.Path):/home/developer/.local/share/claude-npm:ro"
        $claudeEnvLine = '      - CLAUDE_INSTALL_TYPE=npm'
    } else {
        $claudeMount = "      - $($Claude.Path):/home/developer/.local/share/claude:ro"
        $claudeEnvLine = ''
    }

    # Build git credentials mount
    $gitCredsVolume = ''
    if ($Creds.GitCredentials) {
        $gitCredsVolume = "      - $($Creds.GitCredentials):/home/developer/.git-credentials:ro"
    }

    # Generate compose file
    $compose = @"
# Auto-generated by claude-sandbox.ps1
# Target repo: $TargetRepo
# Image source: $ImageSource

services:
  proxy:
    image: $proxyImage
    cap_add:
      - NET_ADMIN
    volumes:
      - squid-ssl:/etc/squid/ssl
$whitelistVolume
    healthcheck:
      test: ["CMD", "squid", "-k", "check"]
      interval: 5s
      timeout: 5s
      retries: 3
      start_period: 10s

  sandbox:
    image: $sandboxImage
    network_mode: "service:proxy"
    depends_on:
      proxy:
        condition: service_healthy
    environment:
      - NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-ca-cert.pem
      - WORKSPACE_FOLDER=`${LOCAL_WORKSPACE_FOLDER_BASENAME}
$claudeEnvLine
    volumes:
      - squid-ssl:/etc/squid/ssl:ro
      - ${TargetRepo}:/workspaces/`${LOCAL_WORKSPACE_FOLDER_BASENAME}:cached
$claudeMount
      - $($Creds.ClaudeDir):/home/developer/.claude:cached
      - $($Creds.ClaudeJson):/home/developer/.claude.json:cached
      - $($Creds.GitConfig):/home/developer/.gitconfig:ro
$gitCredsVolume
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
"@

    $composeFile = Join-Path $TempDir 'docker-compose.yml'
    Set-Content -Path $composeFile -Value $compose -NoNewline

    # Generate .env file
    $envContent = "LOCAL_WORKSPACE_FOLDER_BASENAME=$WorkspaceName"
    Set-Content -Path (Join-Path $TempDir '.env') -Value $envContent -NoNewline

    return $composeFile
}

# =============================================================================
# Docker Compose Wrapper
# =============================================================================
function Invoke-Dc {
    param([string]$ComposeFile, [Parameter(ValueFromRemainingArguments)][string[]]$Args)
    & docker compose -p $ProjectName -f $ComposeFile @Args
}

# =============================================================================
# Container Management
# =============================================================================
function Get-ComposeFile {
    $imageSource = Get-ImageSource
    if ($imageSource -eq 'local-compose') {
        return Join-Path $TargetRepo '.devcontainer\docker-compose.yml'
    }

    $claude = Find-ClaudeBinary
    $creds = Resolve-Credentials
    $whitelist = Resolve-Whitelist
    return New-ComposeFile -ImageSource $imageSource -WhitelistPath $whitelist -Claude $claude -Creds $creds
}

function Test-Running {
    param([string]$ComposeFile)
    $output = Invoke-Dc $ComposeFile ps --status running 2>$null
    return ($output | Select-String 'sandbox') -ne $null
}

function Start-Containers {
    param([string]$ComposeFile)

    if (Test-Running $ComposeFile) {
        Write-Log "Containers already running"
        return
    }

    Write-Log "Starting containers..."

    # For local-compose mode, generate .env in target repo
    $imageSource = Get-ImageSource
    if ($imageSource -eq 'local-compose') {
        $envContent = "LOCAL_WORKSPACE_FOLDER_BASENAME=$WorkspaceName"
        Set-Content -Path (Join-Path $TargetRepo '.devcontainer\.env') -Value $envContent
    }

    Invoke-Dc $ComposeFile up -d

    Write-Log "Waiting for sandbox to be ready..."
    for ($i = 1; $i -le 30; $i++) {
        $ps = Invoke-Dc $ComposeFile ps 2>$null | Out-String
        if ($ps -match 'sandbox.*\(healthy\)' -and $ps -notmatch 'proxy.*\(healthy\).*sandbox') {
            Write-Log "Sandbox is ready"
            return
        }
        Start-Sleep -Seconds 1
    }
    Write-Warn "Sandbox may not be fully ready (timed out waiting for healthy status)"
}

function Stop-Containers {
    param([string]$ComposeFile)
    if (Test-Running $ComposeFile) {
        Write-Log "Stopping containers..."
        Invoke-Dc $ComposeFile down
        Write-Log "Containers stopped"
    } else {
        Write-Warn "No containers running"
    }
}

function Show-Status {
    param([string]$ComposeFile)
    Write-Info "Target repo: $TargetRepo"
    Write-Info "Project name: $ProjectName"
    Write-Info "Image source: $(Get-ImageSource)"
    Write-Info "Compose file: $ComposeFile"

    $wl = Resolve-Whitelist
    if ($wl) { Write-Info "Whitelist: $wl" } else { Write-Info "Whitelist: (image default)" }

    Write-Host ""
    Invoke-Dc $ComposeFile ps 2>$null
}

function Get-AllSandboxes {
    Write-Info "All running sandbox instances:"
    Write-Host ""
    docker ps --filter "name=sandbox" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

function Stop-AllSandboxes {
    Write-Info "Stopping all sandbox instances..."
    $projects = docker ps --filter "name=sandbox" --format "{{.Labels}}" 2>$null |
        Select-String 'com\.docker\.compose\.project=([^,]+)' -AllMatches |
        ForEach-Object { $_.Matches.Groups[1].Value } |
        Sort-Object -Unique

    if (-not $projects) {
        Write-Warn "No sandbox containers running"
        return
    }

    foreach ($project in $projects) {
        Write-Log "Stopping project: $project"
        docker compose -p $project down 2>$null
    }
    Write-Log "All sandbox instances stopped"
}

# =============================================================================
# Main
# =============================================================================
switch ($PSCmdlet.ParameterSetName) {
    'List' {
        Get-AllSandboxes
        return
    }
    'StopAll' {
        Stop-AllSandboxes
        return
    }
}

$composeFile = Get-ComposeFile

switch ($PSCmdlet.ParameterSetName) {
    'Status' {
        Show-Status $composeFile
    }
    'Stop' {
        Stop-Containers $composeFile
    }
    'Run' {
        $imageSource = Get-ImageSource
        Write-Info "Target repo: $TargetRepo"
        Write-Info "Project name: $ProjectName"
        Write-Info "Image source: $imageSource"

        Start-Containers $composeFile

        Write-Log "Launching Claude Code in sandbox..."
        Invoke-Dc $composeFile exec -u developer -w "/workspaces/$WorkspaceName" -it sandbox claude --dangerously-skip-permissions
    }
}
```

**Step 2: Commit**

```bash
git add claude-sandbox.ps1
git commit -m "feat: complete claude-sandbox.ps1 with compose generation and container management"
```

---

### Task 5: Update template README with Windows instructions

**Files:**
- Modify: `template/README.md`

**Step 1: Add Windows setup section after the existing Quick Start**

After the existing "One-time host setup" block in `template/README.md`, add:

```markdown
### Windows Setup

If you're on Windows with Docker Desktop:

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. Run `claude login` to authenticate
3. Create settings file: `New-Item -Path "$env:USERPROFILE\.claude.json" -ItemType File -Force`
4. Ensure git is configured: `git config --global user.name` and `git config --global user.email`

The template uses a cross-platform `setup-env.js` script that detects your home directory automatically. No additional configuration needed — just "Reopen in Container" in VS Code.

**Note:** The `claude-sandbox-bwrap.sh` script is Linux-only. On Windows, use the Docker container approach (this template) or the `claude-sandbox.ps1` script.
```

**Step 2: Update the "Claude not found" troubleshooting entry**

Replace:
```markdown
**Claude not found:**
Ensure Claude Code is installed on your host: `curl -fsSL https://claude.ai/install.sh | sh`
```

With:
```markdown
**Claude not found:**
Ensure Claude Code is installed on your host:
- Linux/macOS: `curl -fsSL https://claude.ai/install.sh | sh`
- Windows: `npm install -g @anthropic-ai/claude-code`
```

**Step 3: Commit**

```bash
git add template/README.md
git commit -m "docs: add Windows setup instructions to template README"
```

---

### Task 6: Update main README with Windows section

**Files:**
- Modify: `README.md`

**Step 1: Add Windows instructions to Option 2 (Docker Container Sandbox)**

In the "Option 2: Docker Container Sandbox" section, after the existing step 2 ("Set up an alias"), add a Windows subsection:

```markdown
   **On Windows (PowerShell):**
   ```powershell
   git clone https://github.com/alennartz/dev-env.git ~/dev-env
   ```

   Add to your PowerShell profile (`$PROFILE`):
   ```powershell
   function claude-sandbox { & "$HOME\dev-env\claude-sandbox.ps1" @args }
   ```

   Then run in any project:
   ```powershell
   cd ~/your-project
   claude-sandbox
   ```
```

**Step 2: Update the "Choosing an Approach" table**

Add a third column to the comparison table for Windows:

```markdown
| | Bubblewrap (Linux only) | Docker Container (Linux, macOS) | Docker Container (Windows) |
|---|---|---|---|
| **Host tools available** | All — overlays host `/` directly | None — must install in container | None — must install in container |
| **Shell/configs** | Your shell, dotfiles, aliases | Minimal bash, no host configs | Minimal bash, no host configs |
| **Setup per project** | Whitelist file only | Dockerfile or image customization | Dockerfile or image customization |
| **Network isolation** | Transparent proxy (iptables) | Transparent proxy (iptables) | Transparent proxy (iptables) |
| **Filesystem isolation** | Overlay — writes are ephemeral | Container — writes are ephemeral | Container — writes are ephemeral |
| **Resource overhead** | ~22MB network jail container | ~418MB+ sandbox container | ~418MB+ sandbox container |
| **Script** | `claude-sandbox-bwrap.sh` | `claude-sandbox.sh` | `claude-sandbox.ps1` |
| **Platform** | Linux only | Linux, macOS (bash) | Windows (PowerShell 5.1+) |
```

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add Windows PowerShell workflow to main README"
```

---

### Task 7: Update CLAUDE.md to reference new files

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the project structure tree**

Add `claude-sandbox.ps1` to the root listing and `setup-env.js` to the template listing. Add `tests/` directory.

**Step 2: Add a brief Windows section**

Under "Key Concepts", after the "Bubblewrap Sandbox" section, add:

```markdown
### Windows Support (claude-sandbox.ps1)

PowerShell equivalent of `claude-sandbox.sh` for Windows-native developers using Docker Desktop. Discovers Claude installed via npm (`npm root -g`) or the shell installer, resolves credentials from `$env:USERPROFILE`, and generates compose files in `$env:TEMP`.

The container entrypoint (`trust-proxy-ca.sh`) handles both install layouts:
- Shell installer: symlinks from `versions/<ver>/` (existing behavior)
- npm global: creates a wrapper script that runs `node <package>/cli.mjs`
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: reference Windows support files in CLAUDE.md"
```

---

Plan complete and saved to `docs/plans/2026-02-23-windows-support-design.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open a new session with executing-plans, batch execution with checkpoints

Which approach?