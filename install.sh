#!/usr/bin/env bash
#
# Sentinel Ops bootstrap installer.
#
#   sudo ./install.sh            guided installation
#   sudo ./install.sh --yes      non-interactive, accept every default
#
# This is a thin wrapper. It hands straight over to bin/sentinel-ops, which is
# also what gets installed onto the server, so there is only ever one code path.
#
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/bin/sentinel-ops"

if [[ ! -f "$CLI" ]]; then
    printf '[ERROR] Cannot find %s\n' "$CLI" >&2
    printf 'Run this script from inside the installer checkout.\n' >&2
    exit 1
fi

# A CRLF line ending here is the single most common way this fails when the
# repository is cloned on Windows, and the error the shell gives is unhelpful.
if grep -q $'\r' "$CLI" 2>/dev/null; then
    printf '[ERROR] %s has Windows line endings (CRLF).\n' "$CLI" >&2
    printf 'Fix with:  sed -i "s/\\r$//" %s/bin/* %s/lib/*.sh %s/lib/commands/*.sh\n' \
        "$SCRIPT_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR" >&2
    exit 1
fi

chmod +x "$CLI" 2>/dev/null || true

# If no explicit command was given, install. Anything else is passed through so
# ./install.sh status works too.
if (( $# == 0 )); then
    exec "$CLI" install
fi

case "$1" in
    -*) exec "$CLI" install "$@" ;;
    *)  exec "$CLI" "$@" ;;
esac
