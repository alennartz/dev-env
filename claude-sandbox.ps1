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
