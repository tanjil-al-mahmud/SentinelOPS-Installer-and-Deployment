# lib/commands/Update.ps1 - application, Supabase and full updates.
#
# Counterpart of lib/commands/update.sh.

# Shared entry guard: an update only makes sense against a real installation.
function Invoke-UpdatePreflight {
    if (-not (Test-InstallationExists)) {
        Invoke-Die "No Sentinel Ops installation found at $($script:INSTALL_DIR). Run: sentinel-ops install"
    }
    if (-not (Import-Config)) { Invoke-Die "Could not read $($script:CONFIG_FILE)" }
    Assert-WindowsPlatform
    Get-PlatformInfo
    if (-not (Assert-Docker)) { Invoke-Die 'Docker is not usable.' }
    if (-not (Test-SupabaseInstalled)) { Invoke-Die "Supabase is not installed at $($script:SUPABASE_DIR)." }
}

# Supabase must be healthy before anything touches the schema or the frontend.
function Assert-SupabaseHealthy {
    Write-LogInfo 'Verifying Supabase...'
    if (-not (Test-SupabasePostgres)) {
        Write-LogWarn 'Supabase is not running; starting it.'
        if (-not (Start-Supabase)) { Invoke-Die 'Could not start Supabase.' }
    }
    if (-not (Test-SupabaseHealth -TimeoutSeconds 180)) {
        Invoke-Die 'Supabase is not healthy. Resolve that first: sentinel-ops status'
    }
}

# ---------------------------------------------------------------------------
# Application update
# ---------------------------------------------------------------------------

function Invoke-CmdUpdateApp {
    Invoke-UpdatePreflight
    $script:SO_LOG_FILE = Join-Path $script:LOG_DIR "update-app-$(Get-Timestamp).log"

    Write-Banner 'Update Sentinel Ops'
    Write-Host ''

    $beforeCommit = Get-State -Key 'APP_COMMIT' -Fallback 'unknown'
    $beforeImage  = Get-State -Key 'APP_IMAGE'  -Fallback ''

    Start-Phase -Name 'Supabase health'
    Assert-SupabaseHealthy
    Complete-Phase

    Start-Phase -Name 'Fetching application changes'
    if (-not (Initialize-DeployKey)) { Invoke-Die 'Deployment key unavailable.' }
    [void](Initialize-KnownHosts)
    if (-not (Update-Repo))     { Invoke-Die 'Could not update the repository.' }
    if (-not (Test-RepoLayout)) { Invoke-Die 'The updated checkout is not a valid Sentinel Ops repository.' }
    Complete-Phase

    Start-Phase -Name 'Application environment'
    if (-not (New-AppEnvironment)) { Invoke-Die 'Could not regenerate the application environment.' }
    Complete-Phase

    # The image is built before anything is changed in the database, so a build
    # failure costs nothing and the running deployment is untouched.
    Start-Phase -Name 'Building the frontend image'
    if (-not (New-FrontendImage)) { Invoke-Die 'Frontend build failed. The running deployment was not modified.' }
    Complete-Phase

    Start-Phase -Name 'Database migrations'
    if (-not (New-DatabaseBackup -Label 'pre-app-update')) { Write-LogWarn 'Backup failed; continuing.' }
    if (-not (Invoke-Migrations)) { Invoke-Die 'Migration failed. The running deployment was not modified.' }
    Complete-Phase

    Start-Phase -Name 'Edge functions'
    if (-not (Invoke-FunctionsDeploy)) { Invoke-Die 'Edge function deployment failed.' }
    Complete-Phase

    Start-Phase -Name 'Deploying the frontend'
    if (-not (Invoke-FrontendDeploy)) { Invoke-Die 'Frontend deployment failed.' }
    Complete-Phase

    Set-State -Key 'APP_COMMIT' -Value (Get-RepoCommit)
    Set-State -Key 'APP_BRANCH' -Value $script:APP_BRANCH
    if ($beforeCommit -and $beforeCommit -ne 'unknown') {
        Set-State -Key 'PREVIOUS_APP_COMMIT' -Value $beforeCommit
    }
    Update-StateTimestamp

    Write-Host ''
    Write-LogOk 'Sentinel Ops updated'
    Write-StatusLine -Label 'Commit' -Text ("{0} -> {1}" -f $beforeCommit.Substring(0, [Math]::Min(7, $beforeCommit.Length)), (Get-RepoShortCommit))
    Write-StatusLine -Label 'Image'  -Text (Get-FrontendDeployedImage)
    if ($beforeImage) { Write-StatusLine -Label 'Previous' -Text $beforeImage }
    Write-Host ''
    return 0
}

