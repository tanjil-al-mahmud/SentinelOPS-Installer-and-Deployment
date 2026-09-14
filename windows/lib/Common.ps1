# lib/Common.ps1 - logging, error handling and shared helpers.
#
# Windows counterpart of lib/common.sh. Targets Windows PowerShell 5.1 as well
# as PowerShell 7, because 5.1 is what ships with Windows Server and a fresh
# host may have nothing else installed.

$script:SO_INSTALLER_VERSION = '1.0.0'

# ---------------------------------------------------------------------------
# Colours (disabled when NO_COLOR is set or the console cannot render ANSI)
# ---------------------------------------------------------------------------
function Test-AnsiSupported {
    if ($env:NO_COLOR) { return $false }
    if ($env:WT_SESSION -or $env:TERM_PROGRAM) { return $true }
    if ($PSVersionTable.PSVersion.Major -ge 7) { return $true }
    # Windows 10 1511+ consoles understand ANSI escapes.
    return ([Environment]::OSVersion.Version -ge [Version]'10.0.10586')
}

if (Test-AnsiSupported) {
    $esc = [char]27
    $script:C_RESET = "$esc[0m"; $script:C_BOLD = "$esc[1m"; $script:C_DIM = "$esc[2m"
    $script:C_RED = "$esc[31m"; $script:C_GREEN = "$esc[32m"; $script:C_YELLOW = "$esc[33m"
    $script:C_BLUE = "$esc[34m"; $script:C_CYAN = "$esc[36m"
} else {
    $script:C_RESET = ''; $script:C_BOLD = ''; $script:C_DIM = ''
    $script:C_RED = ''; $script:C_GREEN = ''; $script:C_YELLOW = ''
    $script:C_BLUE = ''; $script:C_CYAN = ''
}

# Symbols. The legacy console host cannot reliably render these, so it gets ASCII.
if ($PSVersionTable.PSVersion.Major -ge 7 -or $env:WT_SESSION) {
    $script:SYM_OK = [char]0x2713; $script:SYM_FAIL = [char]0x2717; $script:SYM_ARROW = [char]0x2192
} else {
    $script:SYM_OK = '[ok]'; $script:SYM_FAIL = '[x]'; $script:SYM_ARROW = '->'
}

$script:SO_LOG_FILE      = ''
$script:SO_ASSUME_YES    = $false
$script:SO_DEBUG         = $false
$script:SO_FORCE_PHASES  = $false
$script:SO_CURRENT_PHASE = ''

# ---------------------------------------------------------------------------
# File writing
#
# Almost everything this installer writes is consumed by a Linux container: env
# files, compose files, entrypoints. Windows PowerShell's Set-Content would give
# them a UTF-8 BOM and CRLF endings, and both break in a container - a BOM on
# the first line of an env file becomes part of the first variable's name.
# ---------------------------------------------------------------------------
function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$Crlf
    )
    $text = $Content -replace "`r`n", "`n"
    if ($Crlf) { $text = $text -replace "`n", "`r`n" }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-LogFileLine {
    param([AllowEmptyString()][string]$Text)
    if (-not $script:SO_LOG_FILE) { return }
    try {
        $dir = Split-Path -Parent $script:SO_LOG_FILE
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        Add-Content -LiteralPath $script:SO_LOG_FILE -Value "$stamp $Text" -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never take the installer down.
    }
}

function Write-LogInfo  { param([AllowEmptyString()][string]$Message) Write-Host ("{0}[INFO]{1}  {2}" -f $script:C_BLUE,   $script:C_RESET, $Message); Write-LogFileLine "[INFO]  $Message" }
function Write-LogOk    { param([AllowEmptyString()][string]$Message) Write-Host ("{0}[OK]{1}    {2}" -f $script:C_GREEN,  $script:C_RESET, $Message); Write-LogFileLine "[OK]    $Message" }
function Write-LogWarn  { param([AllowEmptyString()][string]$Message) Write-Host ("{0}[WARN]{1}  {2}" -f $script:C_YELLOW, $script:C_RESET, $Message); Write-LogFileLine "[WARN]  $Message" }
function Write-LogError { param([AllowEmptyString()][string]$Message) Write-Host ("{0}[ERROR]{1} {2}" -f $script:C_RED,    $script:C_RESET, $Message); Write-LogFileLine "[ERROR] $Message" }

