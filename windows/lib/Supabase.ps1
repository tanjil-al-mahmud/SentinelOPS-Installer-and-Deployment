# lib/Supabase.ps1 - self-hosted Supabase deployment, configuration and health.
#
# Counterpart of lib/supabase.sh, with three deliberate Windows divergences:
#
#   1. Staging. The Linux version prefers Supabase's official setup.sh. Windows
#      has no POSIX shell to run it with, so this build always takes the
#      documented fallback: a sparse checkout of the upstream docker/ directory.
#      Everything setup.sh would have generated is generated here instead.
#
#   2. Compose file selection. The Linux version relies on COMPOSE_FILE inside
#      supabase/.env. Windows uses ';' as the COMPOSE_FILE separator rather than
#      ':' (a ':' would split "C:\..."), and depending on Compose's env-file
#      ordering for something this load-bearing is fragile, so the file list is
#      computed here and passed as explicit -f arguments.
#
#   3. A generated docker-compose.windows.yml overlay. See
#      Write-WindowsComposeOverlay for why it is not optional.

$script:SUPABASE_REPO_URL = 'https://github.com/supabase/supabase.git'

# Files and directories that carry *state* and must survive an update.
# Everything else in the Supabase directory is deployment scaffolding and is
# refreshed from upstream.
$script:SUPABASE_PRESERVE = @(
    '.env',
    'docker-compose.windows.yml',
    'volumes/db/data',
    'volumes/storage',
    'volumes/functions'
)

$script:WINDOWS_OVERLAY_NAME = 'docker-compose.windows.yml'

# ---------------------------------------------------------------------------
# Compose helpers
# ---------------------------------------------------------------------------

# The compose files this deployment is made of, in merge order. Later files win,
# so the Windows overlay is always last.
function Get-SupabaseComposeArgs {
    $composeArgs = @('--env-file', (Join-Path $script:SUPABASE_DIR '.env'))
    $composeArgs += @('-f', 'docker-compose.yml')

    if ($script:ENABLE_LOGFLARE -eq 'true' -and
        (Test-Path -LiteralPath (Join-Path $script:SUPABASE_DIR 'docker-compose.logs.yml') -PathType Leaf)) {
        $composeArgs += @('-f', 'docker-compose.logs.yml')
    }
    if (Test-Path -LiteralPath (Join-Path $script:SUPABASE_DIR $script:WINDOWS_OVERLAY_NAME) -PathType Leaf) {
        $composeArgs += @('-f', $script:WINDOWS_OVERLAY_NAME)
    }
    return $composeArgs
}

function Invoke-SupabaseCompose {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    return (Invoke-Compose -Description $Description `
                           -Arguments ((Get-SupabaseComposeArgs) + $Arguments) `
                           -WorkingDirectory $script:SUPABASE_DIR)
}

