# lib/Logflare.ps1 - Supabase Analytics (Logflare) deployment.
#
# Counterpart of lib/logflare.sh, following the official self-hosting guide:
#   https://supabase.com/docs/reference/self-hosting-analytics/introduction
#
# Logflare is a phase of its own - it is NOT assumed to exist just because
# Supabase was installed. Upstream ships it as an optional compose overlay
# (docker-compose.logs.yml) adding two services: analytics (Logflare) and
# vector (log collection).
#
# The Linux build has four deployment paths, the preferred one being
# `sh run.sh config add logs`. Windows has no POSIX shell, so that path is gone
# and three remain:
#
#   overlay     docker-compose.logs.yml exists -> included as an explicit -f
#   bundled     analytics already in the base compose file
#   standalone  neither -> our own compose file
#
# Because Get-SupabaseComposeArgs already adds the overlay whenever
# ENABLE_LOGFLARE is true, "enabling" it here is a matter of configuration
# rather than of rewriting COMPOSE_FILE.

# Logflare's HTTP port inside the container. Upstream deliberately does not
# publish it to the host - access is meant to go through the API gateway.
$script:LOGFLARE_PORT = '4000'
$script:LOGFLARE_MODE = ''

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------

function Get-LogflareMode {
    if (Test-Path -LiteralPath (Join-Path $script:SUPABASE_DIR 'docker-compose.logs.yml') -PathType Leaf) {
        $script:LOGFLARE_MODE = 'overlay'
    } else {
        $services = Invoke-SupabaseComposeCapture -Arguments @('config', '--services')
        $list = @()
        if ($services) { $list = @($services -split "`n" | ForEach-Object { $_.Trim() }) }
        if ($list -contains 'analytics') {
            $script:LOGFLARE_MODE = 'bundled'
        } else {
            $script:LOGFLARE_MODE = 'standalone'
        }
    }
    Write-LogDebug "logflare mode: $($script:LOGFLARE_MODE)"
    return $script:LOGFLARE_MODE
}

# ---------------------------------------------------------------------------
# Configuration prompts
# ---------------------------------------------------------------------------

function Read-LogflarePromptConfig {
    Write-Section 'Analytics (Logflare)'

    if (-not (Confirm-Action -Question 'Enable Logflare analytics (log aggregation)?' -Default 'y')) {
        $script:ENABLE_LOGFLARE = 'false'
        return
    }
    $script:ENABLE_LOGFLARE = 'true'

    Write-Host ''
    Write-Host 'Storage backend:'
    Write-Host '  postgres  - no extra services; upstream notes it is not optimised'
    Write-Host '              for high-volume ingest or heavy querying'
    Write-Host '  bigquery  - recommended for production; needs a Google Cloud'
    Write-Host '              project with billing enabled and a service-account key'
    Write-Host ''

    $backend = Read-DefaultPrompt -Question 'Backend [postgres/bigquery]' -Default $script:LOGFLARE_BACKEND
    if ($backend -in @('bigquery', 'bq')) {
        $script:LOGFLARE_BACKEND = 'bigquery'
    } else {
        $script:LOGFLARE_BACKEND = 'postgres'
    }

    if ($script:LOGFLARE_BACKEND -eq 'bigquery') {
        $script:GOOGLE_PROJECT_ID     = Read-DefaultPrompt -Question 'Google Cloud project ID'     -Default $script:GOOGLE_PROJECT_ID
        $script:GOOGLE_PROJECT_NUMBER = Read-DefaultPrompt -Question 'Google Cloud project number' -Default $script:GOOGLE_PROJECT_NUMBER
        Write-Host ''
        Write-LogInfo "Place the service-account key at: $(Join-Path $script:SUPABASE_DIR 'gcloud.json')"
        Write-LogWarn 'Never commit gcloud.json to version control.'
    }
}

