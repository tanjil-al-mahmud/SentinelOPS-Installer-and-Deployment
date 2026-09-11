#!/usr/bin/env bash
# lib/selfinstall.sh - copy the installer into the installation root.
#
# After this runs, `sentinel-ops` is on PATH and every later update uses the
# copy under the installation directory rather than whatever checkout the
# operator happened to run first.
# shellcheck shell=bash

SO_BIN_LINK="/usr/local/bin/sentinel-ops"

selfinstall() {
    local dest_bin="${INSTALL_DIR}/bin" dest_lib="${INSTALL_DIR}/lib" dest_assets="${INSTALL_DIR}/assets"

    # Already running from the installed location: nothing to copy.
    if [[ "$SO_ROOT" == "$INSTALL_DIR" ]]; then
        log_debug "already running from ${INSTALL_DIR}"
    else
        mkdir -p "$dest_bin" "$dest_lib" "$dest_assets"
        cp -a "${SO_ROOT}/bin/." "$dest_bin/"
        cp -a "${SO_ROOT}/lib/." "$dest_lib/"
        cp -a "${SO_ROOT}/assets/." "$dest_assets/"
        chmod +x "${dest_bin}/sentinel-ops" 2>/dev/null || true
        log_ok "Installer copied to ${INSTALL_DIR}"
    fi

    # From here on, templates come from the installed copy.
    SO_ASSETS_DIR="$dest_assets"
    SO_LIB_DIR="$dest_lib"

    # Put the command on PATH.
    if [[ -w "$(dirname "$SO_BIN_LINK")" ]]; then
        ln -sfn "${dest_bin}/sentinel-ops" "$SO_BIN_LINK"
        log_ok "Command available as: sentinel-ops"
    else
        log_warn "Could not write ${SO_BIN_LINK}."
        log_warn "Run the installed copy directly: ${dest_bin}/sentinel-ops"
    fi
    return 0
}