function Invoke-SupabaseComposeCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return (Invoke-ComposeCapture -Arguments ((Get-SupabaseComposeArgs) + $Arguments) `
                                  -WorkingDirectory $script:SUPABASE_DIR)
}

# Resolve the container id backing a compose service ('' when not running).
function Get-SupabaseContainerId {
    param([Parameter(Mandatory)][string]$Service)
    $out = Invoke-SupabaseComposeCapture -Arguments @('ps', '-q', $Service)
    if (-not $out) { return '' }
    return (@($out -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
}

function Test-SupabaseServiceRunning {
    param([Parameter(Mandatory)][string]$Service)
    $cid = Get-SupabaseContainerId -Service $Service
    if (-not $cid) { return $false }
    $state = Invoke-Capture -Command 'docker' -Arguments @('inspect', '-f', '{{.State.Running}}', $cid)
    return ($state -eq 'true')
}

# Docker health status of a service: healthy | unhealthy | starting | none.
function Get-SupabaseServiceHealth {
    param([Parameter(Mandatory)][string]$Service)
    $cid = Get-SupabaseContainerId -Service $Service
    if (-not $cid) { return 'missing' }
    $status = Invoke-Capture -Command 'docker' -Arguments @(
        'inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $cid)
    if (-not $status) { return 'none' }
    return $status
}

function Get-SupabaseKongPort {
    $p = Get-EnvValue -Path (Join-Path $script:SUPABASE_DIR '.env') -Key 'KONG_HTTP_PORT'
    if ([string]::IsNullOrEmpty($p)) { return '8000' }
    return $p
}

function Test-SupabaseInstalled {
    return ((Test-Path -LiteralPath (Join-Path $script:SUPABASE_DIR 'docker-compose.yml') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $script:SUPABASE_DIR '.env') -PathType Leaf))
}

# The Docker network the Supabase stack runs on. Other components (the frontend,
# standalone Logflare) attach to it so they can reach Supabase by service name
# instead of going back out through the host.
function Get-SupabaseNetworkName {
    $cid = Get-SupabaseContainerId -Service (Get-SupabaseDbService)
    if ($cid) {
        $net = Invoke-Capture -Command 'docker' -Arguments @(
            'inspect', '-f', '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}', $cid)
        if ($net) {
            $first = (@($net -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($first) { return $first.Trim() }
        }
    }
    # Fall back to Compose's default naming: <project>_default, where the
    # project defaults to the sanitised directory name.
    $project = (Split-Path -Leaf $script:SUPABASE_DIR).ToLowerInvariant()
    $project = ($project -replace '[^a-z0-9_-]', '')
    return "${project}_default"
}

function Get-SupabaseVersion {
    $marker = Join-Path $script:SUPABASE_DIR '.supabase-version'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $v = (Read-TextFile -Path $marker)
        if ($v) { $v = $v.Trim() }
        if ($v) { return $v }
    }
    $v = Get-State -Key 'SUPABASE_VERSION' -Fallback ''
    if ($v) { return $v }
    return 'unknown'
}

# ---------------------------------------------------------------------------
# Fetching the upstream deployment
# ---------------------------------------------------------------------------

# Copy a directory tree, skipping stateful paths. The Linux version pipes tar
# through itself because rsync is missing on minimal RHEL; here it is a plain
# recursive copy with a relative-path exclusion test.
function Copy-TreeExcluding {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Exclude = @()
    )
    $src = (Resolve-Path -LiteralPath $Source).Path
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    $dst = (Resolve-Path -LiteralPath $Destination).Path

    # Normalise the exclusions to backslash-separated relative prefixes.
    $excl = @($Exclude | ForEach-Object { $_.Replace('/', '\').Trim('\') })

    $isExcluded = {
        param($rel)
        foreach ($e in $excl) {
            if ($rel -eq $e -or $rel.StartsWith($e + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    foreach ($item in Get-ChildItem -LiteralPath $src -Recurse -Force) {
        $rel = $item.FullName.Substring($src.Length).TrimStart('\')
        if (& $isExcluded $rel) { continue }
        $target = Join-Path $dst $rel
        if ($item.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            }
        } else {
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

# Download the official Supabase deployment into a staging directory.
# Returns the staged docker/ directory path, or $null on failure.
#
# Unlike the Linux build there is no setup.sh branch: running it would need a
# POSIX shell that Windows does not have. The sparse checkout is the whole path.
function Get-SupabaseUpstream {
    param([Parameter(Mandatory)][string]$StagingDir)

    Write-LogInfo 'Fetching the Supabase deployment files (docker/ from upstream)...'
    $repo = Join-Path $StagingDir '_repo'

    if (-not (Invoke-Logged -Description 'git clone supabase' -Command 'git' -Arguments @(
            'clone', '--depth', '1', '--filter=blob:none', '--sparse',
            $script:SUPABASE_REPO_URL, $repo))) {
        Write-LogError "Could not clone $($script:SUPABASE_REPO_URL)."
        return $null
    }

    if (-not (Invoke-Logged -Description 'git sparse-checkout' -Command 'git' -Arguments @(
            'sparse-checkout', 'set', 'docker') -WorkingDirectory $repo)) {
        return $null
    }

    $dockerDir = Join-Path $repo 'docker'
    if (-not (Test-Path -LiteralPath (Join-Path $dockerDir 'docker-compose.yml') -PathType Leaf)) {
        Write-LogError 'Supabase repository layout unexpected: docker/docker-compose.yml is missing.'
        return $null
    }

    # Record the upstream commit so `status` can report something meaningful.
    $sha = Invoke-Capture -Command 'git' -Arguments @('rev-parse', '--short', 'HEAD') -WorkingDirectory $repo
    if ($sha) { Write-TextFile -Path (Join-Path $StagingDir '_version') -Content ($sha + "`n") }

    return $dockerDir
}

