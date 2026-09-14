# lib/commands/Install.ps1 - first installation.
#
# Counterpart of lib/commands/install.sh. Every step runs behind a phase marker,
# so re-running after a failure resumes rather than starting over. Nothing here
# destroys existing state.

# --- individual phases -----------------------------------------------------

function Invoke-InstallSystemChecks {
    Assert-WindowsPlatform
    Assert-SupportedPlatform
    Assert-ContainerBackend
    if (-not (Install-BasePrerequisites)) { return $false }
    if (-not (Assert-Docker)) { return $false }
    return $true
}

function Invoke-InstallSupabaseFiles {
    if (-not (Install-SupabaseFiles))  { return $false }
    if (-not (New-SupabaseSecrets))    { return $false }
    if (-not (Set-SupabaseConfig))     { return $false }
    return $true
}

function Invoke-InstallSupabaseStart {
    Invoke-SupabasePull
    if (-not (Start-Supabase)) { return $false }
    if (-not (Test-SupabaseHealth -TimeoutSeconds 240)) {
        Write-Host ''
        Write-LogError 'Supabase health check failed.'
        Write-LogError 'Sentinel Ops installation cannot continue.'
        Write-Host ''
        Write-Host 'Run:'
        Write-Host '  sentinel-ops status'
        Write-Host ''
        return $false
    }
    Set-State -Key 'SUPABASE_VERSION' -Value (Get-SupabaseVersion)
    return $true
}

function Invoke-InstallLogflare {
    if (-not (Install-Logflare))    { return $false }
    if (-not (Test-LogflareHealth)) { return $false }
    return $true
}

function Invoke-InstallRepository {
    if (-not (Initialize-DeployKey)) { return $false }
    [void](Initialize-KnownHosts)
    if (-not (Test-RepoAccess))  { return $false }
    if (-not (Invoke-RepoClone)) { return $false }
    if (-not (Test-RepoLayout))  { return $false }
    return $true
}

function Invoke-InstallDatabase {
    # A backup before the very first migration run is cheap and gives a clean
    # restore point for the pre-application database.
    if (-not (New-DatabaseBackup -Label 'pre-install-migrations')) {
        Write-LogWarn 'Could not create a pre-migration backup; continuing.'
    }
    if (-not (Invoke-Migrations))       { return $false }
    if (-not (Invoke-FunctionsDeploy))  { return $false }
    return $true
}

function Invoke-InstallFrontend {
    if (-not (New-FrontendImage))    { return $false }
    if (-not (Invoke-FrontendDeploy)) { return $false }
    return $true
}

# --- configuration ---------------------------------------------------------

function Read-InstallDirPrompt {
    $dir = $script:SO_DEFAULT_INSTALL_DIR
    if ($script:SO_INSTALL_DIR_OVERRIDE) { $dir = $script:SO_INSTALL_DIR_OVERRIDE }
    $dir = Read-DefaultPrompt -Question 'Installation directory' -Default $dir

    if (-not (Test-InstallDirWritable -Root $dir)) {
        Write-LogError "Cannot write to $dir."
        if (-not (Test-Administrator)) {
            Write-LogError 'Either re-run PowerShell as Administrator, or choose a directory you own:'
            Write-LogError "  sentinel-ops install -Dir $(Join-Path $env:LOCALAPPDATA 'SentinelOps')"
        }
        throw "SENTINELOPS_FATAL: installation directory is not writable: $dir"
    }

    Set-ConfigPaths -Root $dir
    New-ConfigDirectories
    $script:SO_LOG_FILE = Join-Path $script:LOG_DIR "install-$(Get-Timestamp).log"
    Write-LogInfo "Logging to $($script:SO_LOG_FILE)"
}

function Read-InstallConfig {
    # Re-use anything already recorded, so a resumed install does not re-ask.
    [void](Import-Config)
    Read-SupabasePromptConfig
    Read-RepoPromptConfig
    Read-LogflarePromptConfig
    Export-Config
}

