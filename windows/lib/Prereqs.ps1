# lib/Prereqs.ps1 - base tooling, Docker Desktop and Docker Compose.
#
# Counterpart of lib/prereqs.sh. The Linux version installs curl, openssl and jq
# because a minimal server has none of them. On Windows those three are not
# needed at all: HTTP, crypto and JSON all come from .NET, which is always
# present. What is genuinely required here is Git, an SSH client, and Docker.

# Set by Find-ComposeCommand: the argument vector used to drive compose files.
$script:DOCKER_COMPOSE_CMD = @()

function Install-BasePrerequisites {
    # git    - cloning the application repository
    # ssh    - the deployment key; ships in-box as an optional feature since 1809
    $tools = @(
        @{ Name = 'git'; Winget = 'Git.Git';               Choco = 'git'          },
        @{ Name = 'ssh'; Winget = 'Microsoft.OpenSSH.Beta'; Choco = 'openssh'     }
    )

    $missing = @()
    foreach ($t in $tools) {
        if (Test-Command $t.Name) {
            Write-LogOk "$($t.Name) present"
        } else {
            $missing += $t
        }
    }
    if ($missing.Count -eq 0) { return $true }

    Write-LogInfo "Installing missing prerequisites: $(($missing | ForEach-Object { $_.Name }) -join ', ')"

    foreach ($t in $missing) {
        # The OpenSSH client is a Windows optional feature before it is a
        # package; enabling it is faster and more reliable than a download.
        if ($t.Name -eq 'ssh' -and (Install-OpenSshClientFeature)) {
            Update-SessionPath
            if (Test-Command 'ssh') { Write-LogOk 'ssh installed (Windows optional feature)'; continue }
        }
        if (-not (Install-Package -WingetId $t.Winget -ChocoId $t.Choco -DisplayName $t.Name)) {
            Write-LogError "Failed to install $($t.Name)."
            Write-LogError 'Install it manually and re-run the installer.'
            return $false
        }
    }

    Update-SessionPath

    # Re-verify: a package manager can report success while still not putting
    # the binary we need on PATH.
    $stillMissing = @()
    foreach ($t in $missing) {
        if (-not (Test-Command $t.Name)) { $stillMissing += $t.Name }
    }
    if ($stillMissing.Count -gt 0) {
        Write-LogError "Still missing after installation: $($stillMissing -join ', ')"
        Write-LogError 'A new terminal may be needed for PATH changes to take effect.'
        return $false
    }

    Write-LogOk 'Prerequisites installed'
    return $true
}

