# Operations runbook

## Deploying a new application release

```bash
sentinel-ops update app
```

What happens, in order:

1. Verify the installation and that **Supabase is healthy** — nothing proceeds otherwise
2. Fetch and fast-forward the application checkout
3. Regenerate `app/.env` from the live Supabase configuration
4. Build the image, tagged `sentinel-ops:<git-sha>`
5. Back up the database
6. Apply pending migrations
7. Deploy edge functions
8. Verify the new image on a staging container, then swap the live one
9. Health-check; roll back automatically on failure
10. Record the deployed commit and image in `.state/`

Steps 1–4 make no changes to the running deployment. A build failure or an
inaccessible repository costs nothing.

### Ordering

The frontend is never considered deployed until the database and functions are
ready:

```
Supabase → migrations → edge functions → frontend image → frontend container
```

## Updating Supabase

```bash
sentinel-ops update supabase
```

Takes a **mandatory** backup first and aborts if it fails. Refreshes the
deployment files while preserving `.env`, the database, storage and the deployed
edge functions, re-applies the installer-owned configuration, pulls images,
restarts, health-checks, and verifies Logflare.

If the stack does not come back healthy, the failure message names the
pre-update backup directory.

## Backups

```bash
sentinel-ops backup create
sentinel-ops backup list
sentinel-ops restore 2026-09-11-121500     # or omit for the latest
```

Backups are taken automatically before the first migration run, before every
application update, before every Supabase update and before any restore.

```
/opt/sentinel-ops/backups/2026-09-11-121500/
├── database.sql      pg_dumpall --clean --if-exists (roles and all databases)
└── metadata.txt      timestamp, reason, Supabase version, app commit, image
```

The ten most recent are kept (`BACKUP_RETENTION`).

> `restore` replaces the current database contents. It takes a safety copy of
> the current state first, so a bad restore is still recoverable.

## Rolling back

```bash
sentinel-ops rollback
```

Restores the previous image and moves the checkout back to the previous commit.

**Migrations are not reverted.** If the release included a breaking schema
change, restore the matching backup explicitly — `rollback` prints its path.

## Troubleshooting

Always start here:

```bash
sentinel-ops status
```

| Symptom | Where to look |
|---|---|
| Install failed mid-way | `sentinel-ops logs installer`, then re-run — completed phases are skipped |
| Frontend not responding | `sentinel-ops logs app` |
| Supabase unhealthy | `sentinel-ops logs supabase` |
| TLS / routing not working | Your reverse proxy — see [REVERSE-PROXY.md](REVERSE-PROXY.md). Realtime needs WebSocket headers. |
| No logs in Studio | [docs/LOGFLARE.md](LOGFLARE.md) |

### "Supabase health check failed"

Installation stops rather than deploying an application against a broken
database. Common causes: insufficient memory (the stack wants ~4 GB), a port
already bound on 8000, or images that failed to pull.

```bash
cd /opt/sentinel-ops/supabase && docker compose ps
```

### "Cannot fast-forward … to origin/main"

The checkout at `/opt/sentinel-ops/app` was edited locally. The installer
refuses to discard that silently.

```bash
git -C /opt/sentinel-ops/app status
git -C /opt/sentinel-ops/app stash      # or reset --hard origin/main to discard
```

### "Cannot access …repository with the supplied deployment key"

```bash
GIT_SSH_COMMAND="ssh -i /opt/sentinel-ops/config/deploy_key -o IdentitiesOnly=yes" \
    git ls-remote git@github.com:BrainStation-23/sentinel-ops.git
```

Check the key is registered as a deploy key on the repository, and that it is
the private key rather than the `.pub`.

### A migration failed

Each migration runs in a single transaction together with the row recording it,
so a failure leaves neither partial schema changes nor a bogus tracking entry.
Fix the migration in the repository and re-run `sentinel-ops update app`;
already-applied migrations are skipped.

Tracking lives in `supabase_migrations.schema_migrations` — the same table the
Supabase CLI uses, so `supabase db push` stays compatible.

### Re-running a failed install

Just run it again. Phase markers in `.state/phases/` mean Supabase is not
reinstalled, secrets are not regenerated, volumes are not deleted and the
repository is not re-cloned.

```bash
sudo sentinel-ops install            # resume
sudo sentinel-ops install --force    # re-run completed phases too
```

## Changing configuration

Edit `/opt/sentinel-ops/config/installer.env`, then apply:

| Changed | Apply with |
|---|---|
| `SUPABASE_PUBLIC_URL`, `SITE_URL`, `API_EXTERNAL_URL` | `sentinel-ops update app` (rebuilds the bundle — these are baked in at build time) |
| `APP_BRANCH`, `APP_REPOSITORY` | `sentinel-ops update app` |
| `APP_BIND`, `APP_PORT` | `sentinel-ops update app` |
| `ENABLE_LOGFLARE` | `sentinel-ops install` (re-runs the analytics phase) |

Changing a URL requires a **rebuild**, not a restart: Vite inlines
`VITE_SUPABASE_URL` into the JavaScript bundle.

## Uninstalling

```bash
cd /opt/sentinel-ops/supabase && docker compose down      # keeps volumes
docker rm -f sentinel-ops-frontend
```

Add `-v` to `docker compose down` only if you intend to destroy the database.
Back up first.
