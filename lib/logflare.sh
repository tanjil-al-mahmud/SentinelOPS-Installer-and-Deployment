#!/usr/bin/env bash
# lib/logflare.sh - Supabase Analytics (Logflare) deployment.
#
# Follows the official self-hosting guide:
#   https://supabase.com/docs/reference/self-hosting-analytics/introduction
#
# Logflare is a phase of its own - it is NOT assumed to exist just because
# Supabase was installed. Upstream ships it as an optional compose overlay that
# is enabled with `run.sh config add logs`, which layers docker-compose.logs.yml
# on top of the base stack and adds two services: analytics (Logflare) and
# vector (log collection).
#
# Four deployment paths are handled, in order of preference:
#
#   run-sh      run.sh exists            -> sh run.sh config add logs   (official)
#   overlay     docker-compose.logs.yml  -> COMPOSE_FILE set manually
#   bundled     analytics already in the base compose file
#   standalone  none of the above        -> our own compose file
#
# The Supabase-side variables this phase owns are documented in docs/LOGFLARE.md.
# shellcheck shell=bash

# Logflare's HTTP port inside the container. Upstream deliberately does not
# publish it to the host - access is meant to go through the Kong gateway.
LOGFLARE_PORT="4000"
LOGFLARE_MODE=""

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------

logflare_detect_mode() {
    if [[ -f "${SUPABASE_DIR}/run.sh" ]]; then
        LOGFLARE_MODE="run-sh"
    elif [[ -f "${SUPABASE_DIR}/docker-compose.logs.yml" ]]; then
        LOGFLARE_MODE="overlay"
    elif supabase_compose config --services 2>/dev/null | grep -qx "analytics"; then
        LOGFLARE_MODE="bundled"
    else
        LOGFLARE_MODE="standalone"
    fi
    log_debug "logflare mode: ${LOGFLARE_MODE}"
    printf '%s' "$LOGFLARE_MODE"
}

# True when Logflare runs as part of the Supabase compose project.
_logflare_in_supabase_stack() {
    [[ "$LOGFLARE_MODE" != "standalone" ]]
}

# ---------------------------------------------------------------------------
# Configuration prompts
# ---------------------------------------------------------------------------

logflare_prompt_config() {
    section "Analytics (Logflare)"

    if ! confirm "Enable Logflare analytics (log aggregation)?" y; then
        ENABLE_LOGFLARE="false"
        return 0
    fi
    ENABLE_LOGFLARE="true"

    printf '\n'
    printf 'Storage backend:\n'
    printf '  postgres  - no extra services; upstream notes it is not optimised\n'
    printf '              for high-volume ingest or heavy querying\n'
    printf '  bigquery  - recommended for production; needs a Google Cloud\n'
    printf '              project with billing enabled and a service-account key\n\n'

    local backend=""
    prompt_default backend "Backend [postgres/bigquery]" "$LOGFLARE_BACKEND"
    case "$backend" in
        bigquery|bq) LOGFLARE_BACKEND="bigquery" ;;
        *)           LOGFLARE_BACKEND="postgres" ;;
    esac

    if [[ "$LOGFLARE_BACKEND" == "bigquery" ]]; then
        prompt_default GOOGLE_PROJECT_ID     "Google Cloud project ID"     "$GOOGLE_PROJECT_ID"
        prompt_default GOOGLE_PROJECT_NUMBER "Google Cloud project number" "$GOOGLE_PROJECT_NUMBER"
        printf '\n'
        log_info "Place the service-account key at: ${SUPABASE_DIR}/gcloud.json"
        log_warn "Never commit gcloud.json to version control."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Supabase-side configuration
