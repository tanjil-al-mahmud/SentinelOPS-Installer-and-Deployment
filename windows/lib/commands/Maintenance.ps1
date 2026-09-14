# lib/commands/Maintenance.ps1 - backup, restore, rollback and logs.
#
# Counterpart of lib/commands/maintenance.sh.

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

function Invoke-CmdBackup {
    param([string]$Action = 'create')

    if (-not (Test-InstallationExists)) { Invoke-Die "No installation found at $($script:INSTALL_DIR)." }
    [void](Import-Config)
    [void](Find-ComposeCommand)

    switch ($Action) {
        { $_ -in @('create', '') } {
            $dir = New-DatabaseBackup -Label 'manual'
            if (-not $dir) { Invoke-Die 'Backup failed.' }
            Write-Host ''
            Write-LogOk "Backup complete: $dir"
        }
        { $_ -in @('list', 'ls') } {
            Write-Section 'Backups'
            $dirs = @(Get-ChildItem -LiteralPath $script:BACKUP_DIR -Directory -ErrorAction SilentlyContinue |
                      Sort-Object -Property Name -Descending)
            if ($dirs.Count -eq 0) {
                Write-Host 'No backups yet.'
            } else {
                foreach ($d in $dirs) {
                    $sql = Join-Path $d.FullName 'database.sql'
                    $size = '-'
                    if (Test-Path -LiteralPath $sql -PathType Leaf) {
                        $size = '{0:N1} MB' -f ((Get-Item -LiteralPath $sql).Length / 1MB)
                    }
                    $reason = Get-EnvValue -Path (Join-Path $d.FullName 'metadata.txt') -Key 'reason'
                    if (-not $reason) { $reason = '-' }
                    Write-Host ("{0,-24} {1,-10} {2}" -f $d.Name, $size, $reason)
                }
            }
            Write-Host ''
        }
        default {
            Write-LogError "Unknown backup subcommand: $Action"
            Write-Host 'Valid: create, list'
            return 2
        }
    }
    return 0
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

function Invoke-CmdRestore {
    param([string]$Target = '')

    if (-not (Test-InstallationExists)) { Invoke-Die "No installation found at $($script:INSTALL_DIR)." }
    [void](Import-Config)
    [void](Find-ComposeCommand)

    if (-not $Target) { $Target = Get-LatestBackup }
    if (-not $Target) { Invoke-Die 'No backup to restore.' }
    # Accept either a full path or just the timestamp directory name.
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        $Target = Join-Path $script:BACKUP_DIR $Target
    }
    $sqlPath = Join-Path $Target 'database.sql'
    if (-not (Test-Path -LiteralPath $sqlPath -PathType Leaf)) { Invoke-Die "No database.sql in $Target" }

    Write-Banner 'Restore Database'
    Write-Host ''
    $meta = Read-TextFile -Path (Join-Path $Target 'metadata.txt')
    if ($meta) { Write-Host $meta }
    Write-Host ''
    Write-LogWarn 'This REPLACES the current database contents.'
    if (-not (Confirm-Action -Question "Restore from $(Split-Path -Leaf $Target)?" -Default 'n')) {
        Write-LogInfo 'Cancelled.'
        return 0
    }

    # Take a safety copy first: a restore that goes wrong should still be
    # recoverable.
    Write-LogInfo 'Creating a safety backup of the current database...'
    if (-not (New-DatabaseBackup -Label 'pre-restore')) {
        Write-LogWarn 'Could not create a safety backup.'
    }

    if (-not (Test-SupabasePostgres)) { Invoke-Die 'The database is not running.' }

    Write-LogInfo 'Restoring...'
    # Not -SingleTransaction: a pg_dumpall script contains \connect commands and
    # multiple databases, which cannot run inside one transaction.
    if (-not (Invoke-DbSqlFile -Path $sqlPath -Description 'database restore')) {
        Invoke-Die "Restore failed. See $($script:SO_LOG_FILE)."
    }

    Write-LogOk "Database restored from $(Split-Path -Leaf $Target)"
    Write-LogInfo 'Restarting Supabase so every service reconnects...'
    if (-not (Restart-Supabase)) { Write-LogWarn 'Could not restart Supabase automatically.' }
    if (-not (Test-SupabaseHealth -TimeoutSeconds 180)) {
        Write-LogWarn 'Supabase is not fully healthy after the restore.'
    }
    return 0
}

# ---------------------------------------------------------------------------
# Rollback
#
# The database is deliberately NOT rolled back automatically: a migration may
# have been applied that the old code still tolerates, and silently reverting
# schema is far more destructive than leaving it. The matching backup is named
# so an operator can restore it explicitly.
# ---------------------------------------------------------------------------

