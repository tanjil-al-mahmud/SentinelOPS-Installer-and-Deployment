#!/usr/bin/env bash
# Verify JWT signing and the proxy TLS heuristic.
#
# The JWTs matter: on the fallback install path the installer signs the anon
# and service_role keys itself, and a malformed token means every API request
# from the frontend is rejected.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Minimal stubs so the libraries load outside a real installation.
source "${ROOT}/lib/common.sh"
SUPABASE_DIR="$(mktemp -d)"
INSTALL_DIR="$SUPABASE_DIR"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/proxy.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}
ok()  { check "$1" "0" "$2"; }
nok() { check "$1" "1" "$2"; }

# --- base64url -------------------------------------------------------------
# Must be unpadded and use the URL-safe alphabet.
enc="$(printf '{"alg":"HS256","typ":"JWT"}' | _b64url)"
check "b64url header" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "$enc"
check "b64url unpadded" "0" "$(printf '%s' "$enc" | grep -c '=' || true)"

# --- JWT structure ---------------------------------------------------------
token="$(_sign_jwt "test-secret" "anon" 1700000000 2000000000)"
check "jwt has three parts" "3" "$(printf '%s' "$token" | awk -F. '{print NF}')"

# Decode the payload, restoring the base64 padding that base64url strips.
# Note: the padding must only be added when it is actually needed - a single
# stray '=' makes openssl silently drop the final bytes of the payload.
payload_b64="$(printf '%s' "$token" | cut -d. -f2)"
pad=$(( (4 - ${#payload_b64} % 4) % 4 ))
padded="$payload_b64"
while (( pad-- > 0 )); do padded="${padded}="; done
payload="$(printf '%s' "$padded" | tr '_-' '/+' | openssl base64 -d -A 2>/dev/null)"
check "jwt role claim"  "1" "$(printf '%s' "$payload" | grep -c '"role":"anon"')"
check "jwt issuer"      "1" "$(printf '%s' "$payload" | grep -c '"iss":"supabase"')"
check "jwt exp"         "1" "$(printf '%s' "$payload" | grep -c '"exp":2000000000')"

# Signature must actually verify against the secret.
expected_sig="$(printf '%s.%s' "$(printf '%s' "$token" | cut -d. -f1)" "$payload_b64" \
    | openssl dgst -sha256 -hmac "test-secret" -binary | _b64url)"
check "jwt signature verifies" "$expected_sig" "$(printf '%s' "$token" | cut -d. -f3)"

# A different secret must produce a different signature.
other="$(_sign_jwt "other-secret" "anon" 1700000000 2000000000)"
if [[ "$token" != "$other" ]]; then
    printf 'PASS  jwt differs by secret\n'; pass=$((pass+1))
else
    printf 'FAIL  jwt differs by secret\n'; fail=$((fail+1))
fi

# anon and service_role must differ.
svc="$(_sign_jwt "test-secret" "service_role" 1700000000 2000000000)"
if [[ "$token" != "$svc" ]]; then
    printf 'PASS  anon differs from service_role\n'; pass=$((pass+1))
else
    printf 'FAIL  anon differs from service_role\n'; fail=$((fail+1))
fi

# --- random_token ----------------------------------------------------------
t1="$(random_token 32)"; t2="$(random_token 32)"
check "random_token length" "64" "${#t1}"
if [[ "$t1" != "$t2" ]]; then
    printf 'PASS  random_token is random\n'; pass=$((pass+1))
else
    printf 'FAIL  random_token repeated\n'; fail=$((fail+1))
fi

# --- TLS capability heuristic ---------------------------------------------
# Anything that cannot obtain a public certificate must be rejected, or the
# install stalls on a doomed ACME challenge.
_proxy_tls_capable "app.sentinelops.io"; ok  "real domain is TLS capable" "$?"
_proxy_tls_capable "localhost";          nok "localhost rejected"         "$?"
_proxy_tls_capable "192.168.1.10";       nok "bare IPv4 rejected"         "$?"
_proxy_tls_capable "app.example.com";    nok "placeholder domain rejected" "$?"
_proxy_tls_capable "myhost";             nok "hostname without dot rejected" "$?"
_proxy_tls_capable "";                   nok "empty rejected"             "$?"
_proxy_tls_capable "box.local";          nok ".local rejected"            "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$SUPABASE_DIR"
[[ $fail -eq 0 ]]
