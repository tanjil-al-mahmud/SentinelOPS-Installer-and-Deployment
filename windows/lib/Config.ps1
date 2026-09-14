# lib/Config.ps1 - persistent installer configuration and deployment state.
#
# Counterpart of lib/config.sh.

# Default installation root. C:\SentinelOps rather than a path under
# ProgramData: it is short, which matters because the Supabase tree nests
# deeply and Windows still enforces MAX_PATH for many tools.
$script:SO_DEFAULT_INSTALL_DIR = 'C:\SentinelOps'

# Derived paths, set by Set-ConfigPaths.
$script:INSTALL_DIR  = ''
$script:CONFIG_DIR   = ''
$script:CONFIG_FILE  = ''
$script:SUPABASE_DIR = ''
$script:APP_DIR      = ''
$script:LOGFLARE_DIR = ''
$script:BACKUP_DIR   = ''
$script:STATE_DIR    = ''
$script:STATE_FILE   = ''
$script:PHASE_DIR    = ''
$script:LOG_DIR      = ''
$script:RUNTIME_DIR  = ''

# Configuration values (defaults; overridden by installer.env).
$script:APP_REPOSITORY = 'git@github.com:BrainStation-23/sentinel-ops.git'
$script:APP_BRANCH     = 'main'
$script:DEPLOY_KEY     = ''

# Public endpoints. The defaults are the local ports the stack actually binds,
# so an install with no arguments produces a working deployment on this host.
# Pass real hostnames (or answer the prompts) when putting it behind a domain.
$script:SUPABASE_PUBLIC_URL = 'http://localhost:8000'
$script:API_EXTERNAL_URL    = 'http://localhost:8000'
$script:SITE_URL            = 'http://localhost:3000'

$script:APP_PORT = '3000'
# Where the frontend's published port is bound. The reverse proxy is the
# operator's responsibility, so the default is loopback: a proxy on this host
# reaches it, the network does not. Set to 0.0.0.0 only if the proxy runs on a
# different machine.
$script:APP_BIND            = '127.0.0.1'
$script:APP_IMAGE_NAME      = 'sentinel-ops'
$script:APP_CONTAINER_NAME  = 'sentinel-ops-frontend'
$script:ENABLE_LOGFLARE     = 'true'
# postgres | bigquery - see docs/LOGFLARE.md
$script:LOGFLARE_BACKEND       = 'postgres'
$script:GOOGLE_PROJECT_ID      = ''
$script:GOOGLE_PROJECT_NUMBER  = ''

# The keys Import-Config reads back out of installer.env.
$script:SO_CONFIG_KEYS = @(
    'APP_REPOSITORY', 'APP_BRANCH', 'DEPLOY_KEY', 'SUPABASE_PUBLIC_URL',
    'API_EXTERNAL_URL', 'SITE_URL', 'APP_PORT', 'APP_BIND', 'APP_IMAGE_NAME',
    'APP_CONTAINER_NAME', 'ENABLE_LOGFLARE', 'LOGFLARE_BACKEND',
    'GOOGLE_PROJECT_ID', 'GOOGLE_PROJECT_NUMBER'
)