#
# In every mode except standalone the compose overlay defines the analytics
# service itself and only interpolates these variables out of supabase/.env.
# We therefore set the documented variables and do NOT attempt to redefine the
# service's own connection settings.
# ---------------------------------------------------------------------------
logflare_configure_supabase() {
    local env_file="${SUPABASE_DIR}/.env" val

    # Access tokens. Generated once and never rotated automatically - vector,
    # Logflare and Studio all authenticate with these same values.
    for key in LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN; do
        val="$(env_get "$env_file" "$key" 2>/dev/null || true)"
        if [[ -z "$val" || "$val" == *your-super-secret* || "$val" == *change*me* ]]; then
            env_set "$env_file" "$key" "$(random_token 32)"
            log_debug "generated ${key}"
        fi
    done

    # Encryption key for sensitive Logflare database columns. Upstream requires
    # this to be base64 and warns it is mandatory for production use.
    val="$(env_get "$env_file" LOGFLARE_DB_ENCRYPTION_KEY 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
        env_set "$env_file" LOGFLARE_DB_ENCRYPTION_KEY "$(openssl rand -base64 32 2>/dev/null || random_token 32)"
        log_debug "generated LOGFLARE_DB_ENCRYPTION_KEY"
    fi
    # Present but empty is correct until a key rotation is in progress.
    env_get "$env_file" LOGFLARE_DB_ENCRYPTION_KEY_RETIRED >/dev/null 2>&1 || \
        env_set "$env_file" LOGFLARE_DB_ENCRYPTION_KEY_RETIRED ""

    # Single-tenant Supabase mode: no account creation, and the Supabase log
    # sources Studio expects are seeded automatically.
    env_set "$env_file" LOGFLARE_SINGLE_TENANT "true"
    env_set "$env_file" LOGFLARE_SUPABASE_MODE "true"

    # vector mounts the Docker socket to collect container logs. The path
    # differs under rootless Docker and Podman's compatibility shim.
    local sock="/var/run/docker.sock"
    if [[ ! -S "$sock" ]]; then
        sock="$(env_get "$env_file" DOCKER_SOCKET_LOCATION 2>/dev/null || printf '/var/run/docker.sock')"
        log_warn "/var/run/docker.sock not found; using ${sock}. Logs will not flow if this is wrong."
    fi
    env_set "$env_file" DOCKER_SOCKET_LOCATION "$sock"

    if [[ "$LOGFLARE_BACKEND" == "bigquery" ]]; then
        [[ -n "$GOOGLE_PROJECT_ID" ]]     && env_set "$env_file" GOOGLE_PROJECT_ID     "$GOOGLE_PROJECT_ID"
        [[ -n "$GOOGLE_PROJECT_NUMBER" ]] && env_set "$env_file" GOOGLE_PROJECT_NUMBER "$GOOGLE_PROJECT_NUMBER"
        if [[ ! -f "${SUPABASE_DIR}/gcloud.json" ]]; then
            log_error "BigQuery backend selected but ${SUPABASE_DIR}/gcloud.json is missing."
            log_error "Place the service-account key there and re-run, or switch to the postgres backend."
            return 1
        fi
        chmod 600 "${SUPABASE_DIR}/gcloud.json" 2>/dev/null || true
    else
        # Postgres backend. Only set these when the overlay has not already
        # wired them up, so we never fight the upstream compose file.
        val="$(env_get "$env_file" POSTGRES_BACKEND_SCHEMA 2>/dev/null || true)"
        [[ -n "$val" ]] || env_set "$env_file" POSTGRES_BACKEND_SCHEMA "_analytics"
    fi

    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Supabase analytics variables configured"
    return 0
}

# ---------------------------------------------------------------------------
# Enabling the overlay
# ---------------------------------------------------------------------------

# Official mechanism: run.sh manages COMPOSE_FILE for optional overlays.
_logflare_enable_run_sh() {
    log_info "Enabling the logs overlay (run.sh config add logs)..."
    if ! run_logged "run.sh config add logs" bash -c \
            "cd '$SUPABASE_DIR' && sh run.sh config add logs"; then
        log_warn "run.sh could not enable the logs overlay; falling back to COMPOSE_FILE."
        _logflare_enable_compose_file || return 1
    fi
    return 0
}

