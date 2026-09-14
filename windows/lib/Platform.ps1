# lib/Platform.ps1 - Windows host detection.
#
# Counterpart of lib/os.sh. The Linux version classifies a distribution to pick
# a package manager; the Windows version establishes the two things that
# actually gate this installer: a new enough Windows, and a working WSL2 or
# Hyper-V backend for Docker Desktop's Linux containers.

# Populated by Get-PlatformInfo:
$script:OS_NAME        = ''    # "Windows 11 Enterprise"
$script:OS_VERSION     = ''    # "10.0.26200"
$script:OS_BUILD       = 0     # 26200
$script:OS_IS_SERVER   = $false
$script:PKG_MANAGER    = ''    # winget | choco | ''

# Windows 10 1809 (17763) is the first build with a supported Docker Desktop and
# a usable in-box OpenSSH client and tar.exe.
$script:MIN_BUILD = 17763

function Assert-WindowsPlatform {
    $isWin = $true
    # $IsWindows exists only on PowerShell 6+; on 5.1 the host is Windows by
    # definition, so its absence is itself the answer.
    if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        $isWin = $Global:IsWindows
    }
    if (-not $isWin) {
        Write-LogError 'This is the Windows build of the Sentinel Ops installer.'
        Write-LogError 'On Linux, run ./install.sh instead.'
        throw 'SENTINELOPS_FATAL: not running on Windows'
    }
    Write-LogOk 'Windows detected'
}

function Get-PlatformInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $script:OS_NAME      = $os.Caption.Trim()
        $script:OS_VERSION   = $os.Version
        $script:OS_BUILD     = [int]($os.BuildNumber)
        # ProductType 1 is a workstation; 2 (domain controller) and 3 (server)
        # are both Windows Server.
        $script:OS_IS_SERVER = ($os.ProductType -ne 1)
    } catch {
        $script:OS_NAME    = 'Windows (version undetermined)'
        $script:OS_VERSION = [string][Environment]::OSVersion.Version
        $script:OS_BUILD   = [Environment]::OSVersion.Version.Build
        Write-LogDebug "Win32_OperatingSystem unavailable: $_"
    }

    if (Test-Command 'winget')     { $script:PKG_MANAGER = 'winget' }
    elseif (Test-Command 'choco')  { $script:PKG_MANAGER = 'choco' }
    else                           { $script:PKG_MANAGER = '' }
}

function Assert-SupportedPlatform {
    Get-PlatformInfo

    if ($script:OS_BUILD -gt 0 -and $script:OS_BUILD -lt $script:MIN_BUILD) {
        Write-LogError "Unsupported Windows build: $($script:OS_VERSION)"
        Write-Host ''
        Write-Host 'Sentinel Ops Installer requires:'
        Write-Host '  Windows 10 1809 / Windows 11, or'
        Write-Host '  Windows Server 2019 or later'
        Write-Host ''
        Write-Host 'Docker Desktop needs this too, so an older build cannot run the stack.'
        throw 'SENTINELOPS_FATAL: unsupported Windows version'
    }

    Write-LogOk "$($script:OS_NAME) detected (build $($script:OS_BUILD))"
    Write-LogDebug "server=$($script:OS_IS_SERVER) pkg=$($script:PKG_MANAGER) version=$($script:OS_VERSION)"

    if (-not $script:PKG_MANAGER) {
        Write-LogWarn 'Neither winget nor choco is available.'
        Write-LogWarn 'Anything missing will have to be installed by hand.'
    }
}

# ---------------------------------------------------------------------------
# WSL2
#
# Docker Desktop runs Linux containers, and on Windows that means a Linux VM.
# The whole Supabase stack is Linux-only, so a missing backend is fatal - but it
# is diagnosed here rather than surfacing as a confusing Docker error later.
# ---------------------------------------------------------------------------

function Test-Wsl2Available {
    if (-not (Test-Command 'wsl')) { return $false }
    # wsl.exe writes UTF-16LE, which arrives as text peppered with NULs; strip
    # them before matching or every pattern fails.
    $out = (Invoke-Capture -Command 'wsl.exe' -Arguments @('--status')) -replace "`0", ''
    if ($LASTEXITCODE -ne 0 -and -not $out) { return $false }
    return $true
}

function Get-WslDistros {
    if (-not (Test-Command 'wsl')) { return @() }
    $out = (Invoke-Capture -Command 'wsl.exe' -Arguments @('--list', '--quiet')) -replace "`0", ''
    if (-not $out) { return @() }
    return @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-VirtualizationEnabled {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.HypervisorPresent) { return $true }
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [bool]$cpu.VirtualizationFirmwareEnabled
    } catch {
        return $true   # undetectable is not the same as absent; let Docker decide
    }
}

function Assert-ContainerBackend {
    if (Test-Wsl2Available) {
        $distros = Get-WslDistros
        Write-LogOk "WSL2 available ($($distros.Count) distro(s) registered)"
        Write-LogDebug "wsl distros: $($distros -join ', ')"
        return
    }

    if (-not (Test-VirtualizationEnabled)) {
        Write-LogError 'Hardware virtualization appears to be disabled.'
        Write-LogError 'Enable Intel VT-x / AMD-V in the firmware, then retry.'
        throw 'SENTINELOPS_FATAL: virtualization disabled'
    }

    Write-LogWarn 'WSL2 was not detected.'
    Write-LogWarn 'Docker Desktop needs WSL2 (or Hyper-V) to run Linux containers.'
    Write-LogWarn 'Install it with:  wsl --install'
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------

function Install-Package {
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [string]$ChocoId = '',
        [string]$DisplayName = ''
    )
    if (-not $DisplayName) { $DisplayName = $WingetId }

    switch ($script:PKG_MANAGER) {
        'winget' {
            return Invoke-Logged -Description "winget install $DisplayName" -Command 'winget' -Arguments @(
                'install', '--id', $WingetId, '--exact',
                '--accept-source-agreements', '--accept-package-agreements',
                '--silent', '--disable-interactivity'
            )
        }
        'choco' {
            if (-not $ChocoId) { $ChocoId = $WingetId }
            return Invoke-Logged -Description "choco install $DisplayName" -Command 'choco' -Arguments @(
                'install', $ChocoId, '-y', '--no-progress'
            )
        }
        default {
            Write-LogError "No package manager available to install $DisplayName."
            return $false
        }
    }
}

# A freshly installed package is not on this process's PATH until the
# environment is re-read from the registry.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}