function Write-LogDebug {
    param([AllowEmptyString()][string]$Message)
    Write-LogFileLine "[DEBUG] $Message"
    if ($script:SO_DEBUG) { Write-Host ("{0}[DEBUG] {1}{2}" -f $script:C_DIM, $Message, $script:C_RESET) }
}

# A named failure boundary, so a failure can report which phase died rather than
# only a line number.
function Start-Phase {
    param([Parameter(Mandatory)][string]$Name)
    $script:SO_CURRENT_PHASE = $Name
    Write-Host ''
    Write-Host ("{0}{1} {2}{3}" -f "$($script:C_BOLD)$($script:C_CYAN)", $script:SYM_ARROW, $Name, $script:C_RESET)
    Write-LogFileLine "=== PHASE BEGIN: $Name ==="
}

function Complete-Phase {
    Write-LogFileLine "=== PHASE OK: $($script:SO_CURRENT_PHASE) ==="
    $script:SO_CURRENT_PHASE = ''
}

# Ends the run. Throws a tagged exception the entry point catches, rather than
# calling exit: `exit` inside a dot-sourced function would close the operator's
# interactive shell.
function Invoke-Die {
    param([Parameter(Mandatory)][string]$Message)
    Write-LogError $Message
    if ($script:SO_CURRENT_PHASE) {
        Write-LogError "Failed during phase: $($script:SO_CURRENT_PHASE)"
    }
    if ($script:SO_LOG_FILE) {
        Write-Host ''
        Write-Host ("{0}Full log: {1}{2}" -f $script:C_DIM, $script:SO_LOG_FILE, $script:C_RESET)
    }
    throw "SENTINELOPS_FATAL: $Message"
}

function Write-Banner {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ("{0}========================================{1}" -f $script:C_BOLD, $script:C_RESET)
    Write-Host ("{0}        {1}{2}" -f $script:C_BOLD, $Text, $script:C_RESET)
    Write-Host ("{0}========================================{1}" -f $script:C_BOLD, $script:C_RESET)
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ("{0}{1}{2}" -f $script:C_BOLD, $Text, $script:C_RESET)
    Write-Host ('-' * $Text.Length)
}

# Status line used by `sentinel-ops status`, e.g. "PostgreSQL   OK Healthy".
function Write-StatusLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$State = '',
        [AllowEmptyString()][string]$Text = ''
    )
    $colour = ''
    switch ($State) {
        'ok'   { $colour = $script:C_GREEN;  $Text = "$($script:SYM_OK) $Text" }
        'bad'  { $colour = $script:C_RED;    $Text = "$($script:SYM_FAIL) $Text" }
        'warn' { $colour = $script:C_YELLOW; $Text = "! $Text" }
    }
    Write-Host ("{0,-18} {1}{2}{3}" -f $Label, $colour, $Text, $script:C_RESET)
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Run a native command, capturing output into the log file. On failure the tail
# of the output is shown so the operator sees the real error, not just an exit
# code. Returns $true/$false, mirroring run_logged's exit status.
function Invoke-Logged {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    Write-LogDebug ("exec: {0} {1}" -f $Command, ($Arguments -join ' '))

    $restore = @{}
    foreach ($k in $Environment.Keys) {
        $restore[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Environment[$k])
    }
    $pushed = $false
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }

    $output = ''
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        # 2>&1 folds the native command's stderr into the pipeline; casting each
        # record to string stops ErrorRecord objects printing as noise.
        $lines = & $Command @Arguments 2>&1 | ForEach-Object { [string]$_ }
        $code = $global:LASTEXITCODE
        $output = ($lines -join "`n")
    } catch {
        $code = 1
        $output = $_.Exception.Message
    } finally {
        if ($pushed) { Pop-Location }
        foreach ($k in $restore.Keys) { [Environment]::SetEnvironmentVariable($k, $restore[$k]) }
    }

    if ($output) { Write-LogFileLine $output }

    if ($code -ne 0) {
        Write-LogError "$Description failed (exit $code)"
        if ($output) {
            $tail = @($output -split "`n")
            if ($tail.Count -gt 30) { $tail = $tail[($tail.Count - 30)..($tail.Count - 1)] }
            foreach ($line in $tail) { Write-Host $line }
        }
        return $false
    }
    return $true
}

