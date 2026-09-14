<#
    Exercise the pure helper functions the deployment logic relies on.
    Mirrors tests/test_helpers.sh.
#>
[CmdletBinding()]
param([string]$Root = '')

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

. (Join-Path $Root 'lib\Common.ps1')

$script:pass = 0
$script:fail = 0

function Test-Value {
    param(
        [Parameter(Mandatory)][string]$Description,
        [AllowEmptyString()][AllowNull()]$Expected,
        [AllowEmptyString()][AllowNull()]$Actual
    )
    if ([string]$Expected -eq [string]$Actual) {
        Write-Host "PASS  $Description"
        $script:pass++
    } else {
        Write-Host "FAIL  $Description"
        Write-Host "        expected: [$Expected]"
        Write-Host "        actual:   [$Actual]"
        $script:fail++
    }
}

$T = Join-Path ([System.IO.Path]::GetTempPath()) ('so-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $T -Force | Out-Null
$envf = Join-Path $T '.env'

# --- A realistic supabase/.env, including awkward characters ---------------
$seed = @'
############
# Secrets
############
POSTGRES_PASSWORD=p@ss/w0rd+with&special=chars
JWT_SECRET="quoted-secret-value"
ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def
# a comment that must survive
EMPTY_VALUE=
SITE_URL=http://localhost:3000
'@
Write-TextFile -Path $envf -Content ($seed + "`n")

# --- Get-EnvValue ----------------------------------------------------------
Test-Value 'env_get plain'            'p@ss/w0rd+with&special=chars' (Get-EnvValue -Path $envf -Key 'POSTGRES_PASSWORD')
Test-Value 'env_get strips quotes'    'quoted-secret-value'          (Get-EnvValue -Path $envf -Key 'JWT_SECRET')
Test-Value 'env_get empty value'      ''                             (Get-EnvValue -Path $envf -Key 'EMPTY_VALUE')
Test-Value 'env_get missing key'      ''                             (Get-EnvValue -Path $envf -Key 'NOT_THERE')
Test-Value 'env_get value with dots'  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def' (Get-EnvValue -Path $envf -Key 'ANON_KEY')

# --- Set-EnvValue ----------------------------------------------------------
Set-EnvValue -Path $envf -Key 'SITE_URL' -Value 'http://localhost:9999'
Test-Value 'env_set replaced' 'http://localhost:9999' (Get-EnvValue -Path $envf -Key 'SITE_URL')

$content = Read-TextFile -Path $envf
Test-Value 'comment not clobbered' $true ($content.Contains('# a comment that must survive'))

# A backslash in a generated password is the classic corruption case.
Set-EnvValue -Path $envf -Key 'TRICKY' -Value 'back\slash$dollar&amp"quote'
Test-Value 'env_set special chars' 'back\slash$dollar&amp"quote' (Get-EnvValue -Path $envf -Key 'TRICKY')

Set-EnvValue -Path $envf -Key 'BRAND_NEW' -Value 'appended'
Test-Value 'env_set appends new' 'appended' (Get-EnvValue -Path $envf -Key 'BRAND_NEW')
Test-Value 'append kept old'     'http://localhost:9999' (Get-EnvValue -Path $envf -Key 'SITE_URL')

Set-EnvValue -Path $envf -Key 'BRAND_NEW' -Value 'appended'
$occurrences = @(([System.IO.File]::ReadAllLines($envf)) | Where-Object { $_ -match '^BRAND_NEW=' }).Count
Test-Value 'env_set idempotent' 1 $occurrences

# A key that is a prefix of another must not be confused with it.
Set-EnvValue -Path $envf -Key 'SITE_URL_EXTRA' -Value 'extra'
Test-Value 'prefix key distinct' 'http://localhost:9999' (Get-EnvValue -Path $envf -Key 'SITE_URL')
Test-Value 'prefix key set'      'extra'                 (Get-EnvValue -Path $envf -Key 'SITE_URL_EXTRA')

# A value containing '=' must survive a round trip.
Set-EnvValue -Path $envf -Key 'B64' -Value 'YWJjZGVmZ2g='
Test-Value 'value with = preserved' 'YWJjZGVmZ2g=' (Get-EnvValue -Path $envf -Key 'B64')

# --- URL helpers -----------------------------------------------------------
Test-Value 'url_host https'     'supabase.example.test' (Get-UrlHost 'https://supabase.example.test/rest/v1')
Test-Value 'url_host with port' 'localhost'             (Get-UrlHost 'http://localhost:8000/x')
Test-Value 'url_host bare'      'example.test'          (Get-UrlHost 'example.test')
Test-Value 'url_port explicit'  8000                    (Get-UrlPort 'http://localhost:8000/x')
Test-Value 'url_port http'      80                      (Get-UrlPort 'http://localhost/x')
Test-Value 'url_port https'     443                     (Get-UrlPort 'https://app.example.test')

Test-Value 'strip_trailing_slash' 'http://localhost:3000' (Remove-TrailingSlash 'http://localhost:3000/')

# --- Masking ---------------------------------------------------------------
Test-Value 'mask long'  'abcd...wxyz' (Format-MaskedSecret 'abcdefghijklmnopqrstuvwxyz')
Test-Value 'mask short' '********'    (Format-MaskedSecret 'short')

# --- Migration filename parsing -------------------------------------------
. (Join-Path $Root 'lib\Database.ps1')
Test-Value 'version parse'    '20240101120000' (Get-MigrationVersion -BaseName '20240101120000_add_users.sql')
Test-Value 'name parse'       'add_users'      (Get-MigrationName    -BaseName '20240101120000_add_users.sql')
Test-Value 'version no suffix' '20240101120000' (Get-MigrationVersion -BaseName '20240101120000.sql')
Test-Value 'sql quote escapes' "it''s"         (ConvertTo-SqlLiteral "it's")

Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