# ---------------------------------------------------------------------------
# The Windows compose overlay
#
# Upstream bind-mounts the Postgres data directory and the storage directory
# from the host:
#     ./volumes/db/data:/var/lib/postgresql/data
#     ./volumes/storage:/var/lib/storage
#
# On Linux that is fine. On Docker Desktop for Windows those paths cross the
# Windows/Linux filesystem boundary, which cannot represent Unix ownership or
# mode bits. Postgres refuses to start on a data directory it cannot chmod 0700
# ("data directory has invalid permissions"), and the storage API - which runs
# unprivileged - cannot write to its volume either.
#
# The fix is to keep those two paths on Docker-managed named volumes, which live
# inside the Linux VM and behave exactly as they do on a Linux host. Compose
# merges service volume lists keyed on the container-side target, so naming the
# same target here replaces the bind mount rather than adding a second one.
#
# Every other bind mount (SQL init scripts, envoy config, edge functions) is
# read-only or root-owned, so those stay as they are - which is what lets
# `sentinel-ops` deploy edge functions by writing to a Windows directory.
# ---------------------------------------------------------------------------
function Write-WindowsComposeOverlay {
    $path = Join-Path $script:SUPABASE_DIR $script:WINDOWS_OVERLAY_NAME

    $content = @'
# Generated by sentinel-ops (Windows). Do not edit.
#
# Moves the two mounts that need real Unix ownership off the Windows filesystem
# and onto Docker-managed named volumes. Without this Postgres will not start
# and Storage cannot write. See lib/Supabase.ps1 for the full explanation.

services:
  db:
    volumes:
      - sentinelops-db-data:/var/lib/postgresql/data:Z

  storage:
    volumes:
      - sentinelops-storage-data:/var/lib/storage:z

  imgproxy:
    volumes:
      - sentinelops-storage-data:/var/lib/storage:z

volumes:
  sentinelops-db-data:
  sentinelops-storage-data:
'@

    Write-TextFile -Path $path -Content $content
    Write-LogOk "Windows compose overlay written to $path"
    return $true
}

# ---------------------------------------------------------------------------
# Fresh install of the Supabase deployment files
# ---------------------------------------------------------------------------

function Install-SupabaseFiles {
    if (Test-SupabaseInstalled) {
        Write-LogOk 'Supabase deployment files already present; preserving them.'
        # The overlay is ours, not upstream's, so make sure it is there even on
        # an installation that predates it.
        [void](Write-WindowsComposeOverlay)
        return $true
    }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('sentinelops-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $staged = Get-SupabaseUpstream -StagingDir $staging
        if (-not $staged) { return $false }
        Write-LogDebug "staged Supabase deployment at $staged"

        if (-not (Test-Path -LiteralPath $script:SUPABASE_DIR)) {
            New-Item -ItemType Directory -Force -Path $script:SUPABASE_DIR | Out-Null
        }
        Copy-TreeExcluding -Source $staged -Destination $script:SUPABASE_DIR

        # Seed .env from .env.example.
        $envFile = Join-Path $script:SUPABASE_DIR '.env'
        $example = Join-Path $script:SUPABASE_DIR '.env.example'
        if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
                Write-LogError 'Supabase shipped no .env.example; cannot seed the environment.'
                return $false
            }
            Copy-Item -LiteralPath $example -Destination $envFile -Force
            Write-LogInfo 'Seeded supabase/.env from .env.example'
        }
        [void](Set-RestrictedAcl -Path $envFile)

        $versionFile = Join-Path $staging '_version'
        $marker = Join-Path $script:SUPABASE_DIR '.supabase-version'
        if ((Test-Path -LiteralPath $versionFile -PathType Leaf) -and -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            Copy-Item -LiteralPath $versionFile -Destination $marker -Force
        }

        [void](Write-WindowsComposeOverlay)

        Write-LogOk "Supabase deployment files installed at $($script:SUPABASE_DIR)"
        return $true
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Secrets
#
# On Linux setup.sh generates these. This build always generates them itself,
# once, and never again: regenerating JWT secrets on an existing installation
# invalidates every issued token and locks users out.
# ---------------------------------------------------------------------------

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

