# lib/commands/Credentials.ps1 - controlled disclosure of generated secrets.
#
# Counterpart of lib/commands/credentials.sh. Secrets are never written to
# installer logs or printed during installation. This command is the one place
# that shows them, and it refuses to run for a user who could not read
# supabase/.env directly anyway.

function Write-CredentialLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][AllowNull()][string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) {
        Write-Host ("{0,-26} {1}(not set){2}" -f $Label, $script:C_DIM, $script:C_RESET)
    } elseif ($script:SO_SHOW_SECRETS) {
        Write-Host ("{0,-26} {1}" -f $Label, $Value)
    } else {
        Write-Host ("{0,-26} {1}" -f $Label, (Format-MaskedSecret $Value))
    }
}

function Invoke-CmdCredentials {
    if (-not (Test-InstallationExists)) { Invoke-Die "No installation found at $($script:INSTALL_DIR)." }
    [void](Import-Config)

    $envFile = Join-Path $script:SUPABASE_DIR '.env'
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Invoke-Die "Cannot read $envFile."
    }
    try {
        $null = [System.IO.File]::ReadAllText($envFile)
    } catch {
        Invoke-Die "Cannot read $envFile (try running as Administrator)."
    }

    Write-Banner 'Sentinel Ops Credentials'

    Write-Host ''
    if ($script:SO_SHOW_SECRETS) {
        Write-Host ("{0}Secrets are shown in full. Do not paste this output anywhere.{1}" -f $script:C_YELLOW, $script:C_RESET)
    } else {
        Write-Host ("{0}Values are masked. Re-run with -Show to reveal them.{1}" -f $script:C_DIM, $script:C_RESET)
    }

    Write-Section 'Supabase Studio'
    Write-CredentialLine -Label 'URL'      -Value $script:SUPABASE_PUBLIC_URL
    Write-CredentialLine -Label 'Username' -Value (Get-EnvValue -Path $envFile -Key 'DASHBOARD_USERNAME')
    Write-CredentialLine -Label 'Password' -Value (Get-EnvValue -Path $envFile -Key 'DASHBOARD_PASSWORD')

    $port = Get-EnvValue -Path $envFile -Key 'POSTGRES_PORT'; if (-not $port) { $port = '5432' }
    Write-Section 'Database'
    Write-CredentialLine -Label 'Host'     -Value 'localhost'
    Write-CredentialLine -Label 'Port'     -Value $port
    Write-CredentialLine -Label 'Database' -Value (Get-DbName)
    Write-CredentialLine -Label 'User'     -Value (Get-DbUser)
    Write-CredentialLine -Label 'Password' -Value (Get-EnvValue -Path $envFile -Key 'POSTGRES_PASSWORD')

    Write-Section 'API keys'
    Write-CredentialLine -Label 'Publishable (anon)' -Value (Get-SupabasePublishableKey)
    Write-CredentialLine -Label 'Service role'       -Value (Get-SupabaseServiceRoleKey)
    Write-CredentialLine -Label 'JWT secret'         -Value (Get-EnvValue -Path $envFile -Key 'JWT_SECRET')

    if ($script:ENABLE_LOGFLARE -eq 'true') {
        Write-Section 'Logflare'
        Write-CredentialLine -Label 'Public token'  -Value (Get-EnvValue -Path $envFile -Key 'LOGFLARE_PUBLIC_ACCESS_TOKEN')
        Write-CredentialLine -Label 'Private token' -Value (Get-EnvValue -Path $envFile -Key 'LOGFLARE_PRIVATE_ACCESS_TOKEN')
    }

    Write-Host ''
    Write-Host ("{0}The service-role key and JWT secret grant full database access.{1}" -f $script:C_YELLOW, $script:C_RESET)
    Write-Host ("{0}Neither is ever given to the frontend build.{1}" -f $script:C_DIM, $script:C_RESET)
    Write-Host ''
    return 0
}