function Install-OpenSshClientFeature {
    if (-not (Test-Administrator)) { return $false }
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop
        if ($cap.State -eq 'Installed') { return $true }
        Write-LogInfo 'Enabling the Windows OpenSSH client...'
        Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-LogDebug "OpenSSH capability install failed: $_"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Docker
#
# Verified at three levels, because `docker --version` succeeding says nothing
# about whether the daemon is usable:
#   1. the client binary exists
#   2. the daemon answers (`docker info`)
#   3. compose v2 is available
# ---------------------------------------------------------------------------

# The binary must exist *and* actually run. A docker on PATH that cannot print
# its own version is not a usable client, and treating it as one produces an
# "installed ()" line with empty parentheses followed by a daemon failure that
# points nowhere near the real cause.
function Test-DockerBinary {
    if (-not (Test-Command 'docker')) { return $false }
    $v = Invoke-Capture -Command 'docker' -Arguments @('--version')
    return [bool]$v
}

function Test-DockerDaemon {
    $null = Invoke-Capture -Command 'docker' -Arguments @('info', '--format', '{{.ServerVersion}}')
    return ($LASTEXITCODE -eq 0)
}

function Find-ComposeCommand {
    $null = Invoke-Capture -Command 'docker' -Arguments @('compose', 'version')
    if ($LASTEXITCODE -eq 0) {
        $script:DOCKER_COMPOSE_CMD = @('docker', 'compose')
        return $true
    }
    if (Test-Command 'docker-compose') {
        $null = Invoke-Capture -Command 'docker-compose' -Arguments @('version')
        if ($LASTEXITCODE -eq 0) {
            # Legacy v1. Usable, but several Supabase compose files rely on v2
            # syntax, so warn loudly.
            $script:DOCKER_COMPOSE_CMD = @('docker-compose')
            Write-LogWarn 'Using legacy docker-compose v1. Docker Compose v2 is strongly recommended.'
            return $true
        }
    }
    $script:DOCKER_COMPOSE_CMD = @()
    return $false
}

function Get-DockerDesktopPath {
    # Docker Desktop installs per-machine or per-user depending on the installer
    # flags used, so both roots are checked.
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Install-Docker {
    Write-LogInfo 'Installing Docker Desktop...'
    Write-LogWarn 'Docker Desktop usually requires a reboot before it can be used.'

    if (-not (Install-Package -WingetId 'Docker.DockerDesktop' -ChocoId 'docker-desktop' -DisplayName 'Docker Desktop')) {
        Write-LogError 'Could not install Docker Desktop automatically.'
        Write-LogError 'Download it from https://www.docker.com/products/docker-desktop/ and re-run the installer.'
        return $false
    }
    Update-SessionPath
    return $true
}

function Start-DockerDesktop {
    $exe = Get-DockerDesktopPath
    if (-not $exe) {
        Write-LogWarn 'Docker Desktop executable not found; cannot start it automatically.'
        return $false
    }
    Write-LogInfo 'Starting Docker Desktop...'
    try {
        Start-Process -FilePath $exe -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-LogWarn "Could not start Docker Desktop: $_"
        return $false
    }
}

# Full Docker readiness gate, used by install and by every update path.
function Assert-Docker {
    if (-not (Test-DockerBinary)) {
        Write-LogInfo 'Docker is not installed.'
        if (-not (Confirm-Action -Question 'Install Docker Desktop now?' -Default 'y')) {
            Write-LogError 'Docker is required. Aborting.'
            return $false
        }
        if (-not (Install-Docker)) { return $false }
    }

    if (-not (Test-DockerBinary)) {
        Write-LogError "Docker installation completed but the 'docker' command is still unavailable."
        Write-LogError 'Open a new terminal (or reboot) and re-run the installer.'
        return $false
    }
    Write-LogOk "Docker installed ($(Invoke-Capture -Command 'docker' -Arguments @('--version')))"

    if (-not (Test-DockerDaemon)) {
        Write-LogInfo 'Docker daemon is not responding; attempting to start Docker Desktop...'
        [void](Start-DockerDesktop)
        # Docker Desktop boots a Linux VM, which is a great deal slower than
        # starting a systemd unit on Linux. Three minutes is not generous here.
        if (-not (Wait-For -TimeoutSeconds 180 -IntervalSeconds 5 -Condition { Test-DockerDaemon })) {
            Write-LogError 'Docker is installed but the daemon is not running.'
            Write-LogError 'Start Docker Desktop, wait for it to report "Engine running", then re-run the installer.'
            return $false
        }
    }
    Write-LogOk 'Docker daemon running'

    # Linux containers are not optional: every image in this stack is Linux-only.
    $osType = Invoke-Capture -Command 'docker' -Arguments @('info', '--format', '{{.OSType}}')
    if ($osType -and $osType -ne 'linux') {
        Write-LogError "Docker is in $osType-container mode; this stack is Linux-only."
        Write-LogError 'Right-click the Docker tray icon and choose "Switch to Linux containers".'
        return $false
    }
    Write-LogOk 'Docker is in Linux-container mode'

    if (-not (Find-ComposeCommand)) {
        Write-LogError 'Docker Compose is not available.'
        Write-LogError 'Docker Desktop bundles Compose v2; a missing one usually means a broken installation.'
        return $false
    }
    Write-LogOk "Docker Compose available ($($script:DOCKER_COMPOSE_CMD -join ' '))"

    # A real end-to-end check: the daemon must actually be able to run a
    # container, not merely answer the info endpoint.
    if (Invoke-Logged -Description 'Docker sanity check' -Command 'docker' -Arguments @('run', '--rm', 'hello-world')) {
        Write-LogOk 'Docker can run containers'
    } else {
        Write-LogWarn 'Could not run the hello-world test container.'
        Write-LogWarn 'This usually means no network access to the registry, or a broken WSL2 backend.'
        if (-not (Confirm-Action -Question 'Continue anyway?' -Default 'n')) { return $false }
    }

    return $true
}

# Convenience wrapper so callers never expand the compose argument vector
# themselves. Returns $true/$false like Invoke-Logged.
function Invoke-Compose {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )
    if ($script:DOCKER_COMPOSE_CMD.Count -eq 0) {
        if (-not (Find-ComposeCommand)) {
            Write-LogError 'Docker Compose unavailable.'
            return $false
        }
    }
    $cmd  = $script:DOCKER_COMPOSE_CMD[0]
    $pre  = @()
    if ($script:DOCKER_COMPOSE_CMD.Count -gt 1) { $pre = $script:DOCKER_COMPOSE_CMD[1..($script:DOCKER_COMPOSE_CMD.Count - 1)] }
    return (Invoke-Logged -Description $Description -Command $cmd -Arguments ($pre + $Arguments) -WorkingDirectory $WorkingDirectory)
}

# Run compose with its output going straight to the console, for streaming
# commands such as `logs -f` where capturing would defeat the point.
function Invoke-ComposePassthrough {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )
    if ($script:DOCKER_COMPOSE_CMD.Count -eq 0) {
        if (-not (Find-ComposeCommand)) {
            Write-LogError 'Docker Compose unavailable.'
            return
        }
    }
    $cmd = $script:DOCKER_COMPOSE_CMD[0]
    # Guard the slice: with legacy docker-compose v1 the array holds a single
    # element, and 1..0 would silently produce a reversed range.
    $pre = @()
    if ($script:DOCKER_COMPOSE_CMD.Count -gt 1) {
        $pre = $script:DOCKER_COMPOSE_CMD[1..($script:DOCKER_COMPOSE_CMD.Count - 1)]
    }
    $all = $pre + $Arguments
    $pushed = $false
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
    try { & $cmd @all } finally { if ($pushed) { Pop-Location } }
}

# Same as Invoke-Compose, but returns the command's output instead of a flag.
function Invoke-ComposeCapture {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )
    if ($script:DOCKER_COMPOSE_CMD.Count -eq 0) {
        if (-not (Find-ComposeCommand)) { return '' }
    }
    $cmd = $script:DOCKER_COMPOSE_CMD[0]
    $pre = @()
    if ($script:DOCKER_COMPOSE_CMD.Count -gt 1) { $pre = $script:DOCKER_COMPOSE_CMD[1..($script:DOCKER_COMPOSE_CMD.Count - 1)] }
    return (Invoke-Capture -Command $cmd -Arguments ($pre + $Arguments) -WorkingDirectory $WorkingDirectory)
}