# Fallback: set COMPOSE_FILE ourselves, exactly as run.sh would.
_logflare_enable_compose_file() {
    local env_file="${SUPABASE_DIR}/.env" current
    [[ -f "${SUPABASE_DIR}/docker-compose.logs.yml" ]] || {
        log_error "docker-compose.logs.yml not found in ${SUPABASE_DIR}"
        return 1
    }
    current="$(env_get "$env_file" COMPOSE_FILE 2>/dev/null || true)"
    [[ -n "$current" ]] || current="docker-compose.yml"
    if [[ ":${current}:" == *":docker-compose.logs.yml:"* ]]; then
        log_ok "Logs overlay already enabled"
        return 0
    fi
    env_set "$env_file" COMPOSE_FILE "${current}:docker-compose.logs.yml"
    log_ok "Logs overlay enabled (COMPOSE_FILE)"
    return 0
}

# ---------------------------------------------------------------------------
# Standalone deployment (only when upstream ships no analytics service at all)
# ---------------------------------------------------------------------------

logflare_compose() {
    ( cd "$LOGFLARE_DIR" && compose --env-file "${LOGFLARE_DIR}/.env" -f docker-compose.yml "$@" )
}

logflare_install_standalone() {
    local template="${SO_ASSETS_DIR}/logflare/docker-compose.yml"
    [[ -f "$template" ]] || { log_error "Missing Logflare template: ${template}"; return 1; }

    mkdir -p "$LOGFLARE_DIR"
    cp "$template" "${LOGFLARE_DIR}/docker-compose.yml"

    local sb_env="${SUPABASE_DIR}/.env" env_file="${LOGFLARE_DIR}/.env"
    local pg_pass pg_user pg_db

    pg_pass="$(env_get "$sb_env" POSTGRES_PASSWORD || true)"
    pg_user="$(env_get "$sb_env" POSTGRES_USER || printf 'postgres')"
    pg_db="$(env_get "$sb_env" POSTGRES_DB || printf 'postgres')"

    {
        printf '# Logflare standalone deployment - generated by sentinel-ops\n'
        printf 'LOGFLARE_PORT=%s\n'                 "$LOGFLARE_PORT"
        printf 'LOGFLARE_SINGLE_TENANT=true\n'
        printf 'LOGFLARE_SUPABASE_MODE=true\n'
        printf 'LOGFLARE_PUBLIC_ACCESS_TOKEN=%s\n'  "$(env_get "$sb_env" LOGFLARE_PUBLIC_ACCESS_TOKEN)"
        printf 'LOGFLARE_PRIVATE_ACCESS_TOKEN=%s\n' "$(env_get "$sb_env" LOGFLARE_PRIVATE_ACCESS_TOKEN)"
        printf 'LOGFLARE_DB_ENCRYPTION_KEY=%s\n'    "$(env_get "$sb_env" LOGFLARE_DB_ENCRYPTION_KEY)"
        printf 'LOGFLARE_SECRET_KEY_BASE=%s\n'      "$(random_token 32)"
        printf 'LOGFLARE_SUPABASE_NETWORK=%s\n'     "$(supabase_network_name)"
        printf 'LOGFLARE_BACKEND=%s\n'              "$LOGFLARE_BACKEND"
        printf 'POSTGRES_BACKEND_URL=postgresql://%s:%s@%s:5432/%s\n' \
            "$pg_user" "$pg_pass" "$(supabase_db_service)" "$pg_db"
        printf 'POSTGRES_BACKEND_SCHEMA=_analytics\n'
        printf 'GOOGLE_PROJECT_ID=%s\n'             "$GOOGLE_PROJECT_ID"
        printf 'GOOGLE_PROJECT_NUMBER=%s\n'         "$GOOGLE_PROJECT_NUMBER"
    } >"$env_file"
    chmod 600 "$env_file" 2>/dev/null || true

    log_info "Starting standalone Logflare..."
    run_logged "logflare up" bash -c \
        "cd '$LOGFLARE_DIR' && ${DOCKER_COMPOSE_CMD[*]} --env-file '${env_file}' -f docker-compose.yml up -d"
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

logflare_install() {
    if [[ "$ENABLE_LOGFLARE" != "true" ]]; then
        log_info "Logflare is disabled in the configuration; skipping."
        return 0
    fi

    logflare_detect_mode >/dev/null
    logflare_configure_supabase || return 1

    case "$LOGFLARE_MODE" in
        run-sh)
            _logflare_enable_run_sh || return 1
            log_info "Starting the Supabase stack with analytics..."
            run_logged "run.sh start" bash -c "cd '$SUPABASE_DIR' && sh run.sh start" || return 1
            ;;
        overlay)
            _logflare_enable_compose_file || return 1
            run_logged "start analytics" bash -c \
                "$(_supabase_compose_cmd) up -d --remove-orphans" || return 1
            ;;
        bundled)
            log_info "Analytics is part of the base compose file; starting it."
            run_logged "start analytics" bash -c \
                "$(_supabase_compose_cmd) up -d analytics vector" \
                || log_warn "Could not start the analytics services individually."
            ;;
        standalone)
            log_info "Upstream ships no analytics service; deploying Logflare separately."
            logflare_install_standalone || return 1
            ;;
    esac

    state_set LOGFLARE_MODE "$LOGFLARE_MODE"
    state_set LOGFLARE_BACKEND "$LOGFLARE_BACKEND"

    # Upstream warns that the Logflare dashboard has no authentication of its
    # own, so it must never be exposed publicly.
    log_warn "Logflare's /dashboard has no authentication - do not expose port ${LOGFLARE_PORT} publicly."
    return 0
}