# ---------------------------------------------------------------------------
# Supabase-side configuration
#
# In every mode except standalone the compose overlay defines the analytics
# service itself and only interpolates these variables out of supabase/.env. We
# therefore set the documented variables and do NOT attempt to redefine the
# service's own connection settings.
# ---------------------------------------------------------------------------
function Set-LogflareSupabaseConfig {
    $envFile = Join-Path $script:SUPABASE_DIR '.env'

    # Access tokens. Generated once and never rotated automatically - vector,
    # Logflare and Studio all authenticate with these same values.
    foreach ($key in @('LOGFLARE_PUBLIC_ACCESS_TOKEN', 'LOGFLARE_PRIVATE_ACCESS_TOKEN')) {
        $val = Get-EnvValue -Path $envFile -Key $key
        if (Test-IsPlaceholderSecret $val) {
            Set-EnvValue -Path $envFile -Key $key -Value (New-RandomToken 32)
            Write-LogDebug "generated $key"
        }
    }

    # Encryption key for sensitive Logflare database columns. Upstream requires
    # this to be base64 and warns it is mandatory for production use.
    $val = Get-EnvValue -Path $envFile -Key 'LOGFLARE_DB_ENCRYPTION_KEY'
    if ([string]::IsNullOrEmpty($val)) {
        Set-EnvValue -Path $envFile -Key 'LOGFLARE_DB_ENCRYPTION_KEY' -Value (New-RandomBase64 32)
        Write-LogDebug 'generated LOGFLARE_DB_ENCRYPTION_KEY'
    }
    # Present but empty is correct until a key rotation is in progress.
    if ($null -eq (Get-EnvValue -Path $envFile -Key 'LOGFLARE_DB_ENCRYPTION_KEY_RETIRED')) {
        Set-EnvValue -Path $envFile -Key 'LOGFLARE_DB_ENCRYPTION_KEY_RETIRED' -Value ''
    }

    # Single-tenant Supabase mode: no account creation, and the Supabase log
    # sources Studio expects are seeded automatically.
    Set-EnvValue -Path $envFile -Key 'LOGFLARE_SINGLE_TENANT' -Value 'true'
    Set-EnvValue -Path $envFile -Key 'LOGFLARE_SUPABASE_MODE' -Value 'true'

    # vector mounts the Docker socket to collect container logs. On Docker
    # Desktop the socket lives inside the Linux VM at the usual path, so the
    # Linux default is correct here and the existence check the Linux build does
    # against the host filesystem would be meaningless (and would always fail).
    Set-EnvValue -Path $envFile -Key 'DOCKER_SOCKET_LOCATION' -Value '/var/run/docker.sock'

    if ($script:LOGFLARE_BACKEND -eq 'bigquery') {
        if ($script:GOOGLE_PROJECT_ID)     { Set-EnvValue -Path $envFile -Key 'GOOGLE_PROJECT_ID'     -Value $script:GOOGLE_PROJECT_ID }
        if ($script:GOOGLE_PROJECT_NUMBER) { Set-EnvValue -Path $envFile -Key 'GOOGLE_PROJECT_NUMBER' -Value $script:GOOGLE_PROJECT_NUMBER }
        $gcloud = Join-Path $script:SUPABASE_DIR 'gcloud.json'
        if (-not (Test-Path -LiteralPath $gcloud -PathType Leaf)) {
            Write-LogError "BigQuery backend selected but $gcloud is missing."
            Write-LogError 'Place the service-account key there and re-run, or switch to the postgres backend.'
            return $false
        }
        [void](Set-RestrictedAcl -Path $gcloud)
    } else {
        # Postgres backend. Only set this when the overlay has not already wired
        # it up, so we never fight the upstream compose file.
        if ([string]::IsNullOrEmpty((Get-EnvValue -Path $envFile -Key 'POSTGRES_BACKEND_SCHEMA'))) {
            Set-EnvValue -Path $envFile -Key 'POSTGRES_BACKEND_SCHEMA' -Value '_analytics'
        }
    }

    [void](Set-RestrictedAcl -Path $envFile)
    Write-LogOk 'Supabase analytics variables configured'
    return $true
}

# ---------------------------------------------------------------------------
# Standalone deployment (only when upstream ships no analytics service at all)
# ---------------------------------------------------------------------------

