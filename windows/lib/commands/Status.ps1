# lib/commands/Status.ps1 - the first diagnostic to run when something is wrong.
#
# Counterpart of lib/commands/status.sh.

# Probe once and render the result, rather than running each (network-bound)
# check twice to derive the state and the label separately.
function Write-StatusProbe {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    $ok = $false
    try { $ok = [bool](& $Probe) } catch { $ok = $false }
    if ($ok) {
        Write-StatusLine -Label $Label -State 'ok'  -Text 'Healthy'
    } else {
        Write-StatusLine -Label $Label -State 'bad' -Text 'Unhealthy'
    }
}

function Write-StatusSystem {
    Write-Section 'System'
    Get-PlatformInfo
    Write-StatusLine -Label 'OS' -Text $script:OS_NAME

    if (Test-DockerBinary) {
        if (Test-DockerDaemon) {
            Write-StatusLine -Label 'Docker' -State 'ok'  -Text 'Running'
        } else {
            Write-StatusLine -Label 'Docker' -State 'bad' -Text 'Installed, daemon not responding'
        }
    } else {
        Write-StatusLine -Label 'Docker' -State 'bad' -Text 'Not installed'
    }

    if (Find-ComposeCommand) {
        Write-StatusLine -Label 'Docker Compose' -State 'ok'  -Text 'Available'
    } else {
        Write-StatusLine -Label 'Docker Compose' -State 'bad' -Text 'Unavailable'
    }

    Write-StatusLine -Label 'Installer'   -Text (Get-State -Key 'INSTALLER_VERSION' -Fallback $script:SO_INSTALLER_VERSION)
    Write-StatusLine -Label 'Install dir' -Text $script:INSTALL_DIR
}

function Write-StatusSupabase {
    Write-Section 'Supabase'
    if (-not (Test-SupabaseInstalled)) {
        Write-StatusLine -Label 'Status' -State 'bad' -Text 'Not installed'
        return
    }
    Write-StatusLine -Label 'Version' -Text (Get-SupabaseVersion)

    # Without a running daemon every probe below would just time out.
    if (-not (Test-DockerDaemon)) {
        Write-StatusLine -Label 'Services' -State 'bad' -Text 'Docker unavailable'
        return
    }

    Write-StatusProbe -Label 'PostgreSQL' -Probe { Test-SupabasePostgres }
    Write-StatusProbe -Label 'API'        -Probe { Test-SupabaseApi }
    Write-StatusProbe -Label 'Auth'       -Probe { Test-SupabaseAuth }
    Write-StatusProbe -Label 'Studio'     -Probe { Test-SupabaseStudio }
    Write-StatusLine  -Label 'Migrations' -Text "$(Get-AppliedMigrationCount) applied"
}

function Write-StatusLogflare {
    Write-Section 'Logflare'
    if ($script:ENABLE_LOGFLARE -ne 'true') {
        Write-StatusLine -Label 'Status' -State 'warn' -Text 'Disabled'
        return
    }
    Write-StatusLine -Label 'Mode' -Text (Get-State -Key 'LOGFLARE_MODE' -Fallback 'unknown')
    if (Test-LogflareRunning) {
        if (Test-Logflare) {
            Write-StatusLine -Label 'Status' -State 'ok'   -Text 'Running'
        } else {
            Write-StatusLine -Label 'Status' -State 'warn' -Text 'Running, health endpoint not answering'
        }
    } else {
        Write-StatusLine -Label 'Status' -State 'bad' -Text 'Not running'
    }
}

function Write-StatusApp {
    Write-Section 'Sentinel Ops'
    if (-not (Test-RepoCloned)) {
        Write-StatusLine -Label 'Repository' -State 'bad' -Text 'Not cloned'
        return
    }
    Write-StatusLine -Label 'Git branch' -Text (Get-State -Key 'APP_BRANCH' -Fallback $script:APP_BRANCH)
    Write-StatusLine -Label 'Git commit' -Text (Get-RepoShortCommit)
    Write-StatusLine -Label 'Image'      -Text (Get-State -Key 'APP_IMAGE' -Fallback 'none')

    if (Test-ContainerRunning -Name $script:APP_CONTAINER_NAME) {
        Write-StatusLine -Label 'Frontend' -State 'ok'  -Text 'Running'
    } elseif (Test-ContainerExists -Name $script:APP_CONTAINER_NAME) {
        Write-StatusLine -Label 'Frontend' -State 'bad' -Text 'Stopped'
    } else {
        Write-StatusLine -Label 'Frontend' -State 'bad' -Text 'No container'
    }

    if (Test-FrontendHttp -Port $script:APP_PORT) {
        Write-StatusLine -Label 'HTTP health' -State 'ok'  -Text 'Healthy'
    } else {
        Write-StatusLine -Label 'HTTP health' -State 'bad' -Text "Not responding on port $($script:APP_PORT)"
    }
}

function Write-StatusUrls {
    Write-Section 'URLs'
    Write-StatusLine -Label 'Application' -Text $script:SITE_URL
    Write-StatusLine -Label 'Supabase'    -Text $script:SUPABASE_PUBLIC_URL
    # These are what your reverse proxy should point at.
    Write-StatusLine -Label 'Frontend upstream' -Text "$(Get-FrontendBindAddress):$($script:APP_PORT)"
    Write-StatusLine -Label 'Supabase upstream' -Text "127.0.0.1:$(Get-SupabaseKongPort)"
}

function Write-StatusMeta {
    Write-Section 'History'
    Write-StatusLine -Label 'Installed'   -Text (Get-State -Key 'INSTALLED_AT' -Fallback 'unknown')
    Write-StatusLine -Label 'Last update' -Text (Get-State -Key 'UPDATED_AT'   -Fallback 'never')

    $prev = Get-State -Key 'PREVIOUS_APP_COMMIT' -Fallback ''
    if ($prev) {
        Write-StatusLine -Label 'Previous commit' -Text $prev.Substring(0, [Math]::Min(7, $prev.Length))
    }
    $latest = Get-LatestBackup
    if ($latest) {
        Write-StatusLine -Label 'Latest backup' -Text (Split-Path -Leaf $latest)
    }
}

function Invoke-CmdStatus {
    Write-Banner 'Sentinel Ops Status'

    if (-not (Test-InstallationExists)) {
        Write-Host ''
        Write-LogWarn "No installation found at $($script:INSTALL_DIR)."
        Write-Host ''
        Write-Host 'Run:'
        Write-Host '  sentinel-ops install'
        Write-Host ''
        Write-StatusSystem
        Write-Host ''
        return 1
    }
    [void](Import-Config)
    [void](Find-ComposeCommand)

    Write-StatusSystem
    Write-StatusSupabase
    Write-StatusLogflare
    Write-StatusApp
    Write-StatusUrls
    Write-StatusMeta
    Write-Host ''
    return 0
}