# ---------------------------------------------------------------------------
# Health
#
# Port 4000 is not published to the host by default, so the probe runs inside
# the container. Each step falls back to the next.
# ---------------------------------------------------------------------------

_logflare_container() {
    if [[ "$(state_get LOGFLARE_MODE "${LOGFLARE_MODE:-run-sh}")" == "standalone" ]]; then
        logflare_compose ps -q logflare 2>/dev/null | head -n1
    else
        supabase_container_id analytics
    fi
}

logflare_check() {
    local cid
    cid="$(_logflare_container)"
    [[ -n "$cid" ]] || return 1

    # 1. In-container HTTP probe (the port is not exposed to the host).
    if docker exec "$cid" sh -c \
        'command -v curl >/dev/null && curl -fsS http://127.0.0.1:4000/health >/dev/null' 2>/dev/null; then
        return 0
    fi
    if docker exec "$cid" sh -c \
        'command -v wget >/dev/null && wget -qO- http://127.0.0.1:4000/health >/dev/null' 2>/dev/null; then
        return 0
    fi

    # 2. The host port, in case this deployment publishes it.
    local code
    code="$(_http_code "http://127.0.0.1:${LOGFLARE_PORT}/health")"
    [[ "$code" == "200" ]] && return 0

    # 3. Docker's own healthcheck verdict.
    local health
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
    [[ "$health" == "healthy" ]]
}

logflare_running() {
    local cid
    cid="$(_logflare_container)"
    [[ -n "$cid" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" == "true" ]]
}

logflare_health_check() {
    [[ "$ENABLE_LOGFLARE" == "true" ]] || return 0

    log_info "Waiting for Logflare..."
    # Logflare runs its database migrations on first boot, so the initial start
    # is slow; upstream's own healthcheck allows a 60s start period.
    if wait_for 180 5 logflare_check; then
        log_ok "Logflare available"
        return 0
    fi

    if logflare_running; then
        # Degraded log aggregation must not take the application offline.
        log_warn "Logflare is running but did not answer its health endpoint."
        log_warn "Check with: sentinel-ops logs logflare"
        return 0
    fi

    log_error "Logflare failed health check"
    log_error "Check with: sentinel-ops logs logflare"
    return 1
}
