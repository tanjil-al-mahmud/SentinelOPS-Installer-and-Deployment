# lib/Repo.ps1 - deployment key handling and the Sentinel Ops Git checkout.
#
# Counterpart of lib/repo.sh.

$script:SO_KNOWN_HOSTS = ''

# ---------------------------------------------------------------------------
# Deployment key
# ---------------------------------------------------------------------------

# Find the deployment key. Searched in order: the configured path, the
# installation root, and the directory the installer was launched from.
function Find-DeployKey {
    $candidates = @()
    if ($script:DEPLOY_KEY) { $candidates += $script:DEPLOY_KEY }
    $candidates += @(
        (Join-Path $script:INSTALL_DIR 'deploy_key'),
        (Join-Path $script:CONFIG_DIR  'deploy_key'),
        (Join-Path $script:SO_SOURCE_DIR 'deploy_key'),
        (Join-Path (Get-Location).Path 'deploy_key')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

# Validate the key and lock down its permissions. The Windows OpenSSH client
# refuses to use a key file that other accounts can read, exactly as OpenSSH on
# Linux refuses a group- or world-readable one - so the ACL tightening here is
# required for the clone to work, not a nicety.
function Initialize-DeployKey {
    $key = Find-DeployKey
    if (-not $key) {
        Write-LogError 'No deployment key found.'
        Write-Host ''
        Write-Host 'The Sentinel Ops repository is private and needs an SSH deployment key.'
        Write-Host 'Place the private key at one of:'
        Write-Host "  $(Join-Path $script:INSTALL_DIR 'deploy_key')"
        Write-Host '  .\deploy_key   (next to the installer, or the directory you run it from)'
        Write-Host ''
        return $false
    }

    # Copy into the installation so later updates do not depend on wherever the
    # operator originally left it.
    $dest = Join-Path $script:CONFIG_DIR 'deploy_key'
    if ($key -ne $dest) {
        if (-not (Test-Path -LiteralPath $script:CONFIG_DIR)) {
            New-Item -ItemType Directory -Force -Path $script:CONFIG_DIR | Out-Null
        }
        Copy-Item -LiteralPath $key -Destination $dest -Force
        $key = $dest
    }

    if (-not (Set-RestrictedAcl -Path $key)) {
        Write-LogWarn "Could not restrict permissions on $key."
        Write-LogWarn 'OpenSSH may refuse to use it.'
    }

    $content = Read-TextFile -Path $key
    if (-not $content -or $content -notmatch 'BEGIN .*PRIVATE KEY') {
        Write-LogError "$key does not look like an SSH private key."
        Write-LogError 'Make sure you copied the private key, not the .pub file.'
        return $false
    }

    # A key saved on Windows often has CRLF endings, which OpenSSH rejects with
    # a misleading "invalid format" error. Normalise it.
    if ($content.Contains("`r`n")) {
        Write-LogInfo 'Deployment key had Windows line endings; normalising to LF.'
        Write-TextFile -Path $key -Content $content
        [void](Set-RestrictedAcl -Path $key)
    }

    $script:DEPLOY_KEY = $key
    Write-LogOk "Deployment key ready ($key)"
    return $true
}

# Host of an SSH-style Git URL; $null for HTTPS remotes.
function Get-RepoSshHost {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -like 'ssh://*') {
        $u = $Url.Substring(6)
        if ($u.Contains('@')) { $u = $u.Substring($u.IndexOf('@') + 1) }
        $u = ($u -split '/')[0]
        return ($u -split ':')[0]
    }
    if ($Url -match '^[^/]+@([^:]+):') { return $Matches[1] }
    return $null
}

# Candidate ssh-keyscan binaries, best first.
#
# The ssh-keyscan that ships in C:\Windows\System32\OpenSSH is frequently too
# old to negotiate with GitHub (it cannot do sntrup761x25519-sha512) and returns
# no keys at all while still exiting successfully. Git for Windows bundles a
# current build, so it is tried as well.
function Get-KeyscanCandidates {
    $candidates = @()
    $onPath = Get-Command 'ssh-keyscan' -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        foreach ($rel in @('usr\bin\ssh-keyscan.exe', 'mingw64\bin\ssh-keyscan.exe')) {
            $p = Join-Path $gitRoot $rel
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and ($candidates -notcontains $p)) {
                $candidates += $p
            }
        }
    }
    return $candidates
}

# Keep only genuine host-key entries: "<host> <keytype> <base64>".
#
# Filtering on "not a comment" is not enough - a failing ssh-keyscan prints
# diagnostics that are neither comments nor keys, and writing those into
# known_hosts produces a file that parses but contains no usable key, which
# surfaces much later as an unexplained "Host key verification failed".
function Select-HostKeyLines {
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$HostName
    )
    if (-not $Text) { return @() }
    $pattern = '^\S+\s+(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-\S+|sk-ssh-\S+|sk-ecdsa-\S+)\s+[A-Za-z0-9+/=]+'
    return @($Text -split "`n" |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ -match $pattern -and $_ -like "*$HostName*" })
}

