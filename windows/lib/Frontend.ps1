# lib/Frontend.ps1 - application environment, Docker image and container.
#
# Counterpart of lib/frontend.sh.

# docker | host
#   docker - multi-stage build; npm ci and npm run build run inside the image,
#            so the host needs no Node.js toolchain at all. Default.
#   host   - npm ci and npm run build run on the host, and the image only
#            packages the resulting dist/.
$script:FRONTEND_BUILD_MODE = 'docker'
if ($env:FRONTEND_BUILD_MODE) { $script:FRONTEND_BUILD_MODE = $env:FRONTEND_BUILD_MODE }

# ---------------------------------------------------------------------------
# Application environment
# ---------------------------------------------------------------------------

# Generate app/.env.local from the live Supabase configuration.
#
# Keys the installer owns are always refreshed (they are derived values, and a
# stale Supabase URL is a broken deployment). Any other key an operator added
# is preserved.
#
# .env.local rather than .env: the application repository *tracks* .env, so
# writing there leaves the checkout permanently dirty and the next
# `git merge --ff-only` in `update app` aborts with "the local checkout has
# diverged". Vite reads .env.local with higher precedence than .env, and the
# repository's .gitignore already covers *.local, so this overrides the
# committed values without touching version control.
function New-AppEnvironment {
    $envFile = Join-Path $script:APP_DIR '.env.local'

    $pubKey = Get-SupabasePublishableKey
    if (-not $pubKey) {
        Write-LogError "Could not read the Supabase publishable (anon) key from $(Join-Path $script:SUPABASE_DIR '.env')"
        return $false
    }
    $projectId = 'local'

    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Write-TextFile -Path $envFile -Content ''
    }

    # NOTE: the service-role key is deliberately absent. Anything in a Vite
    # build is shipped to the browser, so a service-role key here would hand
    # every visitor full database access.
    Set-EnvValue -Path $envFile -Key 'PORT'                          -Value $script:APP_PORT
    Set-EnvValue -Path $envFile -Key 'NODE_ENV'                      -Value 'production'
    Set-EnvValue -Path $envFile -Key 'SUPABASE_PROJECT_ID'           -Value "`"$projectId`""
    Set-EnvValue -Path $envFile -Key 'SUPABASE_PUBLISHABLE_KEY'      -Value "`"$pubKey`""
    Set-EnvValue -Path $envFile -Key 'SUPABASE_URL'                  -Value "`"$($script:SUPABASE_PUBLIC_URL)`""
    Set-EnvValue -Path $envFile -Key 'VITE_SUPABASE_PROJECT_ID'      -Value "`"$projectId`""
    Set-EnvValue -Path $envFile -Key 'VITE_SUPABASE_PUBLISHABLE_KEY' -Value "`"$pubKey`""
    Set-EnvValue -Path $envFile -Key 'VITE_SUPABASE_URL'             -Value "`"$($script:SUPABASE_PUBLIC_URL)`""

    [void](Set-RestrictedAcl -Path $envFile)
    Write-LogOk "Application environment written to $envFile"

    # An earlier installer version wrote the tracked .env directly. Say so once,
    # rather than letting `update app` fail later with a confusing merge error.
    if (Test-RepoCloned) {
        $dirty = Invoke-AppGit -Arguments @('status', '--porcelain', '--', '.env')
        if ($dirty) {
            Write-LogWarn 'The checkout has local modifications to the tracked .env file.'
            Write-LogWarn "This installer no longer writes it. Discard them with:"
            Write-LogWarn "  git -C $($script:APP_DIR) checkout -- .env"
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Build assets
# ---------------------------------------------------------------------------

# The Dockerfile belongs in the application repository. Until it is committed
# there, the installer supplies one so deployment is not blocked.
function Initialize-FrontendBuildFiles {
    $src = Join-Path $script:SO_ASSETS_DIR 'app'

    if (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'Dockerfile') -PathType Leaf) {
        Write-LogOk 'Using the Dockerfile from the application repository'
    } else {
        $from = Join-Path $src 'Dockerfile'
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) {
            Write-LogError "Missing Dockerfile template: $from"
            return $false
        }
        Copy-Item -LiteralPath $from -Destination (Join-Path $script:APP_DIR 'Dockerfile') -Force
        Write-LogInfo "Repository has no Dockerfile; using the installer's production template."
    }

    $dockerignore = Join-Path $script:APP_DIR '.dockerignore'
    if (-not (Test-Path -LiteralPath $dockerignore -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $src 'dockerignore') -Destination $dockerignore -Force
    }
    return $true
}

function Get-FrontendImageTag    { return "$($script:APP_IMAGE_NAME):$(Get-RepoShortCommit)" }
function Get-FrontendImageLatest { return "$($script:APP_IMAGE_NAME):latest" }