function Invoke-LogflareCompose {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $pre = @('--env-file', (Join-Path $script:LOGFLARE_DIR '.env'), '-f', 'docker-compose.yml')
    return (Invoke-Compose -Description $Description -Arguments ($pre + $Arguments) `
                           -WorkingDirectory $script:LOGFLARE_DIR)
}

function Invoke-LogflareComposeCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $pre = @('--env-file', (Join-Path $script:LOGFLARE_DIR '.env'), '-f', 'docker-compose.yml')
    return (Invoke-ComposeCapture -Arguments ($pre + $Arguments) -WorkingDirectory $script:LOGFLARE_DIR)
}

function Install-LogflareStandalone {
    $template = Join-Path $script:SO_ASSETS_DIR 'logflare\docker-compose.yml'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        Write-LogError "Missing Logflare template: $template"
        return $false
    }

    if (-not (Test-Path -LiteralPath $script:LOGFLARE_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:LOGFLARE_DIR | Out-Null
    }
    Copy-Item -LiteralPath $template -Destination (Join-Path $script:LOGFLARE_DIR 'docker-compose.yml') -Force

    $sbEnv   = Join-Path $script:SUPABASE_DIR '.env'
    $envFile = Join-Path $script:LOGFLARE_DIR '.env'

    $pgPass = Get-EnvValue -Path $sbEnv -Key 'POSTGRES_PASSWORD'
    $pgUser = Get-EnvValue -Path $sbEnv -Key 'POSTGRES_USER'; if (-not $pgUser) { $pgUser = 'postgres' }
    $pgDb   = Get-EnvValue -Path $sbEnv -Key 'POSTGRES_DB';   if (-not $pgDb)   { $pgDb   = 'postgres' }

    $lines = @(
        '# Logflare standalone deployment - generated by sentinel-ops',
        "LOGFLARE_PORT=$($script:LOGFLARE_PORT)",
        'LOGFLARE_SINGLE_TENANT=true',
        'LOGFLARE_SUPABASE_MODE=true',
        "LOGFLARE_PUBLIC_ACCESS_TOKEN=$(Get-EnvValue -Path $sbEnv -Key 'LOGFLARE_PUBLIC_ACCESS_TOKEN')",
        "LOGFLARE_PRIVATE_ACCESS_TOKEN=$(Get-EnvValue -Path $sbEnv -Key 'LOGFLARE_PRIVATE_ACCESS_TOKEN')",
        "LOGFLARE_DB_ENCRYPTION_KEY=$(Get-EnvValue -Path $sbEnv -Key 'LOGFLARE_DB_ENCRYPTION_KEY')",
        "LOGFLARE_SECRET_KEY_BASE=$(New-RandomToken 32)",
        "LOGFLARE_SUPABASE_NETWORK=$(Get-SupabaseNetworkName)",
        "LOGFLARE_BACKEND=$($script:LOGFLARE_BACKEND)",
        ("POSTGRES_BACKEND_URL=postgresql://{0}:{1}@{2}:5432/{3}" -f $pgUser, $pgPass, (Get-SupabaseDbService), $pgDb),
        'POSTGRES_BACKEND_SCHEMA=_analytics',
        "GOOGLE_PROJECT_ID=$($script:GOOGLE_PROJECT_ID)",
        "GOOGLE_PROJECT_NUMBER=$($script:GOOGLE_PROJECT_NUMBER)"
    )
    Write-TextFile -Path $envFile -Content (($lines -join "`n") + "`n")
    [void](Set-RestrictedAcl -Path $envFile)

    Write-LogInfo 'Starting standalone Logflare...'
    return (Invoke-LogflareCompose -Description 'logflare up' -Arguments @('up', '-d'))
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Install-Logflare {
    if ($script:ENABLE_LOGFLARE -ne 'true') {
        Write-LogInfo 'Logflare is disabled in the configuration; skipping.'
        return $true
    }

    [void](Get-LogflareMode)
    if (-not (Set-LogflareSupabaseConfig)) { return $false }

    switch ($script:LOGFLARE_MODE) {
        'overlay' {
            # The overlay is already part of the compose argument list, so the
            # stack only needs to be brought back up to pick up the new services.
            Write-LogInfo 'Starting the Supabase stack with the analytics overlay...'
            if (-not (Invoke-SupabaseCompose -Description 'start analytics' `
                    -Arguments @('up', '-d', '--remove-orphans'))) { return $false }
        }
        'bundled' {
            Write-LogInfo 'Analytics is part of the base compose file; starting it.'
            if (-not (Invoke-SupabaseCompose -Description 'start analytics' `
                    -Arguments @('up', '-d', 'analytics', 'vector'))) {
                Write-LogWarn 'Could not start the analytics services individually.'
            }
        }
        'standalone' {
            Write-LogInfo 'Upstream ships no analytics service; deploying Logflare separately.'
            if (-not (Install-LogflareStandalone)) { return $false }
        }
    }

    Set-State -Key 'LOGFLARE_MODE'    -Value $script:LOGFLARE_MODE
    Set-State -Key 'LOGFLARE_BACKEND' -Value $script:LOGFLARE_BACKEND

    # Upstream warns that the Logflare dashboard has no authentication of its
    # own, so it must never be exposed publicly.
    Write-LogWarn "Logflare's /dashboard has no authentication - do not expose port $($script:LOGFLARE_PORT) publicly."
    return $true
}

# ---------------------------------------------------------------------------
# Health
#
# Port 4000 is not published to the host by default, so the probe runs inside
# the container. Each step falls back to the next.
# ---------------------------------------------------------------------------

function Get-LogflareContainer {
    $mode = Get-State -Key 'LOGFLARE_MODE' -Fallback $script:LOGFLARE_MODE
    if ($mode -eq 'standalone') {
        $out = Invoke-LogflareComposeCapture -Arguments @('ps', '-q', 'logflare')
        if (-not $out) { return '' }
        return (@($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)).Trim()
    }
    return (Get-SupabaseContainerId -Service 'analytics')
}

function Test-Logflare {
    $cid = Get-LogflareContainer
    if (-not $cid) { return $false }

    # 1. In-container HTTP probe (the port is not exposed to the host).
    $null = Invoke-Capture -Command 'docker' -Arguments @('exec', $cid, 'sh', '-c',
        'command -v curl >/dev/null && curl -fsS http://127.0.0.1:4000/health >/dev/null')
    if ($LASTEXITCODE -eq 0) { return $true }

    $null = Invoke-Capture -Command 'docker' -Arguments @('exec', $cid, 'sh', '-c',
        'command -v wget >/dev/null && wget -qO- http://127.0.0.1:4000/health >/dev/null')
    if ($LASTEXITCODE -eq 0) { return $true }

    # 2. The host port, in case this deployment publishes it.
    if ((Get-HttpCode -Url "http://127.0.0.1:$($script:LOGFLARE_PORT)/health") -eq '200') { return $true }

    # 3. Docker's own healthcheck verdict.
    $health = Invoke-Capture -Command 'docker' -Arguments @(
        'inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $cid)
    return ($health -eq 'healthy')
}

function Test-LogflareRunning {
    $cid = Get-LogflareContainer
    if (-not $cid) { return $false }
    $state = Invoke-Capture -Command 'docker' -Arguments @('inspect', '-f', '{{.State.Running}}', $cid)
    return ($state -eq 'true')
}

function Test-LogflareHealth {
    if ($script:ENABLE_LOGFLARE -ne 'true') { return $true }

    Write-LogInfo 'Waiting for Logflare...'
    # Logflare runs its database migrations on first boot, so the initial start
    # is slow; upstream's own healthcheck allows a 60s start period.
    if (Wait-For -TimeoutSeconds 180 -IntervalSeconds 5 -Condition { Test-Logflare }) {
        Write-LogOk 'Logflare available'
        return $true
    }

    if (Test-LogflareRunning) {
        # Degraded log aggregation must not take the application offline.
        Write-LogWarn 'Logflare is running but did not answer its health endpoint.'
        Write-LogWarn 'Check with: sentinel-ops logs logflare'
        return $true
    }

    Write-LogError 'Logflare failed health check'
    Write-LogError 'Check with: sentinel-ops logs logflare'
    return $false
}
