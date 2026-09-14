<#
.SYNOPSIS
    sentinel-ops - installer and deployment manager for the Sentinel Ops stack.

.DESCRIPTION
    Windows counterpart of bin/sentinel-ops. Same commands, same state layout,
    same phase markers - see docs/WINDOWS.md for where the two deliberately
    differ.

.EXAMPLE
    sentinel-ops                    Guided menu
.EXAMPLE
    sentinel-ops install            First installation
.EXAMPLE
    sentinel-ops update supabase    Update Supabase only
.EXAMPLE
    sentinel-ops status             What is actually running
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'menu',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @(),

    # Installation directory (default C:\SentinelOps)
    [Alias('d')]
    [string]$Dir = '',

    # Non-interactive: accept every default
    [Alias('y')]
    [switch]$Yes,

    # Reveal secrets in `credentials` output
    [switch]$Show,

    # Re-run install phases that already completed
    [switch]$Force,

    # Verbose logging. Not named -Debug: that is a PowerShell common parameter
    # and redeclaring it is a parse error under [CmdletBinding()].
    [switch]$DebugMode
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Locate this installation of the tool. Works from the source checkout and from
# the installed copy alike.
# ---------------------------------------------------------------------------
$binDir = Split-Path -Parent $PSCommandPath
$root   = Split-Path -Parent $binDir

# In the source checkout the libraries live under windows/, and the shared
# container assets under the repository root. Once installed, everything sits
# side by side under the installation directory.
$script:SO_ROOT        = $root
$script:SO_BIN_SOURCE  = $binDir
$script:SO_LIB_SOURCE  = Join-Path $root 'lib'
$script:SO_ASSETS_SOURCE = Join-Path $root 'assets'
if (-not (Test-Path -LiteralPath $script:SO_ASSETS_SOURCE)) {
    # Source checkout: windows/bin -> windows -> repository root
    $repoRoot = Split-Path -Parent $root
    $script:SO_ASSETS_SOURCE = Join-Path $repoRoot 'assets'
    $script:SO_ROOT = $repoRoot
}

$script:SO_LIB_DIR    = $script:SO_LIB_SOURCE
$script:SO_ASSETS_DIR = $script:SO_ASSETS_SOURCE
# Where the command was launched from - used to find a deploy_key shipped
# alongside the installer.
$script:SO_SOURCE_DIR = $binDir

foreach ($lib in @('Common', 'Platform', 'Prereqs', 'Config', 'Supabase',
                   'Logflare', 'Repo', 'Frontend', 'Database', 'SelfInstall', 'Menu')) {
    . (Join-Path $script:SO_LIB_DIR "$lib.ps1")
}
foreach ($lib in @('Install', 'Update', 'Status', 'Credentials', 'Maintenance')) {
    . (Join-Path $script:SO_LIB_DIR "commands\$lib.ps1")
}

# ---------------------------------------------------------------------------
# Global flags
# ---------------------------------------------------------------------------
$script:SO_SHOW_SECRETS = [bool]$Show
$script:SO_ASSUME_YES   = [bool]$Yes
$script:SO_FORCE_PHASES = [bool]$Force
$script:SO_DEBUG        = [bool]$DebugMode

$script:SO_INSTALL_DIR_OVERRIDE = $Dir
if (-not $script:SO_INSTALL_DIR_OVERRIDE -and $env:SENTINEL_OPS_DIR) {
    $script:SO_INSTALL_DIR_OVERRIDE = $env:SENTINEL_OPS_DIR
}

function Show-Usage {
    Write-Host @'
Sentinel Ops installer and deployment manager (Windows)

Usage: sentinel-ops [options] <command> [arguments]

Commands:
  install                 Install Sentinel Ops on this machine
  update [app]            Update the application (default target)
  update supabase         Update Supabase only
  update all              Update Supabase and then the application
  status                  Show what is currently deployed and healthy
  credentials             Show the generated Supabase credentials
  backup [create|list]    Create or list database backups
  restore [backup]        Restore a database backup (latest if omitted)
  rollback                Roll the application back to the previous image
  logs [target] [lines]   app | supabase | logflare | installer
  version                 Print the installer version

Options:
  -Dir <path>             Installation directory (default C:\SentinelOps)
  -Yes                    Non-interactive: accept every default
  -Show                   Reveal secrets in `credentials` output
  -Force                  Re-run install phases that already completed
  -DebugMode              Verbose logging
  -?                      This help

With no command, an interactive menu is shown.
'@
}

function Invoke-Main {
    # Establish the paths every command works against.
    $root = $script:SO_DEFAULT_INSTALL_DIR
    if ($script:SO_INSTALL_DIR_OVERRIDE) { $root = $script:SO_INSTALL_DIR_OVERRIDE }
    Set-ConfigPaths -Root $root

    if (Test-Path -LiteralPath $script:LOG_DIR) {
        $script:SO_LOG_FILE = Join-Path $script:LOG_DIR ("sentinel-ops-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    }
    [void](Import-Config)

    $rest0 = ''
    $rest1 = ''
    if ($Arguments.Count -gt 0) { $rest0 = $Arguments[0] }
    if ($Arguments.Count -gt 1) { $rest1 = $Arguments[1] }

    switch ($Command.ToLowerInvariant()) {
        'menu'        { return (Invoke-CmdMenu) }
        'install'     { return (Invoke-CmdInstall) }
        'update'      { if ($rest0) { return (Invoke-CmdUpdate -Target $rest0) } else { return (Invoke-CmdUpdate) } }
        'status'      { return (Invoke-CmdStatus) }
        'credentials' { return (Invoke-CmdCredentials) }
        'creds'       { return (Invoke-CmdCredentials) }
        'backup'      { if ($rest0) { return (Invoke-CmdBackup -Action $rest0) } else { return (Invoke-CmdBackup) } }
        'restore'     { return (Invoke-CmdRestore -Target $rest0) }
        'rollback'    { return (Invoke-CmdRollback) }
        'logs'        {
            $target = 'app'; if ($rest0) { $target = $rest0 }
            $lines  = '100'; if ($rest1) { $lines  = $rest1 }
            return (Invoke-CmdLogs -Target $target -Lines $lines)
        }
        'version'     { Write-Host "sentinel-ops $($script:SO_INSTALLER_VERSION)"; return 0 }
        '--version'   { Write-Host "sentinel-ops $($script:SO_INSTALLER_VERSION)"; return 0 }
        'help'        { Show-Usage; return 0 }
        default {
            Write-LogError "Unknown command: $Command"
            Show-Usage
            return 2
        }
    }
}

try {
    exit (Invoke-Main)
} catch {
    $message = $_.Exception.Message
    if ($message -like 'SENTINELOPS_FATAL:*') {
        # Already reported by Invoke-Die with full context.
        exit 1
    }
    Write-LogError $message
    if ($script:SO_DEBUG) { Write-Host $_.ScriptStackTrace }
    exit 1
}