# ---------------------------------------------------------------------------
# Supabase update
# ---------------------------------------------------------------------------

function Invoke-CmdUpdateSupabase {
    Invoke-UpdatePreflight
    $script:SO_LOG_FILE = Join-Path $script:LOG_DIR "update-supabase-$(Get-Timestamp).log"

    Write-Banner 'Update Supabase'
    Write-Host ''

    $current = Get-SupabaseVersion
    Write-StatusLine -Label 'Current version' -Text $current

    # A database backup is mandatory here: a Supabase update can change the
    # Postgres major version or run its own schema migrations.
    Start-Phase -Name 'Database backup'
    $backupDir = New-DatabaseBackup -Label 'pre-supabase-update'
    if (-not $backupDir) { Invoke-Die 'Refusing to update Supabase without a successful backup.' }
    Complete-Phase

    Start-Phase -Name 'Updating the Supabase deployment'
    if (-not (Update-SupabaseFiles)) { Invoke-Die 'Could not refresh the Supabase deployment files.' }
    # Re-apply the settings the installer owns; an upstream .env.example change
    # must not silently revert the configured URLs.
    if (-not (Set-SupabaseConfig)) { Invoke-Die 'Could not re-apply the Supabase configuration.' }
    if ($script:ENABLE_LOGFLARE -eq 'true') {
        [void](Get-LogflareMode)
        if (-not (Set-LogflareSupabaseConfig)) {
            Write-LogWarn 'Could not re-apply the analytics configuration.'
        }
    }
    Complete-Phase

    Start-Phase -Name 'Pulling images'
    Invoke-SupabasePull
    Complete-Phase

    Start-Phase -Name 'Restarting Supabase'
    if (-not (Restart-Supabase)) {
        Write-LogError 'Supabase failed to restart.'
        Write-LogError "The pre-update backup is at: $backupDir"
        Invoke-Die 'Supabase update failed.'
    }
    if (-not (Test-SupabaseHealth -TimeoutSeconds 300)) {
        Write-LogError 'Supabase did not become healthy after the update.'
        Write-LogError "The pre-update backup is at: $backupDir"
        Write-LogError "Restore it with: sentinel-ops restore $backupDir"
        Invoke-Die 'Supabase update failed.'
    }
    Complete-Phase

    Start-Phase -Name 'Verifying Logflare'
    if (-not (Test-LogflareHealth)) { Write-LogWarn 'Logflare is not healthy after the Supabase update.' }
    Complete-Phase

    $newVersion = Get-SupabaseVersion
    Set-State -Key 'SUPABASE_VERSION'          -Value $newVersion
    Set-State -Key 'PREVIOUS_SUPABASE_VERSION' -Value $current
    Update-StateTimestamp

    Write-Host ''
    Write-LogOk 'Supabase updated'
    Write-StatusLine -Label 'Version' -Text "$current -> $newVersion"
    Write-StatusLine -Label 'Backup'  -Text $backupDir
    Write-Host ''
    return 0
}

# ---------------------------------------------------------------------------
# Full update
# ---------------------------------------------------------------------------

function Invoke-CmdUpdateAll {
    Write-Banner 'Update Everything'
    Write-Host ''
    Write-LogInfo 'Updating Supabase first, then the application.'

    if ((Invoke-CmdUpdateSupabase) -ne 0) { Invoke-Die 'Supabase update failed; the application was not touched.' }
    Write-Host ''
    if ((Invoke-CmdUpdateApp) -ne 0) { Invoke-Die 'Application update failed.' }

    Write-Host ''
    Write-LogOk 'Full update complete'
    return 0
}

# Dispatcher for `sentinel-ops update [app|supabase|all]`.
function Invoke-CmdUpdate {
    param([string]$Target = 'app')
    switch ($Target) {
        { $_ -in @('app', 'application', 'sentinel-ops', '') } { return (Invoke-CmdUpdateApp) }
        { $_ -in @('supabase', 'db') }                         { return (Invoke-CmdUpdateSupabase) }
        { $_ -in @('all', 'everything') }                      { return (Invoke-CmdUpdateAll) }
        default {
            Write-LogError "Unknown update target: $Target"
            Write-Host 'Valid targets: app, supabase, all'
            return 2
        }
    }
}
