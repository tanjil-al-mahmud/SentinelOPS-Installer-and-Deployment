<#
    Secret generation: JWT signing, randomness, and - most importantly - the
    placeholder table that decides which of upstream's published values get
    replaced. Mirrors tests/test_secrets.sh.
#>
[CmdletBinding()]
param([string]$Root = '')

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

. (Join-Path $Root 'lib\Common.ps1')
. (Join-Path $Root 'lib\Platform.ps1')
. (Join-Path $Root 'lib\Prereqs.ps1')
. (Join-Path $Root 'lib\Config.ps1')
. (Join-Path $Root 'lib\Supabase.ps1')

$script:pass = 0
$script:fail = 0

function Test-Value {
    param(
        [Parameter(Mandatory)][string]$Description,
        [AllowEmptyString()][AllowNull()]$Expected,
        [AllowEmptyString()][AllowNull()]$Actual
    )
    if ([string]$Expected -eq [string]$Actual) {
        Write-Host "PASS  $Description"; $script:pass++
    } else {
        Write-Host "FAIL  $Description"
        Write-Host "        expected: [$Expected]"
        Write-Host "        actual:   [$Actual]"
        $script:fail++
    }
}

# --- base64url -------------------------------------------------------------
$utf8 = [System.Text.Encoding]::UTF8
Test-Value 'b64url header' 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' `
    (ConvertTo-Base64Url -Bytes ($utf8.GetBytes('{"alg":"HS256","typ":"JWT"}')))
Test-Value 'b64url unpadded' $false `
    ((ConvertTo-Base64Url -Bytes ($utf8.GetBytes('ab'))).Contains('='))
Test-Value 'b64url url-safe alphabet' $true `
    ((ConvertTo-Base64Url -Bytes ([byte[]]@(0xFB, 0xFF, 0xFE))) -notmatch '[+/]')

# --- JWT signing, against the RFC 7515 / jwt.io HS256 reference vector -----
$h = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
$p = 'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ'
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = $utf8.GetBytes('your-256-bit-secret')
$refSig = ConvertTo-Base64Url -Bytes ($hmac.ComputeHash($utf8.GetBytes("$h.$p")))
$hmac.Dispose()
Test-Value 'HS256 matches reference vector' 'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c' $refSig

$anon = New-SupabaseJwt -Secret 'test-secret' -Role 'anon'         -IssuedAt 1700000000 -Expiry 2000000000
$svc  = New-SupabaseJwt -Secret 'test-secret' -Role 'service_role' -IssuedAt 1700000000 -Expiry 2000000000
$other= New-SupabaseJwt -Secret 'other-secret' -Role 'anon'        -IssuedAt 1700000000 -Expiry 2000000000

Test-Value 'jwt has three parts' 3 ($anon.Split('.').Count)

function Get-JwtPayload {
    param([string]$Token)
    $p = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
}
$payload = Get-JwtPayload -Token $anon
Test-Value 'jwt role claim' $true ($payload.Contains('"role":"anon"'))
Test-Value 'jwt issuer'     $true ($payload.Contains('"iss":"supabase"'))
Test-Value 'jwt exp'        $true ($payload.Contains('"exp":2000000000'))
Test-Value 'jwt differs by secret'      $true ($anon -ne $other)
Test-Value 'anon differs from service_role' $true ($anon -ne $svc)

# --- Randomness ------------------------------------------------------------
Test-Value 'random_token length' 64 (New-RandomToken 32).Length
Test-Value 'random_token is hex' $true ((New-RandomToken 16) -match '^[0-9a-f]{32}$')
Test-Value 'random_token is random' $true ((New-RandomToken 32) -ne (New-RandomToken 32))
# VAULT_ENC_KEY must be exactly 32 characters.
Test-Value 'vault key is 32 chars' 32 (New-RandomToken 16).Length
Test-Value 'base64 key is 44 chars' 44 (New-RandomBase64 32).Length

# --- Placeholder detection -------------------------------------------------
# These are the exact values Supabase ships in docker/.env.example. Every one
# must be replaced; a deployment that keeps any of them is compromised out of
# the box. Three of them carry no obvious placeholder marker, which is why this
# table exists rather than a substring heuristic.
$mustRegenerate = @{
    'JWT_SECRET'         = 'your-super-secret-jwt-token-with-at-least-32-characters-long'
    'POSTGRES_PASSWORD'  = 'your-super-secret-and-long-postgres-password'
    'POOLER_TENANT_ID'   = 'your-tenant-id'
    'LOGFLARE_PUBLIC'    = 'your-super-secret-and-long-logflare-key-public'
    'VAULT_ENC_KEY'      = 'your-32-character-encryption-key'
    'DASHBOARD_PASSWORD' = 'this_password_is_insecure_and_should_be_updated'
    'SECRET_KEY_BASE'    = 'UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq'
    'empty'              = ''
}
foreach ($k in ($mustRegenerate.Keys | Sort-Object)) {
    Test-Value "placeholder detected: $k" $true (Test-IsPlaceholderSecret $mustRegenerate[$k])
}

# The demo API keys are JWTs issued by "supabase-demo".
$demoAnon = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE'
Test-Value 'placeholder detected: demo ANON_KEY' $true (Test-IsPlaceholderSecret $demoAnon)

# A freshly generated secret must NOT be mistaken for a placeholder, or every
# run would rotate it and lock users out.
Test-Value 'generated token kept' $false (Test-IsPlaceholderSecret (New-RandomToken 32))
Test-Value 'generated b64 kept'   $false (Test-IsPlaceholderSecret (New-RandomBase64 32))
Test-Value 'issued jwt kept'      $false (Test-IsPlaceholderSecret $anon)

Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
