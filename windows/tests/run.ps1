<#
    Run every check that does not need a live Docker host.

        pwsh -File .\windows\tests\run.ps1

    Covers: PowerShell syntax, the unit tests for the helpers the deployment
    logic depends on, and the placeholder-detection table that decides which
    upstream secrets get regenerated.

    Deliberately dependency-free (no Pester): the point is that this runs on a
    stock Windows host with nothing installed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # -> windows/
$repo = Split-Path -Parent $root

Push-Location $repo
$script:failed = 0

function Write-Hr { param([string]$Text) Write-Host ''; Write-Host "== $Text ==" }

# ---------------------------------------------------------------------------
Write-Hr 'PowerShell syntax'
$psFiles = @(Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Sort-Object FullName)
foreach ($f in $psFiles) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    $rel = $f.FullName.Substring($repo.Length + 1)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "FAIL  $rel"
        $errors | Select-Object -First 3 | ForEach-Object { Write-Host "        line $($_.Extent.StartLineNumber): $($_.Message)" }
        $script:failed = 1
    } else {
        Write-Host "ok    $rel"
    }
}

# ---------------------------------------------------------------------------
Write-Hr 'Shim line endings'
# The .cmd shim is read by cmd.exe, which needs CRLF. Everything the installer
# writes for a container needs LF. Both are produced by Write-TextFile, so this
# checks the helper rather than files on disk.
. (Join-Path $root 'lib\Common.ps1')
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('so-eol-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Write-TextFile -Path "$tmp\lf.txt"   -Content "a`r`nb`n"
Write-TextFile -Path "$tmp\crlf.txt" -Content "a`nb`n" -Crlf
$lfBytes   = [System.IO.File]::ReadAllBytes("$tmp\lf.txt")
$crlfBytes = [System.IO.File]::ReadAllBytes("$tmp\crlf.txt")
if ($lfBytes -contains 13) { Write-Host 'FAIL  Write-TextFile leaked a CR'; $script:failed = 1 }
else { Write-Host 'ok    Write-TextFile normalises to LF' }
if ($crlfBytes -contains 13) { Write-Host 'ok    Write-TextFile -Crlf emits CRLF' }
else { Write-Host 'FAIL  Write-TextFile -Crlf did not emit CRLF'; $script:failed = 1 }
if ($lfBytes[0] -eq 0xEF) { Write-Host 'FAIL  Write-TextFile emitted a BOM'; $script:failed = 1 }
else { Write-Host 'ok    Write-TextFile emits no BOM' }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Hr 'Unit tests'
foreach ($t in (Get-ChildItem -Path (Join-Path $root 'tests') -Filter 'Test-*.ps1' | Sort-Object Name)) {
    Write-Host ''
    Write-Host "-- $($t.Name)"
    & $t.FullName -Root $root
    if ($LASTEXITCODE -ne 0) { $script:failed = 1 }
}

# ---------------------------------------------------------------------------
Write-Hr 'Result'
Pop-Location
if ($script:failed) {
    Write-Host 'FAILED'
    exit 1
}
Write-Host 'All checks passed'
exit 0