# Run a native command and return its combined output, ignoring exit status.
# For probes where the output is the answer.
function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ''
    )
    $pushed = $false
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
    try {
        $lines = & $Command @Arguments 2>&1 | ForEach-Object { [string]$_ }
        return (($lines -join "`n").Trim())
    } catch {
        return ''
    } finally {
        if ($pushed) { Pop-Location }
    }
}

# Retry a command with a fixed delay.
function Invoke-Retry {
    param(
        [Parameter(Mandatory)][int]$Attempts,
        [Parameter(Mandatory)][int]$DelaySeconds,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    for ($n = 1; ; $n++) {
        if (& $Action) { return $true }
        if ($n -ge $Attempts) { return $false }
        Write-LogDebug "attempt $n/$Attempts failed, retrying in ${DelaySeconds}s"
        Start-Sleep -Seconds $DelaySeconds
    }
}

# Poll until a predicate returns true, or the timeout expires.
function Wait-For {
    param(
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$IntervalSeconds,
        [Parameter(Mandatory)][scriptblock]$Condition
    )
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds $IntervalSeconds
        $waited += $IntervalSeconds
    }
    return $false
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function Test-Interactive {
    # A redirected stdin (CI, a pipe) means no one is there to answer; reading
    # in that state would hang or throw.
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    return $true
}

# Under -Yes, or with no interactive console, the default is taken silently,
# which keeps the whole installer usable from CI.
function Read-DefaultPrompt {
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Default
    )
    if ($script:SO_ASSUME_YES -or -not (Test-Interactive)) {
        Write-Host ("{0}`n  [{1}] (auto)" -f $Question, $Default)
        return $Default
    }
    Write-Host ("{0}`n  [{1}]: " -f $Question, $Default) -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Question,
        [ValidateSet('y', 'n')][string]$Default = 'y'
    )
    if ($script:SO_ASSUME_YES -or -not (Test-Interactive)) {
        return ($Default -eq 'y')
    }
    $hint = 'y/N'
    if ($Default -eq 'y') { $hint = 'Y/n' }
    Write-Host ("{0} [{1}]: " -f $Question, $hint) -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return ($answer.Trim() -match '^[Yy]')
}

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Administrator {
    param([string]$Operation = '')
    if (Test-Administrator) { return }
    Write-LogError 'This operation must run as Administrator.'
    Write-LogError "Start PowerShell with 'Run as administrator', then retry:"
    Write-LogError "  sentinel-ops $Operation"
    throw 'SENTINELOPS_FATAL: administrator privileges required'
}

# ---------------------------------------------------------------------------
# Env-style files
#
# Read and written key by key, never by evaluating the file, so a generated
# password containing shell or PowerShell metacharacters can never execute.
# ---------------------------------------------------------------------------

function Get-EnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $pattern = '^\s*' + [regex]::Escape($Key) + '='
    $line = $null
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -match $pattern) { $line = $l }   # last wins, as in the shell version
    }
    if ($null -eq $line) { return $null }

    $value = $line.Substring($line.IndexOf('=') + 1)
    $value = $value.TrimEnd("`r")
    # Strip one layer of surrounding quotes if present.
    if ($value.Length -ge 2) {
        $first = $value[0]; $last = $value[$value.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    return $value
}

# Write (or replace) KEY=VALUE, preserving every other line. This is how the
# installer edits Supabase's .env without rewriting it.
function Set-EnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @([System.IO.File]::ReadAllLines($Path))
    }
    $pattern = '^\s*' + [regex]::Escape($Key) + '='
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($l in $lines) {
        if ($l -match $pattern) {
            if (-not $done) { $out.Add("$Key=$Value"); $done = $true }
            continue
        }
        $out.Add($l.TrimEnd("`r"))
    }
    if (-not $done) { $out.Add("$Key=$Value") }
    Write-TextFile -Path $Path -Content (($out -join "`n") + "`n")
}