# Sign an HS256 JWT. Replaces the Linux build's openssl dgst pipeline.
function New-SupabaseJwt {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][long]$IssuedAt,
        [Parameter(Mandatory)][long]$Expiry
    )
    $utf8 = [System.Text.Encoding]::UTF8
    $header  = ConvertTo-Base64Url -Bytes ($utf8.GetBytes('{"alg":"HS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url -Bytes ($utf8.GetBytes(
        ('{{"role":"{0}","iss":"supabase","iat":{1},"exp":{2}}}' -f $Role, $IssuedAt, $Expiry)))

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $utf8.GetBytes($Secret)
        $sig = ConvertTo-Base64Url -Bytes ($hmac.ComputeHash($utf8.GetBytes("$header.$payload")))
    } finally {
        $hmac.Dispose()
    }
    return "$header.$payload.$sig"
}

# Is this value still an upstream placeholder (or absent)?
#
# Matched against the actual values shipped in Supabase's .env.example rather
# than a generic "looks secret-ish" guess. Several of them - the storage
# encryption key, the dashboard password, the Phoenix secret key base - do not
# contain any obvious placeholder marker, so a substring heuristic silently
# leaves the upstream value in place on every install in the world.
function Test-IsPlaceholderSecret {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }

    $markers = @(
        'your-super-secret', 'your-tenant-id', 'replace-me', 'example',
        'super-secret-jwt', 'your-32-character', 'this_password_is_insecure',
        'changeme', 'change-me'
    )
    foreach ($m in $markers) {
        if ($Value.ToLowerInvariant().Contains($m)) { return $true }
    }

    # Values published verbatim in upstream's .env.example. They look like real
    # secrets, which is exactly why they have to be listed explicitly.
    $knownPublic = @(
        'UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq'
    )
    if ($knownPublic -contains $Value) { return $true }

    # The demo ANON_KEY / SERVICE_ROLE_KEY are JWTs issued by "supabase-demo".
    if ($Value -like 'eyJ*') {
        try {
            $parts = $Value.Split('.')
            if ($parts.Count -ge 2) {
                $p = $parts[1].Replace('-', '+').Replace('_', '/')
                switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
                $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
                if ($json -match 'supabase-demo') { return $true }
            }
        } catch {
            # An unparseable token is not evidence of a placeholder.
        }
    }
    return $false
}