function Invoke-CmdRollback {
    if (-not (Test-InstallationExists)) { Invoke-Die "No installation found at $($script:INSTALL_DIR)." }
    [void](Import-Config)
    [void](Find-ComposeCommand)
    $script:SO_LOG_FILE = Join-Path $script:LOG_DIR "rollback-$(Get-Timestamp).log"

    $prevImage  = Get-State -Key 'PREVIOUS_APP_IMAGE'  -Fallback ''
    $prevCommit = Get-State -Key 'PREVIOUS_APP_COMMIT' -Fallback ''

    if (-not $prevImage) { Invoke-Die 'No previous image recorded; cannot roll back.' }
    $null = Invoke-Capture -Command 'docker' -Arguments @('image', 'inspect', $prevImage)
    if ($LASTEXITCODE -ne 0) {
        Invoke-Die "The previous image $prevImage is no longer present on this host."
    }

    Write-Banner 'Rollback'
    Write-Host ''
    Write-StatusLine -Label 'Current image' -Text (Get-State -Key 'APP_IMAGE' -Fallback 'unknown')
    Write-StatusLine -Label 'Roll back to'  -Text $prevImage
    if ($prevCommit) {
        Write-StatusLine -Label 'Commit' -Text $prevCommit.Substring(0, [Math]::Min(7, $prevCommit.Length))
    }
    Write-Host ''
    Write-LogWarn 'Database migrations are NOT reverted.'
    $latest = Get-LatestBackup
    if ($latest) { Write-LogInfo "Most recent backup: $latest" }
    Write-Host ''
    if (-not (Confirm-Action -Question 'Proceed with the rollback?' -Default 'n')) {
        Write-LogInfo 'Cancelled.'
        return 0
    }

    $currentImage = Get-State -Key 'APP_IMAGE' -Fallback ''

    if ((Start-FrontendContainer -Name $script:APP_CONTAINER_NAME -Image $prevImage -HostPort $script:APP_PORT) -and
        (Wait-For -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { Test-FrontendHttp -Port $script:APP_PORT })) {
        Set-State -Key 'APP_IMAGE'          -Value $prevImage
        Set-State -Key 'PREVIOUS_APP_IMAGE' -Value $currentImage
        if ($prevCommit) { Set-State -Key 'APP_COMMIT' -Value $prevCommit }
        Update-StateTimestamp
        Write-LogOk "Rolled back to $prevImage"

        # Move the checkout back so the next update starts from the right base.
        if ($prevCommit -and (Test-RepoCloned)) {
            $null = Invoke-AppGit -Arguments @('checkout', '--quiet', $prevCommit)
            if ($LASTEXITCODE -eq 0) {
                Write-LogOk "Checkout moved to $($prevCommit.Substring(0, [Math]::Min(7, $prevCommit.Length))) (detached HEAD)"
                Write-LogInfo "Re-attach with: git -C $($script:APP_DIR) checkout $($script:APP_BRANCH)"
            } else {
                Write-LogWarn "Could not move the checkout to $($prevCommit.Substring(0, [Math]::Min(7, $prevCommit.Length)))."
            }
        }
        return 0
    }

    Write-LogError 'Rollback failed; the frontend is not healthy.'
    return 1
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

function Invoke-CmdLogs {
    param(
        [string]$Target = 'app',
        [string]$Lines = '100'
    )
    if (-not (Test-InstallationExists)) { Invoke-Die "No installation found at $($script:INSTALL_DIR)." }
    [void](Import-Config)
    [void](Find-ComposeCommand)

    switch ($Target) {
        { $_ -in @('app', 'frontend') } {
            & docker logs --tail $Lines -f $script:APP_CONTAINER_NAME
        }
        'supabase' {
            Invoke-ComposePassthrough -WorkingDirectory $script:SUPABASE_DIR `
                -Arguments ((Get-SupabaseComposeArgs) + @('logs', '--tail', $Lines, '-f'))
        }
        { $_ -in @('logflare', 'analytics') } {
            if ((Get-State -Key 'LOGFLARE_MODE' -Fallback 'overlay') -eq 'standalone') {
                Invoke-ComposePassthrough -WorkingDirectory $script:LOGFLARE_DIR -Arguments @(
                    '--env-file', (Join-Path $script:LOGFLARE_DIR '.env'), '-f', 'docker-compose.yml',
                    'logs', '--tail', $Lines, '-f')
            } else {
                Invoke-ComposePassthrough -WorkingDirectory $script:SUPABASE_DIR `
                    -Arguments ((Get-SupabaseComposeArgs) + @('logs', '--tail', $Lines, '-f', 'analytics'))
            }
        }
        'installer' {
            # By modification time, not by name: the filenames are prefixed with
            # the operation (install-, update-app-, rollback-), so sorting them
            # alphabetically returns whichever prefix sorts last rather than the
            # log that was actually written most recently.
            $logs = @(Get-ChildItem -LiteralPath $script:LOG_DIR -Filter '*.log' -File -ErrorAction SilentlyContinue |
                      Sort-Object -Property LastWriteTime)
            if ($logs.Count -eq 0) { Invoke-Die 'No installer logs yet.' }
            $latest = $logs[-1].FullName
            Write-Host $latest
            Write-Host ''
            Get-Content -LiteralPath $latest -Tail ([int]$Lines)
        }
        default {
            Write-LogError "Unknown log target: $Target"
            Write-Host 'Valid: app, supabase, logflare, installer'
            return 2
        }
    }
    return 0
}