# ---------------------------------------------------------------------------
# Secrets and misc helpers
# ---------------------------------------------------------------------------

# Mask a secret for display: keep the first and last four characters.
function Format-MaskedSecret {
    param([AllowEmptyString()][string]$Secret)
    if (-not $Secret -or $Secret.Length -le 12) { return '********' }
    return ('{0}...{1}' -f $Secret.Substring(0, 4), $Secret.Substring($Secret.Length - 4))
}

# Hex token of <Bytes> random bytes. There is no openssl on Windows, so this
# goes straight to the platform CSPRNG.
function New-RandomToken {
    param([int]$Bytes = 32)
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    return (-join ($buf | ForEach-Object { $_.ToString('x2') }))
}

function New-RandomBase64 {
    param([int]$Bytes = 32)
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($buf)
}

function Get-Timestamp { return (Get-Date).ToString('yyyy-MM-dd-HHmmss') }
function Get-IsoTimestamp { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

function Remove-TrailingSlash {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    return $Text.TrimEnd('/')
}

# Extract the hostname from a URL (no scheme, no path, no port).
function Get-UrlHost {
    param([Parameter(Mandatory)][string]$Url)
    $u = $Url
    $i = $u.IndexOf('://')
    if ($i -ge 0) { $u = $u.Substring($i + 3) }
    $u = ($u -split '/')[0]
    $u = ($u -split ':')[0]
    return $u
}

# Port out of a URL, defaulting by scheme.
function Get-UrlPort {
    param([Parameter(Mandatory)][string]$Url)
    $scheme = 'http'
    $u = $Url
    $i = $u.IndexOf('://')
    if ($i -ge 0) { $scheme = $u.Substring(0, $i); $u = $u.Substring($i + 3) }
    $u = ($u -split '/')[0]
    if ($u -match ':(\d+)$') { return [int]$Matches[1] }
    if ($scheme -eq 'https') { return 443 }
    return 80
}

# HTTP status code of a URL, or '000' when it could not be reached. Mirrors the
# shell version's `curl -o /dev/null -w '%{http_code}'`.
function Get-HttpCode {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [hashtable]$Headers = @{}
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSeconds * 1000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'sentinel-ops'
        foreach ($k in $Headers.Keys) { $req.Headers.Add($k, [string]$Headers[$k]) }
        $resp = $req.GetResponse()
        try { return [string][int]$resp.StatusCode } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        # A 4xx/5xx arrives here as an exception but still carries a response,
        # and those codes are exactly what several health checks look for.
        if ($_.Exception.Response) {
            try { return [string][int]$_.Exception.Response.StatusCode } catch { return '000' }
        }
        return '000'
    } catch {
        return '000'
    }
}

# Is a TCP port free on loopback? Replaces the shell's /dev/tcp probe.
function Test-PortFree {
    param([Parameter(Mandatory)][int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Get-FreePort {
    foreach ($port in 39000..39050) {
        if (Test-PortFree -Port $port) { return $port }
    }
    return 39099
}

# ---------------------------------------------------------------------------
# File permissions
#
# The Windows analogue of chmod 600: break inheritance and grant the file to
# SYSTEM, Administrators and the current user only. OpenSSH on Windows refuses
# to use a private key readable by anyone else, so for the deployment key this
# is load-bearing rather than cosmetic.
# ---------------------------------------------------------------------------
function Set-RestrictedAcl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

        # On a directory the grant MUST carry (OI)(CI), or it applies to the
        # directory object alone: with inheritance already broken by
        # /inheritance:r, files created inside would then inherit no ACE at all
        # and even the owner could not write them.
        $rights = '(F)'
        if (Test-Path -LiteralPath $Path -PathType Container) { $rights = '(OI)(CI)(F)' }

        $aclArgs = @(
            $Path, '/inheritance:r',
            '/grant:r', "${me}:${rights}",
            '/grant:r', "*S-1-5-18:${rights}",      # SYSTEM, by SID so it works on any locale
            '/grant:r', "*S-1-5-32-544:${rights}"   # BUILTIN\Administrators
        )
        $null = & icacls.exe @aclArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-LogDebug "could not restrict ACL on ${Path}: $_"
        return $false
    }
}