# Establish every path from the installation root.
function Set-ConfigPaths {
    param([Parameter(Mandatory)][string]$Root)
    $script:INSTALL_DIR  = (Remove-TrailingSlash ($Root.TrimEnd('\')))
    $script:CONFIG_DIR   = Join-Path $script:INSTALL_DIR 'config'
    $script:CONFIG_FILE  = Join-Path $script:CONFIG_DIR  'installer.env'
    $script:SUPABASE_DIR = Join-Path $script:INSTALL_DIR 'supabase'
    $script:APP_DIR      = Join-Path $script:INSTALL_DIR 'app'
    $script:LOGFLARE_DIR = Join-Path $script:INSTALL_DIR 'logflare'
    $script:BACKUP_DIR   = Join-Path $script:INSTALL_DIR 'backups'
    $script:STATE_DIR    = Join-Path $script:INSTALL_DIR '.state'
    $script:STATE_FILE   = Join-Path $script:STATE_DIR   'state.env'
    $script:PHASE_DIR    = Join-Path $script:STATE_DIR   'phases'
    $script:LOG_DIR      = Join-Path $script:INSTALL_DIR 'logs'
    $script:RUNTIME_DIR  = Join-Path $script:INSTALL_DIR 'runtime'
}

function New-ConfigDirectories {
    foreach ($d in @($script:CONFIG_DIR, $script:BACKUP_DIR, $script:STATE_DIR,
                     $script:PHASE_DIR, $script:LOG_DIR, $script:RUNTIME_DIR,
                     $script:LOGFLARE_DIR)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
    # Config and state hold URLs and deployment metadata; keep them private.
    foreach ($d in @($script:CONFIG_DIR, $script:STATE_DIR, $script:BACKUP_DIR)) {
        [void](Set-RestrictedAcl -Path $d)
    }
}

# Can this account actually install into the chosen root?
#
# The Linux version simply demands root. On Windows that is the wrong test:
# a standard user can write to C:\SentinelOps or their own profile perfectly
# well, and only machine-wide PATH changes genuinely need elevation. So the
# question asked here is "is this directory writable", not "are you admin".
function Test-InstallDirWritable {
    param([Parameter(Mandatory)][string]$Root)
    try {
        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Force -Path $Root -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Root ('.write-probe-' + [Guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-LogDebug "install dir not writable (${Root}): $_"
        return $false
    }
}

# True when a previous installation exists at this root.
function Test-InstallationExists {
    return (Test-Path -LiteralPath $script:CONFIG_FILE -PathType Leaf)
}

# Load installer.env. Values are read key by key so the file can never execute
# anything.
function Import-Config {
    if (-not (Test-Path -LiteralPath $script:CONFIG_FILE -PathType Leaf)) { return $false }
    foreach ($key in $script:SO_CONFIG_KEYS) {
        $val = Get-EnvValue -Path $script:CONFIG_FILE -Key $key
        if (-not [string]::IsNullOrEmpty($val)) {
            Set-Variable -Name $key -Value $val -Scope Script
        }
    }
    return $true
}

function Export-Config {
    New-ConfigDirectories
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Sentinel Ops installer configuration')
    [void]$sb.AppendLine("# Generated by sentinel-ops $($script:SO_INSTALLER_VERSION)")
    [void]$sb.AppendLine('# Edit with care: this file is read by every update run.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("INSTALL_DIR=$($script:INSTALL_DIR)")
    [void]$sb.AppendLine("SUPABASE_DIR=$($script:SUPABASE_DIR)")
    [void]$sb.AppendLine("APP_DIR=$($script:APP_DIR)")
    [void]$sb.AppendLine("LOGFLARE_DIR=$($script:LOGFLARE_DIR)")
    [void]$sb.AppendLine("BACKUP_DIR=$($script:BACKUP_DIR)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Application repository')
    [void]$sb.AppendLine("APP_REPOSITORY=$($script:APP_REPOSITORY)")
    [void]$sb.AppendLine("APP_BRANCH=$($script:APP_BRANCH)")
    [void]$sb.AppendLine("DEPLOY_KEY=$($script:DEPLOY_KEY)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Public endpoints')
    [void]$sb.AppendLine("SUPABASE_PUBLIC_URL=$($script:SUPABASE_PUBLIC_URL)")
    [void]$sb.AppendLine("API_EXTERNAL_URL=$($script:API_EXTERNAL_URL)")
    [void]$sb.AppendLine("SITE_URL=$($script:SITE_URL)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Frontend runtime. Point your own reverse proxy at')
    [void]$sb.AppendLine('# APP_BIND:APP_PORT, and at Supabase Kong for the API.')
    [void]$sb.AppendLine("APP_PORT=$($script:APP_PORT)")
    [void]$sb.AppendLine("APP_BIND=$($script:APP_BIND)")
    [void]$sb.AppendLine("APP_IMAGE_NAME=$($script:APP_IMAGE_NAME)")
    [void]$sb.AppendLine("APP_CONTAINER_NAME=$($script:APP_CONTAINER_NAME)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Analytics (Logflare) - see docs/LOGFLARE.md')
    [void]$sb.AppendLine("ENABLE_LOGFLARE=$($script:ENABLE_LOGFLARE)")
    [void]$sb.AppendLine("LOGFLARE_BACKEND=$($script:LOGFLARE_BACKEND)")
    [void]$sb.AppendLine("GOOGLE_PROJECT_ID=$($script:GOOGLE_PROJECT_ID)")
    [void]$sb.AppendLine("GOOGLE_PROJECT_NUMBER=$($script:GOOGLE_PROJECT_NUMBER)")

    Write-TextFile -Path $script:CONFIG_FILE -Content $sb.ToString()
    [void](Set-RestrictedAcl -Path $script:CONFIG_FILE)
    Write-LogDebug "configuration written to $($script:CONFIG_FILE)"
}

# ---------------------------------------------------------------------------
# Deployment state
# ---------------------------------------------------------------------------

function Get-State {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Fallback = ''
    )
    $val = Get-EnvValue -Path $script:STATE_FILE -Key $Key
    if ([string]::IsNullOrEmpty($val)) { return $Fallback }
    return $val
}

function Set-State {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if (-not (Test-Path -LiteralPath $script:STATE_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:STATE_DIR | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:STATE_FILE -PathType Leaf)) {
        Write-TextFile -Path $script:STATE_FILE -Content "# Sentinel Ops deployment state - managed automatically.`n"
        [void](Set-RestrictedAcl -Path $script:STATE_FILE)
    }
    Set-EnvValue -Path $script:STATE_FILE -Key $Key -Value $Value
}

function Update-StateTimestamp {
    Set-State -Key 'UPDATED_AT' -Value (Get-IsoTimestamp)
}

# ---------------------------------------------------------------------------
# Phase markers - the basis of idempotent re-runs
#
# A completed phase drops a marker file. On a re-run the installer skips a phase
# whose marker exists, so a failure late in the process does not force Supabase
# to be reinstalled or secrets to be regenerated.
# ---------------------------------------------------------------------------

function Test-PhaseDone {
    param([Parameter(Mandatory)][string]$Name)
    return (Test-Path -LiteralPath (Join-Path $script:PHASE_DIR $Name) -PathType Leaf)
}

function Set-PhaseDone {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -LiteralPath $script:PHASE_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:PHASE_DIR | Out-Null
    }
    Write-TextFile -Path (Join-Path $script:PHASE_DIR $Name) -Content ((Get-IsoTimestamp) + "`n")
}

function Clear-PhaseDone {
    param([Parameter(Mandatory)][string]$Name)
    Remove-Item -LiteralPath (Join-Path $script:PHASE_DIR $Name) -Force -ErrorAction SilentlyContinue
}

# Run a phase once. If its marker exists the phase is skipped unless
# -Force was passed. The action must return $true on success.
function Invoke-PhaseOnce {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ((Test-PhaseDone -Name $Name) -and -not $script:SO_FORCE_PHASES) {
        Write-LogOk "$Description (already completed, skipping)"
        return $true
    }
    Start-Phase -Name $Description
    if (& $Action) {
        Set-PhaseDone -Name $Name
        Complete-Phase
        return $true
    }
    return $false
}