function Write-InstallSummary {
    Write-Host ''
    Write-Banner 'Installation Complete'
    Write-Host ''
    Write-Section 'URLs'
    Write-StatusLine -Label 'Application' -Text $script:SITE_URL
    Write-StatusLine -Label 'Supabase'    -Text $script:SUPABASE_PUBLIC_URL

    # No reverse proxy is installed - these are the upstreams to point one at.
    Write-Section 'Reverse proxy upstreams'
    Write-StatusLine -Label 'Frontend'     -Text "$(Get-FrontendBindAddress):$($script:APP_PORT)"
    Write-StatusLine -Label 'Supabase API' -Text "127.0.0.1:$(Get-SupabaseKongPort)"

    Write-Section 'Deployed'
    Write-StatusLine -Label 'Supabase'   -Text (Get-SupabaseVersion)
    Write-StatusLine -Label 'Git commit' -Text (Get-RepoShortCommit)
    Write-StatusLine -Label 'Image'      -Text (Get-FrontendDeployedImage)
    Write-StatusLine -Label 'Migrations' -Text "$(Get-AppliedMigrationCount) applied"

    Write-Host ''
    # Credentials are deliberately not printed here: installation output is
    # routinely copied into tickets and chat.
    Write-Host 'Supabase credentials are available with:'
    Write-Host ("  {0}sentinel-ops credentials{1}" -f $script:C_BOLD, $script:C_RESET)
    Write-Host ''
    Write-Host 'Check the deployment at any time with:'
    Write-Host ("  {0}sentinel-ops status{1}" -f $script:C_BOLD, $script:C_RESET)
    Write-Host ''
}

# --- entry point -----------------------------------------------------------

function Invoke-CmdInstall {
    Write-Banner 'Sentinel Ops Installer'
    Write-Host ''

    Start-Phase -Name 'System checks'
    if (-not (Invoke-InstallSystemChecks)) { Invoke-Die 'System prerequisites are not satisfied.' }
    Complete-Phase

    Read-InstallDirPrompt

    # Copy the installer into the installation root before anything else depends
    # on its templates, so the rest of the run (and every future update) uses one
    # canonical copy.
    Start-Phase -Name 'Installing the sentinel-ops command'
    if (-not (Install-Self)) { Invoke-Die 'Could not install the sentinel-ops command.' }
    Complete-Phase

    if ((Test-InstallationExists) -and (Test-PhaseDone -Name 'frontend')) {
        Write-LogWarn "An installation already exists at $($script:INSTALL_DIR)."
        Write-LogWarn "Use 'sentinel-ops update' to update it."
        if (-not (Confirm-Action -Question 'Continue and re-run the installer anyway?' -Default 'n')) {
            return 0
        }
    }

    Read-InstallConfig

    if (-not (Invoke-PhaseOnce -Name 'supabase_files' -Description 'Supabase deployment files' -Action { Invoke-InstallSupabaseFiles })) {
        Invoke-Die 'Supabase setup failed.'
    }
    if (-not (Invoke-PhaseOnce -Name 'supabase_start' -Description 'Starting Supabase' -Action { Invoke-InstallSupabaseStart })) {
        Invoke-Die 'Supabase did not become healthy.'
    }
    if (-not (Invoke-PhaseOnce -Name 'logflare' -Description 'Logflare' -Action { Invoke-InstallLogflare })) {
        Invoke-Die 'Logflare deployment failed.'
    }
    if (-not (Invoke-PhaseOnce -Name 'repository' -Description 'Sentinel Ops repository' -Action { Invoke-InstallRepository })) {
        Invoke-Die 'Repository checkout failed.'
    }

    # The remaining phases are cheap and depend on current config, so they run on
    # every install invocation rather than being marker-gated.
    Start-Phase -Name 'Application environment'
    if (-not (New-AppEnvironment)) { Invoke-Die 'Could not generate the application environment.' }
    Complete-Phase

    Start-Phase -Name 'Database migrations and edge functions'
    if (-not (Invoke-InstallDatabase)) { Invoke-Die 'Database deployment failed.' }
    Complete-Phase

    Start-Phase -Name 'Frontend image and container'
    if (-not (Invoke-InstallFrontend)) { Invoke-Die 'Frontend deployment failed.' }
    Complete-Phase

    Set-PhaseDone -Name 'frontend'
    Set-State -Key 'INSTALLER_VERSION' -Value $script:SO_INSTALLER_VERSION
    Set-State -Key 'INSTALLED_AT'      -Value (Get-State -Key 'INSTALLED_AT' -Fallback (Get-IsoTimestamp))
    Set-State -Key 'APP_COMMIT'        -Value (Get-RepoCommit)
    Set-State -Key 'APP_BRANCH'        -Value $script:APP_BRANCH
    Set-State -Key 'SUPABASE_VERSION'  -Value (Get-SupabaseVersion)
    Update-StateTimestamp

    Write-InstallSummary
    return 0
}
