# Supabase Analytics (Logflare)

Follows the official reference:
<https://supabase.com/docs/reference/self-hosting-analytics/introduction>

Logflare is deployed as a phase of its own. It is **not** assumed to exist just
because Supabase was installed.

```
Install Supabase → Start → Verify → Configure analytics → Enable overlay → Verify
```

## How it is enabled

Upstream ships analytics as an **optional compose overlay**, not as part of the
base stack. `run.sh config add logs` layers `docker-compose.logs.yml` on top of
`docker-compose.yml` and adds two services: **analytics** (Logflare) and
**vector** (log collection). It does this by managing `COMPOSE_FILE` in
`supabase/.env`.

The installer detects which path applies and records it in `.state/state.env` as
`LOGFLARE_MODE`:

| Mode | When | What the installer does |
|---|---|---|
| `run-sh` | `supabase/run.sh` exists | `sh run.sh config add logs` then `sh run.sh start` — the official route |
| `overlay` | `docker-compose.logs.yml` exists, no `run.sh` | Sets `COMPOSE_FILE` itself, exactly as run.sh would |
| `bundled` | `analytics` is already in the base compose file | Starts `analytics` and `vector` |
| `standalone` | None of the above | Deploys `logflare/docker-compose.yml` alongside the stack |

> Because `COMPOSE_FILE` drives which services exist, the installer never passes
> `-f docker-compose.yml` to Compose. Doing so would silently drop the analytics
> and vector services from every `ps`, `logs`, `up` and `down`.

## The pipeline

```
Docker container stdout/stderr
        │
        ▼
     vector            reads the Docker socket, ships to Logflare
        │
        ▼
   Logflare :4000      ingest + query API  (NOT published to the host)
        │
        ▼
  Postgres or BigQuery
        │
        ▼
  Supabase Studio      the Logs views
```

## Backends

Chosen at install time, stored as `LOGFLARE_BACKEND` in `config/installer.env`.

### `postgres` (default)

| Variable | Purpose |
|---|---|
| `POSTGRES_BACKEND_URL` | Connection string. Supplied by the upstream overlay; the installer only sets it in standalone mode. |
| `POSTGRES_BACKEND_SCHEMA` | Defaults to `_analytics`. |

No extra services and nothing to provision. Upstream notes it is **not
optimised for high-volume inserts or heavy querying**, and that its support for
the BigQuery SQL dialect is limited.

Upstream also recommends pointing Logflare at a **separate Postgres database**
rather than your production one, to avoid confusing application data with log
data while debugging.

### `bigquery` (recommended for production)

| Variable | Purpose |
|---|---|
| `GOOGLE_PROJECT_ID` | Google Cloud project ID |
| `GOOGLE_PROJECT_NUMBER` | Google Cloud project number |

Also requires a service-account key mounted at
`/opt/app/rel/logflare/bin/gcloud.json`. Place it at `supabase/gcloud.json`
before installing — the installer checks for it and refuses to continue with the
BigQuery backend if it is missing.

Needs a project with **billing enabled** and BigQuery Admin (or the equivalent
minimum) permissions.

> **Never commit `gcloud.json` to version control.** It is covered by
> `.gitignore` and the Docker build context exclusions.

## Variables the installer owns

All in `supabase/.env`, written by `logflare_configure_supabase()` and
re-applied after every Supabase update so an upstream `.env.example` change
cannot silently revert them.

| Variable | Purpose |
|---|---|
| `LOGFLARE_SINGLE_TENANT` | `true` — no account creation; one implicit tenant |
| `LOGFLARE_SUPABASE_MODE` | `true` — seeds the Supabase log sources Studio expects |
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | Ingest token. vector authenticates with it. |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | Query/management token. Studio reads logs with it. |
| `LOGFLARE_DB_ENCRYPTION_KEY` | **Base64** key encrypting sensitive Logflare columns. Required in production. |
| `LOGFLARE_DB_ENCRYPTION_KEY_RETIRED` | Empty except during a key rotation. |
| `DOCKER_SOCKET_LOCATION` | Socket vector mounts to collect container logs. Defaults to `/var/run/docker.sock`; differs under rootless Docker and Podman. |

Both tokens and the encryption key are generated **once**, at installation, and
never rotated automatically. They must match on both sides — vector, Logflare
and Studio all read them from this same file (standalone mode copies them into
`logflare/.env`).

### Rotating the encryption key

Move the current value to `LOGFLARE_DB_ENCRYPTION_KEY_RETIRED`, put the new key
in `LOGFLARE_DB_ENCRYPTION_KEY`, restart, and clear the retired key once
Logflare has re-encrypted. The installer does not automate this.

## Health

Port 4000 is **not published to the host** — upstream restricts access to the
Kong gateway. `logflare_check()` therefore probes in layers:

1. an in-container HTTP request to `127.0.0.1:4000/health` (`curl`, then `wget`)
2. the host port, in case this deployment does publish it
3. Docker's own healthcheck verdict

A Logflare that is running but not answering is reported as a **warning**, not a
failure: degraded log aggregation should never take the application offline.

First boot is slow because Logflare runs its own database migrations — the
health check allows 180 seconds.

## Security

> **Logflare's `/dashboard` has no authentication of its own.** Access must be
> restricted at the network level. Do not publish port 4000 and do not proxy it
> to the internet. The installer prints this warning after every deployment.

## Disabling it

Answer *no* at install time, or set `ENABLE_LOGFLARE=false` in
`config/installer.env`. The phase is skipped and `status` reports it disabled.

To turn it off on a running installation:

```bash
cd /opt/sentinel-ops/supabase && sh run.sh config remove logs && sh run.sh start
```

## Troubleshooting

```bash
sentinel-ops logs logflare
sentinel-ops status              # mode, backend and health
```

**No logs in Studio.** Almost always a token mismatch or the Docker socket.
Confirm `LOGFLARE_PUBLIC_ACCESS_TOKEN` is identical everywhere it appears, and
that the socket exists:

```bash
grep DOCKER_SOCKET_LOCATION /opt/sentinel-ops/supabase/.env
ls -l /var/run/docker.sock
```

**Analytics service missing from `docker compose ps`.** The overlay is not
enabled. Check `COMPOSE_FILE`:

```bash
grep COMPOSE_FILE /opt/sentinel-ops/supabase/.env
# expect: docker-compose.yml:docker-compose.logs.yml
```

**Logflare restarting in a loop.** Usually the backend. For Postgres, confirm
the `_analytics` schema is reachable with the configured credentials. For
BigQuery, confirm `gcloud.json` is mounted, billing is enabled, and the service
account has BigQuery permissions.

**Errors about decrypting columns.** `LOGFLARE_DB_ENCRYPTION_KEY` changed after
data was written. Restore the previous key, or put it in
`LOGFLARE_DB_ENCRYPTION_KEY_RETIRED` and let Logflare re-encrypt.