# Pin the remote's host key so clones never block on an interactive prompt and
# are not silently vulnerable to a substituted host.
function Initialize-KnownHosts {
    $repoHost = Get-RepoSshHost -Url $script:APP_REPOSITORY
    if (-not $repoHost) { return $true }

    $script:SO_KNOWN_HOSTS = Join-Path $script:CONFIG_DIR 'known_hosts'
    if (-not (Test-Path -LiteralPath $script:CONFIG_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:CONFIG_DIR | Out-Null
    }

    $existing = ''
    if (Test-Path -LiteralPath $script:SO_KNOWN_HOSTS -PathType Leaf) {
        $existing = Read-TextFile -Path $script:SO_KNOWN_HOSTS
    }
    # Only trust an existing file if it holds a real key line for this host.
    if ((Select-HostKeyLines -Text $existing -HostName $repoHost).Count -gt 0) {
        return $true
    }

    Write-LogInfo "Recording the host key for $repoHost..."
    $keyLines = @()
    foreach ($scanner in (Get-KeyscanCandidates)) {
        $scan = Invoke-Capture -Command $scanner -Arguments @('-T', '10', $repoHost)
        $keyLines = Select-HostKeyLines -Text $scan -HostName $repoHost
        if ($keyLines.Count -gt 0) {
            Write-LogDebug "host keys obtained with $scanner"
            break
        }
        Write-LogDebug "$scanner returned no usable host key"
    }

    if ($keyLines.Count -eq 0) {
        # Better to let SSH learn the key on first contact than to write a file
        # that makes strict checking fail against every host.
        Write-LogWarn "ssh-keyscan could not retrieve a host key for $repoHost; falling back to accept-new."
        $script:SO_KNOWN_HOSTS = ''
        return $true
    }

    Write-TextFile -Path $script:SO_KNOWN_HOSTS -Content (($keyLines -join "`n") + "`n")
    Write-LogOk "Pinned $($keyLines.Count) host key(s) for $repoHost"
    return $true
}

# The SSH command used for every Git operation.
#
# Git parses GIT_SSH_COMMAND with a POSIX shell even on Windows, so the paths in
# it must use forward slashes and be quoted - a backslash would be eaten as an
# escape and the key would appear to be missing.
#
# IdentitiesOnly stops SSH offering any other agent key and tripping the
# server's authentication-attempt limit.
function Get-GitSshCommand {
    $keyPath = $script:DEPLOY_KEY -replace '\\', '/'
    $cmd = "ssh -i `"$keyPath`" -o IdentitiesOnly=yes -o BatchMode=yes"
    if ($script:SO_KNOWN_HOSTS) {
        $khPath = $script:SO_KNOWN_HOSTS -replace '\\', '/'
        $cmd += " -o UserKnownHostsFile=`"$khPath`" -o StrictHostKeyChecking=yes"
    } else {
        $cmd += ' -o StrictHostKeyChecking=accept-new'
    }
    return $cmd
}

function Get-GitEnvironment {
    return @{
        GIT_SSH_COMMAND      = (Get-GitSshCommand)
        GIT_TERMINAL_PROMPT  = '0'
    }
}

# Cheap reachability probe before committing to a full clone.
function Test-RepoAccess {
    Write-LogInfo "Verifying access to $($script:APP_REPOSITORY)..."
    if (Invoke-Logged -Description 'git ls-remote' -Command 'git' `
            -Arguments @('ls-remote', '--heads', $script:APP_REPOSITORY) `
            -Environment (Get-GitEnvironment)) {
        Write-LogOk 'Repository accessible'
        return $true
    }
    Write-LogError "Cannot access $($script:APP_REPOSITORY) with the supplied deployment key."
    Write-Host ''
    Write-Host 'Check that:'
    Write-Host '  - the key is registered as a deploy key on the repository'
    Write-Host '  - the repository URL is correct'
    Write-Host '  - this host can reach the Git server'
    Write-Host ''
    return $false
}