function New-SupabaseSecrets {
    $envFile = Join-Path $script:SUPABASE_DIR '.env'
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Write-LogError "Missing $envFile"
        return $false
    }
    $changed = 0

    $jwtSecret = Get-EnvValue -Path $envFile -Key 'JWT_SECRET'
    if (Test-IsPlaceholderSecret $jwtSecret) {
        $jwtSecret = New-RandomToken 32
        Set-EnvValue -Path $envFile -Key 'JWT_SECRET' -Value $jwtSecret
        $changed++
        # The API keys are signed with the JWT secret, so they must be reissued
        # whenever the secret is created.
        $iat = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $exp = $iat + (60 * 60 * 24 * 365 * 10)
        Set-EnvValue -Path $envFile -Key 'ANON_KEY' `
            -Value (New-SupabaseJwt -Secret $jwtSecret -Role 'anon' -IssuedAt $iat -Expiry $exp)
        Set-EnvValue -Path $envFile -Key 'SERVICE_ROLE_KEY' `
            -Value (New-SupabaseJwt -Secret $jwtSecret -Role 'service_role' -IssuedAt $iat -Expiry $exp)
        Write-LogInfo 'Generated JWT secret and API keys'
    }

    $keys = @(
        'POSTGRES_PASSWORD', 'SECRET_KEY_BASE', 'VAULT_ENC_KEY',
        'LOGFLARE_PUBLIC_ACCESS_TOKEN', 'LOGFLARE_PRIVATE_ACCESS_TOKEN',
        'POOLER_TENANT_ID', 'DASHBOARD_PASSWORD',
        'S3_PROTOCOL_ACCESS_KEY_ID', 'S3_PROTOCOL_ACCESS_KEY_SECRET'
    )
    foreach ($key in $keys) {
        $val = Get-EnvValue -Path $envFile -Key $key
        # A key upstream does not ship at all is not ours to invent.
        if ($null -eq $val -and $key -like 'S3_PROTOCOL_*') { continue }
        if (Test-IsPlaceholderSecret $val) {
            switch ($key) {
                'VAULT_ENC_KEY'    { $newVal = New-RandomToken 16 }   # must be exactly 32 chars
                'POOLER_TENANT_ID' { $newVal = 'sentinel-ops' }
                'DASHBOARD_PASSWORD' { $newVal = New-RandomToken 12 }
                default            { $newVal = New-RandomToken 32 }
            }
            Set-EnvValue -Path $envFile -Key $key -Value $newVal
            $changed++
            Write-LogDebug "generated $key"
        }
    }

    if ([string]::IsNullOrEmpty((Get-EnvValue -Path $envFile -Key 'DASHBOARD_USERNAME'))) {
        Set-EnvValue -Path $envFile -Key 'DASHBOARD_USERNAME' -Value 'supabase'
    }

    [void](Set-RestrictedAcl -Path $envFile)
    if ($changed -gt 0) {
        Write-LogOk "Supabase secrets generated ($changed value(s))"
    } else {
        Write-LogOk 'Supabase secrets already present (left untouched)'
    }
    return $true
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Interactive prompts for the externally visible settings only. Secrets are
# never requested from the operator.
function Read-SupabasePromptConfig {
    Write-Section 'Supabase Configuration'

    $script:SUPABASE_PUBLIC_URL = Remove-TrailingSlash (Read-DefaultPrompt `
        -Question 'Supabase public URL' -Default $script:SUPABASE_PUBLIC_URL)

    $script:API_EXTERNAL_URL = Remove-TrailingSlash (Read-DefaultPrompt `
        -Question 'API external URL' -Default $script:SUPABASE_PUBLIC_URL)

    $script:SITE_URL = Remove-TrailingSlash (Read-DefaultPrompt `
        -Question 'Site URL (the Sentinel Ops application)' -Default $script:SITE_URL)
}

# Apply the operator's settings to supabase/.env. Only these keys are managed;
# everything else the operator wrote is left alone.
function Set-SupabaseConfig {
    $envFile = Join-Path $script:SUPABASE_DIR '.env'
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Write-LogError "Missing $envFile"
        return $false
    }

    Set-EnvValue -Path $envFile -Key 'SITE_URL'            -Value $script:SITE_URL
    Set-EnvValue -Path $envFile -Key 'API_EXTERNAL_URL'    -Value $script:API_EXTERNAL_URL
    Set-EnvValue -Path $envFile -Key 'SUPABASE_PUBLIC_URL' -Value $script:SUPABASE_PUBLIC_URL

    Set-EnvValue -Path $envFile -Key 'STUDIO_DEFAULT_ORGANIZATION' -Value 'Sentinel Ops'
    Set-EnvValue -Path $envFile -Key 'STUDIO_DEFAULT_PROJECT'      -Value 'Sentinel Ops'

    # Allow the application origin back through auth redirects.
    $extra = Get-EnvValue -Path $envFile -Key 'ADDITIONAL_REDIRECT_URLS'
    if ([string]::IsNullOrEmpty($extra)) {
        Set-EnvValue -Path $envFile -Key 'ADDITIONAL_REDIRECT_URLS' -Value "$($script:SITE_URL)/**"
    } elseif (-not $extra.Contains($script:SITE_URL)) {
        Set-EnvValue -Path $envFile -Key 'ADDITIONAL_REDIRECT_URLS' -Value "$extra,$($script:SITE_URL)/**"
    }

    [void](Set-RestrictedAcl -Path $envFile)
    Write-LogOk 'Supabase configuration applied'
    return $true
}

# The client-side key handed to the React frontend. Newer Supabase releases
# renamed ANON_KEY to a publishable key, so both spellings are accepted.
function Get-SupabasePublishableKey {
    $envFile = Join-Path $script:SUPABASE_DIR '.env'
    foreach ($k in @('ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY', 'PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY')) {
        $key = Get-EnvValue -Path $envFile -Key $k
        if (-not [string]::IsNullOrEmpty($key)) { return $key }
    }
    return $null
}

function Get-SupabaseServiceRoleKey {
    $envFile = Join-Path $script:SUPABASE_DIR '.env'
    foreach ($k in @('SERVICE_ROLE_KEY', 'SUPABASE_SECRET_KEY', 'SECRET_KEY')) {
        $key = Get-EnvValue -Path $envFile -Key $k
        if (-not [string]::IsNullOrEmpty($key)) { return $key }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

function Invoke-SupabasePull {
    Write-LogInfo 'Pulling Supabase images (this can take several minutes)...'
    if (-not (Invoke-SupabaseCompose -Description 'supabase pull' -Arguments @('pull'))) {
        Write-LogWarn 'Some images could not be pulled; continuing with what is cached.'
    }
    Write-LogOk 'Supabase images ready'
}

function Start-Supabase {
    Write-LogInfo 'Starting Supabase...'
    if (-not (Invoke-SupabaseCompose -Description 'supabase up' -Arguments @('up', '-d', '--remove-orphans'))) {
        return $false
    }
    Write-LogOk 'Supabase started'
    return $true
}

function Stop-Supabase {
    Write-LogInfo 'Stopping Supabase...'
    [void](Invoke-SupabaseCompose -Description 'supabase down' -Arguments @('down'))
}

# Restart without removing volumes. Never use `down -v` here: that destroys the
# database.
function Restart-Supabase {
    return (Invoke-SupabaseCompose -Description 'supabase restart' -Arguments @('up', '-d', '--remove-orphans'))
}

# The compose service name for Postgres differs between releases.
function Get-SupabaseDbService {
    $services = Invoke-SupabaseComposeCapture -Arguments @('config', '--services')
    if ($services) {
        $list = @($services -split "`n" | ForEach-Object { $_.Trim() })
        foreach ($s in @('db', 'database', 'postgres')) {
            if ($list -contains $s) { return $s }
        }
    }
    return 'db'
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

function Test-SupabasePostgres {
    $svc = Get-SupabaseDbService
    $cid = Get-SupabaseContainerId -Service $svc
    if (-not $cid) { return $false }
    $user = Get-EnvValue -Path (Join-Path $script:SUPABASE_DIR '.env') -Key 'POSTGRES_USER'
    if ([string]::IsNullOrEmpty($user)) { $user = 'postgres' }
    $null = Invoke-Capture -Command 'docker' -Arguments @('exec', $cid, 'pg_isready', '-U', $user, '-q')
    return ($LASTEXITCODE -eq 0)
}

# Headers for a gateway probe.
#
# Current Supabase releases front the stack with Envoy instead of Kong, and
# Envoy's RBAC filter rejects EVERY route without an apikey - including
# /auth/v1/health, which Kong used to serve unauthenticated. A probe that omits
# the key therefore gets a flat 401 from a perfectly healthy stack.
function Get-SupabaseProbeHeaders {
    $key = Get-SupabasePublishableKey
    if ($key) { return @{ apikey = $key } }
    return @{}
}

function Test-SupabaseApi {
    $port = Get-SupabaseKongPort
    # Any of these proves the gateway routed to PostgREST rather than failing to
    # reach it: 200 from an open deployment, 401/403 from the gateway's own
    # authorization filter, 404 when the bare root is not a route.
    $code = Get-HttpCode -Url "http://localhost:${port}/rest/v1/" -Headers (Get-SupabaseProbeHeaders)
    return ($code -in @('200', '401', '403', '404'))
}

function Test-SupabaseAuth {
    $port = Get-SupabaseKongPort
    $code = Get-HttpCode -Url "http://localhost:${port}/auth/v1/health" -Headers (Get-SupabaseProbeHeaders)
    if ($code -eq '200') { return $true }

    # The gateway is reachable but refused us. That says nothing about GoTrue,
    # so ask the container directly rather than reporting a false failure.
    $cid = Get-SupabaseContainerId -Service 'auth'
    if ($cid) {
        $null = Invoke-Capture -Command 'docker' -Arguments @('exec', $cid, 'wget', '-qO-', 'http://127.0.0.1:9999/health')
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Test-SupabaseStudio {
    # Studio is not always routed through the gateway, so fall back to the
    # container's own health status.
    $port = Get-SupabaseKongPort
    $code = Get-HttpCode -Url "http://localhost:${port}/" -Headers (Get-SupabaseProbeHeaders)
    if ($code -in @('200', '301', '302', '401', '403')) { return $true }
    $health = Get-SupabaseServiceHealth -Service 'studio'
    if ($health -in @('healthy', 'none')) { return (Test-SupabaseServiceRunning -Service 'studio') }
    return $false
}

# Wait for the whole stack, reporting each component as it comes up.
# Returns $false if any critical component fails.
function Test-SupabaseHealth {
    param([int]$TimeoutSeconds = 180)
    $ok = $true

    Write-LogInfo "Waiting for Supabase services (up to ${TimeoutSeconds}s)..."

    if (Wait-For -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 5 -Condition { Test-SupabasePostgres }) {
        Write-LogOk 'PostgreSQL available'
    } else {
        Write-LogError 'PostgreSQL failed health check'
        $ok = $false
    }

    if (Wait-For -TimeoutSeconds 60 -IntervalSeconds 5 -Condition { Test-SupabaseApi }) {
        Write-LogOk 'Supabase API available'
    } else {
        Write-LogError 'Supabase API failed health check'
        $ok = $false
    }

    if (Wait-For -TimeoutSeconds 60 -IntervalSeconds 5 -Condition { Test-SupabaseAuth }) {
        Write-LogOk 'Auth available'
    } else {
        Write-LogError 'Auth failed health check'
        $ok = $false
    }

    if (Wait-For -TimeoutSeconds 60 -IntervalSeconds 5 -Condition { Test-SupabaseStudio }) {
        Write-LogOk 'Studio available'
    } else {
        # Studio is an operator convenience, not a runtime dependency of the
        # application, so a failure here is a warning rather than fatal.
        Write-LogWarn 'Studio did not become available'
    }

    return $ok
}

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

# Refresh the deployment scaffolding from upstream while preserving .env,
# database volumes, storage and the application's edge functions.
function Update-SupabaseFiles {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('sentinelops-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $staged = Get-SupabaseUpstream -StagingDir $staging
        if (-not $staged) { return $false }

        # Belt and braces: keep a copy of .env outside the tree being rewritten.
        $envFile = Join-Path $script:SUPABASE_DIR '.env'
        $backupEnv = Join-Path $staging '.env.preserved'
        Copy-Item -LiteralPath $envFile -Destination $backupEnv -Force

        Write-LogInfo 'Refreshing Supabase deployment files (state preserved)...'
        Copy-TreeExcluding -Source $staged -Destination $script:SUPABASE_DIR -Exclude $script:SUPABASE_PRESERVE

        # The staged tree may ship its own .env; make sure ours wins.
        Copy-Item -LiteralPath $backupEnv -Destination $envFile -Force
        [void](Set-RestrictedAcl -Path $envFile)

        # Upstream may have added services that need the Windows treatment.
        [void](Write-WindowsComposeOverlay)

        $versionFile = Join-Path $staging '_version'
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            Copy-Item -LiteralPath $versionFile -Destination (Join-Path $script:SUPABASE_DIR '.supabase-version') -Force
        }

        Write-LogOk 'Supabase deployment files updated'
        return $true
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
