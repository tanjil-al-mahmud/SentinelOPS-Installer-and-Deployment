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

## 6. Logflare has two modes

**Plan:** Logflare is deployed separately because the default Supabase setup
does not include it.

**Implementation:** the installer checks. Recent Supabase releases *do* ship an
`analytics` service; older ones do not. Deploying a second Logflare next to an
existing one would give two instances competing for the same `_analytics`
schema.

So: configure the bundled service when present, deploy a standalone overlay when
not. Either way the Supabase-side variables are the same, and they are
documented in [LOGFLARE.md](LOGFLARE.md).

---

## 7. Caddy is optional and TLS is conditional

**Plan:** Caddy in front of Supabase and the frontend.

**Implementation:** as planned, but declinable at install time, and automatic
HTTPS is only requested for a hostname that could plausibly get a certificate.

`localhost`, bare IP addresses, `.local` and the placeholder `*.example.com`
domains get plain HTTP instead. Otherwise a default-domain install would hang on
an ACME challenge that can never succeed. When Caddy is declined, the frontend
binds `0.0.0.0` for an existing proxy to sit in front of; with Caddy it binds
loopback only.

Supabase's Kong gateway is left exactly as it is — Caddy only terminates TLS and
routes the two hostnames.

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