# Build on the host, for FRONTEND_BUILD_MODE=host.
function Invoke-FrontendHostBuild {
    if (-not (Test-Command 'npm')) {
        Write-LogError 'FRONTEND_BUILD_MODE=host requires Node.js and npm on this machine.'
        Write-LogError 'Install Node.js, or switch to the default docker build mode.'
        return $false
    }
    Write-LogInfo 'Installing npm dependencies...'
    # npm on Windows is npm.cmd; calling it through cmd keeps argument handling
    # consistent whichever shim is on PATH.
    if (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'package-lock.json') -PathType Leaf) {
        if (-not (Invoke-Logged -Description 'npm ci' -Command 'cmd.exe' `
                -Arguments @('/c', 'npm', 'ci') -WorkingDirectory $script:APP_DIR)) { return $false }
    } else {
        Write-LogWarn "No package-lock.json; falling back to 'npm install'."
        if (-not (Invoke-Logged -Description 'npm install' -Command 'cmd.exe' `
                -Arguments @('/c', 'npm', 'install') -WorkingDirectory $script:APP_DIR)) { return $false }
    }
    Write-LogInfo 'Building the frontend...'
    if (-not (Invoke-Logged -Description 'npm run build' -Command 'cmd.exe' `
            -Arguments @('/c', 'npm', 'run', 'build') -WorkingDirectory $script:APP_DIR)) { return $false }

    if (-not (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'dist'))) {
        Write-LogError "Build finished but $(Join-Path $script:APP_DIR 'dist') does not exist."
        return $false
    }
    Write-LogOk 'Frontend built'
    return $true
}

# Build the production image, tagged with the Git SHA so a previous image is
# always available to roll back to.
function New-FrontendImage {
    $tag    = Get-FrontendImageTag
    $latest = Get-FrontendImageLatest

    if (-not (Initialize-FrontendBuildFiles)) { return $false }

    if ($script:FRONTEND_BUILD_MODE -eq 'host') {
        if (-not (Invoke-FrontendHostBuild)) { return $false }
    }

    $pubKey = Get-SupabasePublishableKey
    if (-not $pubKey) { return $false }

    Write-LogInfo "Building Docker image $tag..."
    # Vite inlines VITE_* variables at build time, so they must be present in
    # the build stage - passing them at container runtime would be too late.
    $buildArgs = @(
        'build',
        '--build-arg', "BUILD_MODE=$($script:FRONTEND_BUILD_MODE)",
        '--build-arg', "VITE_SUPABASE_URL=$($script:SUPABASE_PUBLIC_URL)",
        '--build-arg', "VITE_SUPABASE_PUBLISHABLE_KEY=$pubKey",
        '--build-arg', 'VITE_SUPABASE_PROJECT_ID=local',
        '--build-arg', "APP_PORT=$($script:APP_PORT)",
        '-t', $tag, '-t', $latest,
        '-f', (Join-Path $script:APP_DIR 'Dockerfile'),
        $script:APP_DIR
    )
    if (-not (Invoke-Logged -Description 'docker build' -Command 'docker' -Arguments $buildArgs)) {
        return $false
    }
    Write-LogOk "Image built: $tag"
    return $true
}

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

function Test-ContainerExists {
    param([Parameter(Mandatory)][string]$Name)
    $null = Invoke-Capture -Command 'docker' -Arguments @('container', 'inspect', $Name)
    return ($LASTEXITCODE -eq 0)
}

function Test-ContainerRunning {
    param([Parameter(Mandatory)][string]$Name)
    $state = Invoke-Capture -Command 'docker' -Arguments @('inspect', '-f', '{{.State.Running}}', $Name)
    return ($state -eq 'true')
}

function Remove-ContainerQuietly {
    param([Parameter(Mandatory)][string]$Name)
    $null = Invoke-Capture -Command 'docker' -Arguments @('rm', '-f', $Name)
}

# Where the published port is bound. Defaults to loopback so the container is
# reachable by a reverse proxy on this host but not from the network.
function Get-FrontendBindAddress {
    if ($script:APP_BIND) { return $script:APP_BIND }
    return '127.0.0.1'
}

# Start a container from an image.
function Start-FrontendContainer {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$HostPort
    )
    $network = Get-SupabaseNetworkName
    $bind    = Get-FrontendBindAddress

    Remove-ContainerQuietly -Name $Name

    # Runtime environment is passed explicitly rather than with --env-file:
    # Docker does not strip quotes from an env file, so the quoted values in
    # app/.env (written in the format the application's own tooling expects)
    # would arrive with literal " characters around them.
    #
    # The client-side Supabase settings are not needed here in any case - Vite
    # inlined them into the bundle at build time.
    $runArgs = @(
        'run', '-d',
        '--name', $Name,
        '--restart', 'unless-stopped',
        '-e', 'NODE_ENV=production',
        '-e', "APP_PORT=$($script:APP_PORT)",
        # Nitro's node-server listens on PORT/HOST. HOST must be 0.0.0.0 or the
        # server binds to loopback *inside* the container and the published
        # port reaches nothing.
        '-e', "PORT=$($script:APP_PORT)",
        '-e', 'HOST=0.0.0.0',
        '-p', "${bind}:${HostPort}:$($script:APP_PORT)"
    )
    # Attaching to the Supabase network lets a dockerised reverse proxy route to
    # this container by name instead of going back out through the host.
    $null = Invoke-Capture -Command 'docker' -Arguments @('network', 'inspect', $network)
    if ($LASTEXITCODE -eq 0) {
        $runArgs += @('--network', $network)
    } else {
        Write-LogWarn "Supabase network '$network' not found; starting on the default bridge."
    }
    $runArgs += $Image

    return (Invoke-Logged -Description "start $Name" -Command 'docker' -Arguments $runArgs)
}

function Test-FrontendHttp {
    param([string]$Port = '')
    if (-not $Port) { $Port = $script:APP_PORT }
    $code = Get-HttpCode -Url "http://127.0.0.1:${Port}/"
    return ($code -in @('200', '301', '302'))
}

function Test-FrontendHealth {
    param([string]$Port = '')
    if (-not $Port) { $Port = $script:APP_PORT }
    Write-LogInfo "Checking the frontend on port $Port..."
    if (Wait-For -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { Test-FrontendHttp -Port $Port }) {
        Write-LogOk 'Frontend responding'
        return $true
    }
    Write-LogError "Frontend did not answer on port $Port"
    Write-ContainerLogTail -Name $script:APP_CONTAINER_NAME -Lines 40
    return $false
}

function Write-ContainerLogTail {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Lines = 40
    )
    $logs = Invoke-Capture -Command 'docker' -Arguments @('logs', '--tail', [string]$Lines, $Name)
    if ($logs) { foreach ($l in ($logs -split "`n")) { Write-Host $l } }
}

# Deploy the new image without destroying the running one first.
#
#   verify the new image on a staging container
#        -> only then replace the live container
#        -> if the replacement is unhealthy, restore the previous image
function Invoke-FrontendDeploy {
    $image         = Get-FrontendImageTag
    $stagingName   = "$($script:APP_CONTAINER_NAME)-staging"
    $stagingPort   = [string](Get-FreePort)
    $previousImage = Get-State -Key 'APP_IMAGE' -Fallback ''

    # 1. Prove the new image actually serves traffic.
    Write-LogInfo 'Verifying the new image on a staging container...'
    if (-not (Start-FrontendContainer -Name $stagingName -Image $image -HostPort $stagingPort)) {
        Remove-ContainerQuietly -Name $stagingName
        return $false
    }
    if (-not (Wait-For -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { Test-FrontendHttp -Port $stagingPort })) {
        Write-LogError 'The new image failed its health check; the running deployment was left untouched.'
        Write-ContainerLogTail -Name $stagingName -Lines 40
        Remove-ContainerQuietly -Name $stagingName
        return $false
    }
    Write-LogOk 'New image verified'
    Remove-ContainerQuietly -Name $stagingName

    # 2. Swap the live container over.
    if (Test-ContainerExists -Name $script:APP_CONTAINER_NAME) {
        Write-LogInfo 'Replacing the running container...'
        Remove-ContainerQuietly -Name $script:APP_CONTAINER_NAME
    }

    if ((Start-FrontendContainer -Name $script:APP_CONTAINER_NAME -Image $image -HostPort $script:APP_PORT) -and
        (Wait-For -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { Test-FrontendHttp -Port $script:APP_PORT })) {
        Write-LogOk "Sentinel Ops frontend deployed ($image)"
        Set-State -Key 'APP_IMAGE' -Value $image
        if ($previousImage -and $previousImage -ne $image) {
            Set-State -Key 'PREVIOUS_APP_IMAGE' -Value $previousImage
        }
        return $true
    }

    # 3. Roll back to the previous image if we have one.
    Write-LogError 'The replacement container is unhealthy.'
    if ($previousImage) {
        $null = Invoke-Capture -Command 'docker' -Arguments @('image', 'inspect', $previousImage)
        if ($LASTEXITCODE -eq 0) {
            Write-LogWarn "Rolling back to $previousImage..."
            if ((Start-FrontendContainer -Name $script:APP_CONTAINER_NAME -Image $previousImage -HostPort $script:APP_PORT) -and
                (Wait-For -TimeoutSeconds 60 -IntervalSeconds 3 -Condition { Test-FrontendHttp -Port $script:APP_PORT })) {
                Write-LogOk "Rolled back to $previousImage"
            } else {
                Write-LogError 'Rollback also failed. The frontend is down.'
            }
            return $false
        }
    }
    Write-LogError 'No previous image recorded; cannot roll back automatically.'
    return $false
}

function Get-FrontendDeployedImage { return (Get-State -Key 'APP_IMAGE' -Fallback '') }
