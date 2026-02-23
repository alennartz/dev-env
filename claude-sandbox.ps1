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
