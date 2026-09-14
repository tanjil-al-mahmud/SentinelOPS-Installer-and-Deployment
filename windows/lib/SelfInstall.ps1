# lib/SelfInstall.ps1 - copy the installer into the installation root.
#
# Counterpart of lib/selfinstall.sh. After this runs, `sentinel-ops` is on PATH
# and every later update uses the copy under the installation directory rather
# than whatever checkout the operator happened to run first.
#
# Linux gets a symlink into /usr/local/bin. Windows has no equivalent directory
# that is on PATH by default, so instead a .cmd shim is written next to the
# installed script and its directory is added to PATH - to the machine PATH when
# running elevated, otherwise to the user's.

function Install-Self {
    $destBin    = Join-Path $script:INSTALL_DIR 'bin'
    $destLib    = Join-Path $script:INSTALL_DIR 'lib'
    $destAssets = Join-Path $script:INSTALL_DIR 'assets'

    # Already running from the installed location: nothing to copy.
    if ($script:SO_ROOT -eq $script:INSTALL_DIR) {
        Write-LogDebug "already running from $($script:INSTALL_DIR)"
    } else {
        foreach ($d in @($destBin, $destLib, $destAssets)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        }
        Copy-Item -Path (Join-Path $script:SO_BIN_SOURCE    '*') -Destination $destBin    -Recurse -Force
        Copy-Item -Path (Join-Path $script:SO_LIB_SOURCE    '*') -Destination $destLib    -Recurse -Force
        Copy-Item -Path (Join-Path $script:SO_ASSETS_SOURCE '*') -Destination $destAssets -Recurse -Force
        Write-LogOk "Installer copied to $($script:INSTALL_DIR)"
    }

    # From here on, templates come from the installed copy.
    $script:SO_ASSETS_DIR = $destAssets
    $script:SO_LIB_DIR    = $destLib

    Write-CommandShim -BinDir $destBin
    Add-ToPath -Directory $destBin
    return $true
}

# A .cmd shim so `sentinel-ops` works from cmd.exe and PowerShell alike, and a
# .ps1 passthrough is not needed because the real script already lives here.
function Write-CommandShim {
    param([Parameter(Mandatory)][string]$BinDir)

    $target = Join-Path $BinDir 'sentinel-ops.ps1'
    $shim   = Join-Path $BinDir 'sentinel-ops.cmd'

    # Prefer PowerShell 7 when it is present, but fall back to the Windows
    # PowerShell that every machine has.
    $content = @"
@echo off
setlocal
set "SO_SCRIPT=%~dp0sentinel-ops.ps1"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SO_SCRIPT%" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SO_SCRIPT%" %*
)
exit /b %ERRORLEVEL%
"@
    # A .cmd file is read by cmd.exe, which wants CRLF.
    Write-TextFile -Path $shim -Content $content -Crlf

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-LogOk 'Command available as: sentinel-ops'
    } else {
        Write-LogWarn "Expected $target to exist after the copy."
    }
}

function Add-ToPath {
    param([Parameter(Mandatory)][string]$Directory)

    $scope = 'User'
    if (Test-Administrator) { $scope = 'Machine' }

    try {
        $current = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not $current) { $current = '' }
        $entries = @($current -split ';' | Where-Object { $_ })
        if ($entries -contains $Directory) {
            Write-LogDebug "$Directory already on the $scope PATH"
        } else {
            $updated = (@($entries) + $Directory) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $updated, $scope)
            Write-LogOk "Added $Directory to the $scope PATH"
            Write-LogInfo 'Open a new terminal for the sentinel-ops command to be available.'
        }
        # Make it work in this session too.
        if (($env:Path -split ';') -notcontains $Directory) {
            $env:Path = "$($env:Path);$Directory"
        }
    } catch {
        Write-LogWarn "Could not update the $scope PATH: $_"
        Write-LogWarn "Run the installed copy directly: $(Join-Path $Directory 'sentinel-ops.cmd')"
    }
}
