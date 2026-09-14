# lib/Database.ps1 - migrations, edge functions and database backups.
#
# Counterpart of lib/database.sh. These operations are shared verbatim by first
# install, application update and full update: there is exactly one
# implementation of each.
#
# Windows divergence: the Linux build pipes SQL into `docker exec -i psql` and
# redirects `pg_dumpall` into a file with the shell. Neither is safe here -
# PowerShell 5.1 would re-encode a redirected stream as UTF-16 and corrupt every
# dump, and piping text into a container's stdin re-encodes it the same way. So
# SQL goes in by `docker cp` + `psql -f`, and dumps come out through an
# OS-level redirect that never passes through PowerShell's text pipeline.

$script:BACKUP_RETENTION = 10
if ($env:BACKUP_RETENTION) { $script:BACKUP_RETENTION = [int]$env:BACKUP_RETENTION }

# ---------------------------------------------------------------------------
# Low-level database access
# ---------------------------------------------------------------------------

function Get-DbContainer {
    $cid = Get-SupabaseContainerId -Service (Get-SupabaseDbService)
    if (-not $cid) {
        Write-LogError 'The Supabase database container is not running.'
        return $null
    }
    return $cid
}

function Get-DbUser {
    $v = Get-EnvValue -Path (Join-Path $script:SUPABASE_DIR '.env') -Key 'POSTGRES_USER'
    if ([string]::IsNullOrEmpty($v)) { return 'postgres' }
    return $v
}

function Get-DbName {
    $v = Get-EnvValue -Path (Join-Path $script:SUPABASE_DIR '.env') -Key 'POSTGRES_DB'
    if ([string]::IsNullOrEmpty($v)) { return 'postgres' }
    return $v
}

function Get-DbPassword {
    $v = Get-EnvValue -Path (Join-Path $script:SUPABASE_DIR '.env') -Key 'POSTGRES_PASSWORD'
    if ([string]::IsNullOrEmpty($v)) { return '' }
    return $v
}

