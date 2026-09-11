# Logflare and the Supabase logging pipeline

Logflare is deployed as a phase of its own. It is **not** assumed to exist just
because Supabase was installed.

```
Install Supabase → Start → Verify → Install Logflare → Configure logging → Verify
```

## Two deployment modes

The installer detects which applies (`logflare_detect_mode`) and records the
result in `.state/state.env` as `LOGFLARE_MODE`.

| Mode | When | What happens |
|---|---|---|
| `bundled` | The installed Supabase release ships an `analytics` service | The existing service is configured and restarted |
| `standalone` | It does not | `logflare/docker-compose.yml` is deployed alongside the Supabase stack |

Standalone Logflare joins the Supabase Docker network and uses the existing
PostgreSQL instance as its backend (schema `_analytics`), so there is no second
database to operate and no BigQuery dependency.

## The pipeline

```
Docker container stdout/stderr
        │
        ▼
     vector            reads the Docker socket, forwards to Logflare
        │
        ▼
    Logflare :4000     ingest + query API
        │
        ▼
    PostgreSQL         schema _analytics
        │
        ▼
  Supabase Studio      the Logs views
```

## Supabase variables this phase owns

All of these live in `supabase/.env` and are written by
`logflare_configure_supabase()`. They are re-applied after a Supabase update, so
an upstream `.env.example` change cannot silently revert them.

| Variable | Purpose |
|---|---|
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | Ingest token. vector authenticates with it when shipping logs. |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | Query/management token. Studio uses it to read the log views. |
| `LOGFLARE_SINGLE_TENANT` | `true` — skips account creation; there is one implicit tenant. |
| `LOGFLARE_SUPABASE_MODE` | `true` — provisions the Supabase log sources and the schemas Studio expects. |
| `DOCKER_SOCKET_LOCATION` | Path to the Docker socket vector mounts to collect container logs. Defaults to `/var/run/docker.sock`; differs under rootless Docker and Podman. |

Both tokens are generated once, during installation, and are never regenerated.
They must match on both sides: vector, Logflare and Studio all read them from
this same file (standalone mode copies them into `logflare/.env`).

## Standalone-only variables

Written to `logflare/.env`:

| Variable | Purpose |
|---|---|
| `POSTGRES_BACKEND_URL` | Connection string to the Supabase database |
| `POSTGRES_BACKEND_SCHEMA` / `LOGFLARE_DB_SCHEMA` | `_analytics` |
| `LOGFLARE_FEATURE_FLAG_OVERRIDE` | `multibackend=true`, required for the Postgres backend |
| `LOGFLARE_SECRET_KEY_BASE` | Phoenix session signing key |
| `LOGFLARE_SUPABASE_NETWORK` | The Docker network the Supabase stack created |
| `PHX_HTTP_PORT` | `4000` |

## Health

`logflare_health_check()` polls `http://localhost:4000/health`, falling back to
`/`. Port 4000 is bound to loopback only.

A Logflare that is running but not answering its health endpoint is reported as
a **warning**, not a failure: log aggregation being degraded should not take the
application offline.

## Disabling it

Answer *no* at install time, or set `ENABLE_LOGFLARE=false` in
`config/installer.env`. The logging phase is then skipped entirely and `status`
reports it as disabled.

## Troubleshooting

```bash
sentinel-ops logs logflare       # follow Logflare's own output
sentinel-ops status              # mode and health at a glance
```

**No logs appearing in Studio.** Almost always a token mismatch or the Docker
socket. Check that `LOGFLARE_PUBLIC_ACCESS_TOKEN` is identical in
`supabase/.env` and `logflare/.env`, and that `DOCKER_SOCKET_LOCATION` points at
a socket that exists:

```bash
ls -l "$(grep DOCKER_SOCKET_LOCATION /opt/sentinel-ops/supabase/.env | cut -d= -f2)"
```

**Logflare restarting repeatedly.** Usually the database backend. Confirm the
`_analytics` schema is reachable with the configured credentials, and check
`sentinel-ops logs logflare` for connection errors.
