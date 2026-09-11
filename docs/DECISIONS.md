# Implementation decisions

Where the implementation departs from the original plan, and why. Each of these
is a deliberate choice, not an omission.

---

## 1. Edge functions are deployed by syncing the runtime volume

**Plan:** `deploy_functions()` deploys everything under `supabase/functions/`.

**Implementation:** the functions are copied into
`supabase/volumes/functions/` and the edge-runtime container is recreated.

`supabase functions deploy` targets the **hosted** Supabase platform — it
expects a project ref and an access token, and has nothing to deploy to on a
self-hosted stack. Self-hosted, the `edge-runtime` container serves whatever is
mounted at `volumes/functions`, so syncing that directory *is* the deployment.

Details worth knowing:

- Functions removed from the repository are removed from the deployment.
- The `main` bootstrap function that the stack ships is infrastructure, not
  application code, and is preserved.
- Directories beginning with `_` (e.g. `_shared`) are copied but not counted as
  functions.
- The runtime is verified to still be running afterwards — a syntax error in a
  function can stop it booting, which would otherwise pass silently.

---

## 2. Migrations are applied with psql, not the Supabase CLI

**Plan:** detect applied migrations, apply pending ones, fail safely.

**Implementation:** exactly that, via `psql` inside the database container,
tracking state in `supabase_migrations.schema_migrations`.

This is the same table the Supabase CLI uses, so a database migrated by this
installer stays compatible with `supabase db push` and vice versa. Using psql
directly avoids adding the CLI as a prerequisite — one less versioned binary to
install, pin and keep working on five distributions.

Each migration is applied in a **single transaction together with the row that
records it**, so a failure can leave neither half-applied schema nor a tracking
entry for a migration that did not run.

---

## 3. The frontend is built inside Docker by default

**Plan:** step 19 `npm ci`, step 20 `npm run build`, step 21 build the Docker
image. The plan also states a multi-stage build is preferred.

**Implementation:** multi-stage by default — `npm ci` and `npm run build` run
*inside* stage 1 of the image build.

These two readings conflict, and the multi-stage one is better:

- the server needs **no Node.js toolchain at all**
- the build cannot be contaminated by whatever Node version the host happens to
  have
- Docker layer caching makes dependency installs free when only source changed

The host path is still available via `FRONTEND_BUILD_MODE=host`, which runs
`npm ci` / `npm run build` on the server and packages the resulting `dist/`. The
Dockerfile supports both through a `BUILD_MODE` build argument.

---

## 4. The Dockerfile ships with the installer

**Plan:** Phase 5 adds `Dockerfile` and `.dockerignore` to the Sentinel Ops
application repository.

**Implementation:** they live in `assets/app/` and are copied into the checkout
when it does not already contain them. A `Dockerfile` present in the repository
always takes precedence.

The application repository is a separate repository that this installer only has
read access to, so the files cannot be committed there from here. **These
templates should be moved into the application repository** — at that point the
installer will simply use them and stop copying anything.

---

## 5. Supabase installation has a fallback path

**Plan:** `curl -fsSL https://supabase.link/setup.sh | sh`.

**Implementation:** that first. If the script is unreachable or produces no
usable deployment, the installer falls back to a sparse checkout of the
`docker/` directory from the Supabase repository.

A single unreachable URL should not make a fresh install impossible. On the
fallback path the setup script's secret generation is missing, so the installer
generates the secrets itself — including signing the `anon` and `service_role`
JWTs with HS256 against the generated `JWT_SECRET`. Those are unit-tested in
`tests/test_secrets.sh`.

Secrets are only ever generated when absent or still at an upstream
placeholder. Regenerating `JWT_SECRET` on an existing installation would
invalidate every issued token and lock all users out.

---

## 6. Logflare uses Supabase's own optional overlay

**Plan:** Logflare is deployed separately because the default Supabase setup does
not include it.

**Implementation:** correct — it is not in the base stack — but upstream already
provides the mechanism for adding it, and reimplementing that would have been a
mistake.

Per the [self-hosting analytics
reference](https://supabase.com/docs/reference/self-hosting-analytics/introduction),
`run.sh config add logs` layers `docker-compose.logs.yml` onto the base stack and
starts two services: **analytics** (Logflare) and **vector** (log collection). The
installer uses that path when `run.sh` exists, falls back to setting
`COMPOSE_FILE` itself, then to a bundled `analytics` service, and only deploys its
own compose file when upstream ships none of the above.

Three things this surfaced that the original plan did not account for:

- **`LOGFLARE_DB_ENCRYPTION_KEY`** is a required base64 key encrypting sensitive
  Logflare columns. It was missing from the first implementation. It is now
  generated once, unit-tested for round-trip integrity through the env file, and
  re-applied after Supabase updates.
- **Port 4000 is not published.** Upstream restricts access to the Kong gateway,
  so the health check probes from inside the container rather than via
  `localhost:4000`.
- **The dashboard has no authentication.** The installer warns about this after
  every deployment, and the reverse-proxy guide says not to expose it.

A backend choice was also added, because upstream is explicit that the Postgres
backend "is not optimized for high-volume inserts or heavy querying" and
recommends BigQuery for production. `postgres` remains the default since it needs
nothing provisioned.

---

## 7. No reverse proxy is installed

**Plan:** Caddy in front of Supabase and the frontend.

**Implementation:** removed entirely. TLS termination, certificates and routing
belong to the host, which usually already has a proxy, a certificate workflow and
opinions about both. Installing a second one that binds :80 and :443 would
conflict with whatever is already there.

What the installer owns instead is a stable contract: the frontend on
`APP_BIND:APP_PORT` (default `127.0.0.1:3000`) and Supabase Kong on
`127.0.0.1:8000`, both loopback-bound so nothing is publicly exposed by accident.
`sentinel-ops status` and the post-install summary print both, and
[REVERSE-PROXY.md](REVERSE-PROXY.md) carries worked nginx, Caddy and Traefik
configurations plus the two failure modes that actually bite — missing WebSocket
headers breaking Realtime, and nginx's 1 MB body limit rejecting Storage uploads.

Supabase's Kong gateway is untouched. It was never the thing that needed
replacing.

---

## 8. `app/.env` is not passed to the container with `--env-file`

The plan's format for `app/.env` quotes its values
(`SUPABASE_URL="https://..."`). Docker's `--env-file` does **not** strip quotes,
so the container would receive a value with literal `"` characters around it.

The file is written in the specified format — it is what the application's own
tooling reads — and the container's runtime environment is passed explicitly
with `-e` instead. The client-side Supabase settings are not needed at runtime
anyway: Vite inlines them into the bundle at build time.

This is also why changing a URL requires a rebuild rather than a restart.

---

## 9. Additional commands

`restore` and `logs` are not in the planned CLI. Both proved necessary while
building the rest: a backup mechanism with no restore path is not a backup
mechanism, and `status` telling you something is unhealthy is only useful if you
can then read that component's logs.

---

## 10. Rollback does not revert the database

`sentinel-ops rollback` restores the previous image and commit, and leaves the
schema alone.

Reverting migrations automatically would mean either running unknown `down`
migrations or restoring a whole-database backup — silently discarding every
write since the deployment. Rolling application code back onto a slightly newer
schema is usually fine; silently destroying data is never fine. The command
prints the relevant backup path so the operator can make that call explicitly.