# Copy a SQL file into the database container and run it there.
# Returns $true on success.
function Invoke-DbSqlFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SingleTransaction,
        [string]$Description = 'psql'
    )
    $cid = Get-DbContainer
    if (-not $cid) { return $false }

    $remote = '/tmp/sentinel-ops-' + [Guid]::NewGuid().ToString('N') + '.sql'
    if (-not (Invoke-Logged -Description 'docker cp sql' -Command 'docker' `
            -Arguments @('cp', $Path, "${cid}:${remote}"))) {
        return $false
    }

    $psqlArgs = @('exec', '-e', "PGPASSWORD=$(Get-DbPassword)", $cid,
                  'psql', '-U', (Get-DbUser), '-d', (Get-DbName), '-v', 'ON_ERROR_STOP=1', '-q')
    if ($SingleTransaction) { $psqlArgs += '--single-transaction' }
    $psqlArgs += @('-f', $remote)

    $ok = Invoke-Logged -Description $Description -Command 'docker' -Arguments $psqlArgs

    $null = Invoke-Capture -Command 'docker' -Arguments @('exec', $cid, 'rm', '-f', $remote)
    return $ok
}

# Run a single query and return the bare result.
function Invoke-DbQuery {
    param([Parameter(Mandatory)][string]$Sql)
    $cid = Get-DbContainer
    if (-not $cid) { return '' }
    return (Invoke-Capture -Command 'docker' -Arguments @(
        'exec', '-e', "PGPASSWORD=$(Get-DbPassword)", $cid,
        'psql', '-U', (Get-DbUser), '-d', (Get-DbName), '-tAq', '-c', $Sql))
}

# ---------------------------------------------------------------------------
# Migrations
#
# The tracking table is the same one the Supabase CLI uses
# (supabase_migrations.schema_migrations), so a database migrated by this
# installer stays compatible with `supabase db push` and vice versa.
# ---------------------------------------------------------------------------

function Initialize-MigrationTable {
    $sql = @'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
    version    text NOT NULL PRIMARY KEY,
    statements text[],
    name       text
);
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('so-migtable-' + [Guid]::NewGuid().ToString('N') + '.sql')
    try {
        Write-TextFile -Path $tmp -Content $sql
        return (Invoke-DbSqlFile -Path $tmp -Description 'create migration tracking table')
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# The version is the leading numeric timestamp of the filename, matching the
# Supabase CLI's convention: 20240101120000_add_users.sql -> 20240101120000
function Get-MigrationVersion {
    param([Parameter(Mandatory)][string]$BaseName)
    $b = $BaseName -replace '\.sql$', ''
    return ($b -split '_')[0]
}

function Get-MigrationName {
    param([Parameter(Mandatory)][string]$BaseName)
    $b = $BaseName -replace '\.sql$', ''
    $i = $b.IndexOf('_')
    if ($i -ge 0) { return $b.Substring($i + 1) }
    return $b
}

function ConvertTo-SqlLiteral {
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace("'", "''")
}

# Apply every pending migration, in filename order.
#
# Each migration runs in a single transaction together with the row that records
# it, so a failed migration leaves neither partial schema changes nor a bogus
# tracking entry.
function Invoke-Migrations {
    $dir = Join-Path $script:APP_DIR 'supabase\migrations'
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-LogError "No migrations directory at $dir"
        return $false
    }
    if (-not (Get-DbContainer)) { return $false }

    if (-not (Initialize-MigrationTable)) {
        Write-LogError 'Could not create the migration tracking table.'
        return $false
    }

    $appliedRaw = Invoke-DbQuery -Sql 'SELECT version FROM supabase_migrations.schema_migrations;'
    $applied = @()
    if ($appliedRaw) { $applied = @($appliedRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    # Ordinal sort, so the ordering matches the Linux build's LC_ALL=C sort
    # rather than the operator's locale.
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.sql' -File |
               Sort-Object -Property Name -Culture ([System.Globalization.CultureInfo]::InvariantCulture))

    if ($files.Count -eq 0) {
        Write-LogWarn "No migration files found in $dir"
        return $true
    }

    $pending = @()
    foreach ($f in $files) {
        $version = Get-MigrationVersion -BaseName $f.Name
        if ($applied -contains $version) {
            Write-LogDebug "already applied: $($f.Name)"
        } else {
            $pending += $f
        }
    }

    if ($pending.Count -eq 0) {
        Write-LogOk "Database schema up to date ($($files.Count) migrations already applied)"
        return $true
    }

    Write-LogInfo "Applying $($pending.Count) pending migration(s)..."
    $count = 0
    foreach ($f in $pending) {
        $version = Get-MigrationVersion -BaseName $f.Name
        $name    = Get-MigrationName    -BaseName $f.Name
        Write-LogInfo "  $($f.Name)"

        $body = Read-TextFile -Path $f.FullName
        $combined = $body + "`n" +
            ("INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('{0}', '{1}');" -f `
                (ConvertTo-SqlLiteral $version), (ConvertTo-SqlLiteral $name)) + "`n"

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('so-mig-' + [Guid]::NewGuid().ToString('N') + '.sql')
        try {
            Write-TextFile -Path $tmp -Content $combined
            if (-not (Invoke-DbSqlFile -Path $tmp -SingleTransaction -Description "migration $($f.Name)")) {
                Write-LogError "Migration failed: $($f.Name)"
                Write-LogError 'The transaction was rolled back; the database is unchanged by this migration.'
                Write-LogError "Applied before the failure: $count migration(s)."
                return $false
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        $count++
    }

    Write-LogOk "Applied $count migration(s)"
    return $true
}

function Get-AppliedMigrationCount {
    $c = Invoke-DbQuery -Sql 'SELECT count(*) FROM supabase_migrations.schema_migrations;'
    if (-not $c) { return '?' }
    return $c.Trim()
}

# ---------------------------------------------------------------------------
# Edge functions
#
# On a self-hosted stack the edge runtime serves whatever is mounted at
# supabase/volumes/functions. Deploying therefore means syncing the repository's
# functions into that volume and restarting the runtime - `supabase functions
# deploy` targets the hosted platform and does not apply here.
# ---------------------------------------------------------------------------

function Get-FunctionsService {
    $services = Invoke-SupabaseComposeCapture -Arguments @('config', '--services')
    if ($services) {
        $list = @($services -split "`n" | ForEach-Object { $_.Trim() })
        foreach ($s in @('functions', 'edge-runtime', 'deno-relay')) {
            if ($list -contains $s) { return $s }
        }
    }
    return 'functions'
}

function Invoke-FunctionsDeploy {
    $src  = Join-Path $script:APP_DIR 'supabase\functions'
    $dest = Join-Path $script:SUPABASE_DIR 'volumes\functions'

    if (-not (Test-Path -LiteralPath $src)) {
        Write-LogError "No functions directory at $src"
        return $false
    }
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    }

    # Enumerate the functions: every immediate subdirectory holding an entry
    # point. Directories starting with _ are shared code, not functions.
    $names = @()
    foreach ($d in (Get-ChildItem -LiteralPath $src -Directory | Sort-Object Name)) {
        if ($d.Name.StartsWith('_')) { continue }
        foreach ($entry in @('index.ts', 'index.js', 'mod.ts')) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName $entry) -PathType Leaf) {
                $names += $d.Name
                break
            }
        }
    }

    if ($names.Count -eq 0) {
        Write-LogWarn "No deployable edge functions found in $src"
    } else {
        Write-LogInfo "Deploying $($names.Count) edge function(s): $($names -join ' ')"
    }

    # The stack ships a `main` bootstrap function that routes requests to the
    # others. It is infrastructure, not application code, so it is preserved.
    $preserved = $null
    $destMain = Join-Path $dest 'main'
    if ((Test-Path -LiteralPath $destMain) -and -not (Test-Path -LiteralPath (Join-Path $src 'main'))) {
        $preserved = Join-Path ([System.IO.Path]::GetTempPath()) ('so-main-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $preserved | Out-Null
        Copy-Item -LiteralPath $destMain -Destination (Join-Path $preserved 'main') -Recurse -Force
    }

    try {
        # Replace the application functions wholesale so a function deleted from
        # the repository also disappears from the deployment.
        foreach ($d in (Get-ChildItem -LiteralPath $dest -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -eq 'main') { continue }
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

        Copy-TreeExcluding -Source $src -Destination $dest

        if ($preserved -and -not (Test-Path -LiteralPath $destMain)) {
            Copy-Item -LiteralPath (Join-Path $preserved 'main') -Destination $destMain -Recurse -Force
        }
    } catch {
        Write-LogError "Could not copy functions into ${dest}: $_"
        return $false
    } finally {
        if ($preserved) { Remove-Item -LiteralPath $preserved -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Restart the runtime so it picks up the new code.
    $svc = Get-FunctionsService
    Write-LogInfo "Restarting the edge runtime ($svc)..."
    if (-not (Invoke-SupabaseCompose -Description "restart $svc" `
            -Arguments @('up', '-d', '--force-recreate', $svc))) {
        Write-LogError 'Could not restart the edge runtime.'
        return $false
    }

    # Confirm it actually came back up; a syntax error in a function can stop
    # the runtime from booting at all.
    if (-not (Wait-For -TimeoutSeconds 60 -IntervalSeconds 3 -Condition { Test-SupabaseServiceRunning -Service $svc })) {
        Write-LogError 'The edge runtime did not stay running after deployment.'
        $cid = Get-SupabaseContainerId -Service $svc
        if ($cid) { Write-ContainerLogTail -Name $cid -Lines 40 }
        return $false
    }

    $fnList = 'none'
    if ($names.Count -gt 0) { $fnList = ($names -join ' ') }
    Set-State -Key 'APP_FUNCTIONS' -Value $fnList
    Write-LogOk 'Edge functions deployed'
    return $true
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

# Run a native command with its stdout redirected straight to a file by the OS.
#
# This is the only safe way to capture pg_dumpall on Windows PowerShell: the
# `>` operator and Out-File both round-trip through PowerShell's text pipeline,
# which on 5.1 writes UTF-16 by default and would corrupt every dump.
function Invoke-NativeToFile {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$ErrFile = ''
    )
    if (-not $ErrFile) {
        $ErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('so-err-' + [Guid]::NewGuid().ToString('N') + '.log')
    }
    $exe = (Get-Command $Command -ErrorAction SilentlyContinue)
    if (-not $exe) { return $false }

    $proc = Start-Process -FilePath $exe.Source -ArgumentList $Arguments `
                          -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
                          -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        $err = Read-TextFile -Path $ErrFile
        if ($err) { Write-LogFileLine $err }
        return $false
    }
    return $true
}

# Dump the database and record what was running at the time.
# Returns the backup directory path, or $null.
function New-DatabaseBackup {
    param([string]$Label = 'manual')

    $cid = Get-DbContainer
    if (-not $cid) {
        Write-LogError 'Cannot back up: the database is not running.'
        return $null
    }

    $stamp = Get-Timestamp
    $dir = Join-Path $script:BACKUP_DIR $stamp
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sqlPath = Join-Path $dir 'database.sql'

    Write-LogInfo "Backing up the database to $dir..."
    # pg_dumpall captures roles and every database, which is what a restore of a
    # Supabase stack actually needs.
    $ok = Invoke-NativeToFile -Command 'docker' -OutFile $sqlPath -Arguments @(
        'exec', '-e', "PGPASSWORD=$(Get-DbPassword)", $cid,
        'pg_dumpall', '-U', (Get-DbUser), '--clean', '--if-exists')

    if (-not $ok -or -not (Test-Path -LiteralPath $sqlPath -PathType Leaf) -or
        (Get-Item -LiteralPath $sqlPath).Length -eq 0) {
        Write-LogError 'Database dump failed.'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    $size = (Get-Item -LiteralPath $sqlPath).Length
    $meta = @(
        "timestamp=$(Get-IsoTimestamp)",
        "reason=$Label",
        "installer_version=$($script:SO_INSTALLER_VERSION)",
        "supabase_version=$(Get-SupabaseVersion)",
        "app_commit=$(Get-State -Key 'APP_COMMIT' -Fallback 'unknown')",
        "app_branch=$($script:APP_BRANCH)",
        "app_image=$(Get-State -Key 'APP_IMAGE' -Fallback 'unknown')",
        "size_bytes=$size"
    ) -join "`n"
    Write-TextFile -Path (Join-Path $dir 'metadata.txt') -Content ($meta + "`n")

    [void](Set-RestrictedAcl -Path $dir)
    Write-LogOk ("Backup created: {0} ({1:N1} MB)" -f $dir, ($size / 1MB))

    Remove-OldBackups
    return $dir
}

# Keep only the most recent $BACKUP_RETENTION backups.
function Remove-OldBackups {
    $dirs = @(Get-ChildItem -LiteralPath $script:BACKUP_DIR -Directory -ErrorAction SilentlyContinue |
              Sort-Object -Property Name -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
    if ($dirs.Count -le $script:BACKUP_RETENTION) { return }
    $excess = $dirs.Count - $script:BACKUP_RETENTION
    foreach ($d in $dirs[0..($excess - 1)]) {
        Write-LogDebug "pruning old backup $($d.FullName)"
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LatestBackup {
    $dirs = @(Get-ChildItem -LiteralPath $script:BACKUP_DIR -Directory -ErrorAction SilentlyContinue |
              Sort-Object -Property Name -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
    if ($dirs.Count -eq 0) { return $null }
    return $dirs[-1].FullName
}