# Confirm the branch exists before cloning, so the failure message is useful.
function Test-RepoBranchExists {
    $env:GIT_SSH_COMMAND = Get-GitSshCommand
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $out = Invoke-Capture -Command 'git' -Arguments @('ls-remote', '--heads', $script:APP_REPOSITORY, $script:APP_BRANCH)
        return [bool]($out -and $out.Trim())
    } finally {
        Remove-Item Env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue
        Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Checkout
# ---------------------------------------------------------------------------

function Test-RepoCloned {
    return (Test-Path -LiteralPath (Join-Path $script:APP_DIR '.git'))
}

function Invoke-AppGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $env:GIT_SSH_COMMAND = Get-GitSshCommand
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        return (Invoke-Capture -Command 'git' -Arguments (@('-C', $script:APP_DIR) + $Arguments))
    } finally {
        Remove-Item Env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue
        Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoClone {
    if (Test-RepoCloned) {
        Write-LogOk "Repository already cloned at $($script:APP_DIR)"
        return $true
    }
    if ((Test-Path -LiteralPath $script:APP_DIR) -and
        @(Get-ChildItem -LiteralPath $script:APP_DIR -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-LogError "$($script:APP_DIR) exists and is not a Git checkout."
        Write-LogError 'Move it aside and re-run, or choose a different installation directory.'
        return $false
    }

    if (-not (Test-RepoBranchExists)) {
        Write-LogError "Branch '$($script:APP_BRANCH)' does not exist on $($script:APP_REPOSITORY)."
        return $false
    }

    Write-LogInfo "Cloning $($script:APP_REPOSITORY) (branch $($script:APP_BRANCH))..."
    if (-not (Invoke-Logged -Description 'git clone' -Command 'git' -Arguments @(
            'clone', '--branch', $script:APP_BRANCH, $script:APP_REPOSITORY, $script:APP_DIR) `
            -Environment (Get-GitEnvironment))) {
        return $false
    }
    Write-LogOk 'Repository cloned'
    return $true
}

# Validate the checkout has the layout the installer depends on.
function Test-RepoLayout {
    $missing = @()
    if (-not (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'package.json') -PathType Leaf)) { $missing += 'package.json' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'supabase\migrations'))) { $missing += 'supabase/migrations/' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:APP_DIR 'supabase\functions'))) { $missing += 'supabase/functions/' }

    if ($missing.Count -gt 0) {
        Write-LogError 'Invalid Sentinel Ops repository.'
        Write-Host ''
        Write-Host 'Expected:'
        Write-Host '  package.json'
        Write-Host '  supabase/migrations/'
        Write-Host '  supabase/functions/'
        Write-Host ''
        Write-Host 'Missing:'
        foreach ($m in $missing) { Write-Host "  $m" }
        Write-Host ''
        return $false
    }
    Write-LogOk 'Repository layout validated'
    return $true
}

function Get-RepoCommit {
    $c = Invoke-AppGit -Arguments @('rev-parse', 'HEAD')
    if (-not $c) { return 'unknown' }
    return $c.Trim()
}

function Get-RepoShortCommit {
    $c = Invoke-AppGit -Arguments @('rev-parse', '--short', 'HEAD')
    if (-not $c) { return 'unknown' }
    return $c.Trim()
}

# Fetch and fast-forward. A non-fast-forward is reported rather than forced:
# local divergence means someone edited the checkout, and silently discarding
# that is worse than stopping.
function Update-Repo {
    if (-not (Test-RepoCloned)) {
        Write-LogError "No repository at $($script:APP_DIR)"
        return $false
    }

    $before = Get-RepoCommit

    Write-LogInfo 'Fetching latest changes...'
    if (-not (Invoke-Logged -Description 'git fetch' -Command 'git' `
            -Arguments @('-C', $script:APP_DIR, 'fetch', '--prune', 'origin') `
            -Environment (Get-GitEnvironment))) {
        return $false
    }

    # Make sure we are on the configured branch.
    $current = (Invoke-AppGit -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
    if ($current -ne $script:APP_BRANCH) {
        Write-LogInfo "Switching from '$current' to '$($script:APP_BRANCH)'..."
        if (-not (Invoke-Logged -Description 'git checkout' -Command 'git' `
                -Arguments @('-C', $script:APP_DIR, 'checkout', $script:APP_BRANCH) `
                -Environment (Get-GitEnvironment))) {
            return $false
        }
    }

    if (-not (Invoke-Logged -Description 'git merge --ff-only' -Command 'git' `
            -Arguments @('-C', $script:APP_DIR, 'merge', '--ff-only', "origin/$($script:APP_BRANCH)") `
            -Environment (Get-GitEnvironment))) {
        Write-LogError "Cannot fast-forward $($script:APP_DIR) to origin/$($script:APP_BRANCH)."
        Write-LogError 'The local checkout has diverged or has uncommitted changes.'
        Write-LogError "Inspect it with:  git -C $($script:APP_DIR) status"
        return $false
    }

    $after = Get-RepoCommit
    if ($before -eq $after) {
        Write-LogOk "Already up to date ($(Get-RepoShortCommit))"
    } else {
        Write-LogOk "Updated $($before.Substring(0, [Math]::Min(7, $before.Length))) -> $($after.Substring(0, [Math]::Min(7, $after.Length)))"
        $log = Invoke-AppGit -Arguments @('log', '--oneline', "$before..$after")
        if ($log) { @($log -split "`n" | Select-Object -First 20) | ForEach-Object { Write-Host $_ } }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Configuration prompts
# ---------------------------------------------------------------------------

function Read-RepoPromptConfig {
    Write-Section 'Sentinel Ops Repository'
    $script:APP_REPOSITORY = Read-DefaultPrompt -Question 'Repository' -Default $script:APP_REPOSITORY
    $script:APP_BRANCH     = Read-DefaultPrompt -Question 'Branch'     -Default $script:APP_BRANCH
}
