# Sentinel Ops — Installer & Deployment

A Linux-only installation and update system for the Sentinel Ops stack:
self-hosted **Supabase**, **Logflare**, and the **Sentinel Ops React frontend**,
all running under Docker.

A clean supported server plus a deployment key becomes a working Sentinel Ops
installation with one command, and every subsequent release ships with
`sentinel-ops update app`.

---

## Quick start

```bash
git clone <this-repo> sentinel-ops-installer
cd sentinel-ops-installer
cp /path/to/deploy_key ./deploy_key      # private SSH key for the app repo
chmod 600 ./deploy_key
sudo ./install.sh
```

After installation the `sentinel-ops` command is on `PATH`:

```bash
sentinel-ops                 # guided menu
sentinel-ops status          # what is actually running
sentinel-ops credentials     # generated Supabase credentials
```

Non-interactive (CI, image bakes):

```bash
sudo ./install.sh --yes
```

---

## Commands

| Command | What it does |
|---|---|
| `sentinel-ops` | Guided menu; detects whether an installation exists |
| `sentinel-ops install` | First installation |
| `sentinel-ops update app` | Update the application only *(the common case)* |
| `sentinel-ops update supabase` | Update Supabase only |
| `sentinel-ops update all` | Update Supabase, then the application |
| `sentinel-ops status` | Health and version of every component |
| `sentinel-ops credentials` | Show generated credentials (masked; `--show` to reveal) |
| `sentinel-ops backup [create\|list]` | Database backups |
| `sentinel-ops restore [backup]` | Restore a backup (latest if omitted) |
| `sentinel-ops rollback` | Roll the application back to the previous image |
| `sentinel-ops logs <target>` | `app`, `supabase`, `logflare`, `proxy`, `installer` |

Global options: `--dir <path>`, `--yes`, `--show`, `--force`, `--debug`.

---

## Supported systems

| Family | Distributions |
|---|---|
| Debian | Debian, Ubuntu (and derivatives via `ID_LIKE`) |
| RHEL | RHEL, CentOS, Fedora, Rocky, AlmaLinux |

The installer refuses to run anywhere else, and refuses to run on non-Linux
kernels. Prerequisites (`curl`, `git`, `openssl`, `jq`, `ssh`, Docker, Docker
Compose) are verified and installed when missing.

Docker is checked at three levels, because `docker --version` succeeding proves
nothing: the **binary** exists, the **daemon** answers, and a **container
actually runs**.

---

## Layout on the server

```
/opt/sentinel-ops/
├── bin/sentinel-ops         the CLI (symlinked to /usr/local/bin)
├── lib/                     installer modules
├── assets/                  Dockerfile / compose templates
├── config/
│   ├── installer.env        persisted configuration
│   ├── deploy_key           chmod 600, used only for Git
│   └── known_hosts          pinned Git host key
├── supabase/
│   ├── .env                 ← secrets and state; never regenerated
│   ├── docker-compose.yml
│   └── volumes/             database data, storage, edge functions
├── logflare/                standalone deployment (when not bundled)
├── app/                     the Sentinel Ops checkout
│   ├── .env                 generated from Supabase config
│   └── supabase/{migrations,functions}
├── backups/<timestamp>/     database.sql + metadata.txt
├── runtime/caddy/           reverse-proxy config
├── logs/                    installer logs
└── .state/                  deployed commit, image, versions, phase markers
```

---

## Runtime architecture

```
                Internet
                   │
                 Caddy            :80 / :443, automatic TLS
              ┌────┴─────┐
              ▼          ▼
         Supabase     Sentinel Ops
         Kong :8000   frontend :3000  (nginx, static bundle)
              │
              ▼
         PostgreSQL ──► Logflare / vector
```

Caddy is the only component bound to a public interface. The frontend and Kong
are published on `127.0.0.1` only, and everything talks over the Supabase Docker
network. Supabase's own Kong gateway is left in place rather than duplicated.

Caddy is optional — answer *no* at install time and the frontend binds to
`0.0.0.0:3000` for an existing proxy to sit in front of.

---

## What is safe across updates

`sentinel-ops update app` never touches Supabase's version, secrets,
configuration or volumes. `sentinel-ops update supabase` refreshes the
deployment scaffolding and images while preserving:

- `supabase/.env` — secrets are generated once and never regenerated
- `supabase/volumes/db/data` — the database
- `supabase/volumes/storage` — uploaded objects
- `supabase/volumes/functions` — deployed edge functions

A database backup is **mandatory** before a Supabase update; the update aborts
if the backup fails.

---

## Idempotency

Every expensive installation phase is guarded by a marker in `.state/phases/`.
If an install fails at the frontend build, fixing the problem and re-running
resumes from there: Supabase is not reinstalled, secrets are not regenerated,
volumes are not deleted and the repository is not re-cloned. `--force` re-runs
completed phases deliberately.

---

## Deployment safety

Application updates never destroy the running deployment before the replacement
is proven:

```
build new image (tagged :<git-sha>)
      ↓
verify it on a staging container
      ↓
run migrations, deploy functions
      ↓
swap the live container
      ↓
health check ──fail──► automatic rollback to the previous image
```

Images are tagged `sentinel-ops:<git-sha>` as well as `:latest`, so there is
always a known-good image to roll back to.

`sentinel-ops rollback` restores the previous image and commit. It deliberately
does **not** revert database migrations — silently reversing schema is more
destructive than leaving it — and names the relevant backup instead.

---

## Secrets

- Secrets are generated by Supabase's own setup, or by the installer on the
  fallback path. They are **never** requested from the operator.
- Nothing secret is printed during installation or written to installer logs.
  `sentinel-ops credentials` is the one disclosure point, masked by default.
- The **service-role key is never given to the frontend**. Only the publishable
  (anon) key reaches the build, because anything in a Vite bundle is shipped to
  the browser.
- `config/deploy_key` is `chmod 600`, used only via `GIT_SSH_COMMAND`, and
  excluded from the Docker build context.

---

## Frontend build

The default build mode is **`docker`**: `npm ci` and `npm run build` run inside
a multi-stage image, so the server needs no Node.js toolchain and the build is
reproducible. The runtime image is nginx serving the static bundle — no Node,
no source, no `node_modules`.

Set `FRONTEND_BUILD_MODE=host` to run `npm ci` / `npm run build` on the host and
package the resulting `dist/` instead. This requires Node.js on the server.

`assets/app/Dockerfile`, `nginx.conf` and `.dockerignore` belong in the
application repository. Until they are committed there, the installer copies its
own templates into the checkout; a `Dockerfile` already present in the repo
always wins.

---

## Development

```bash
./tests/run.sh
```

Runs shell syntax checks, a CRLF guard, shellcheck (when installed) and the unit
tests for the helpers that the deployment logic depends on.

> **Windows note:** these scripts must ship with LF endings. `.gitattributes`
> enforces this; `install.sh` also refuses to run a CRLF-contaminated checkout
> rather than failing with an unhelpful `bad interpreter` error.

---

## Further reading

- [docs/OPERATIONS.md](docs/OPERATIONS.md) — day-two runbook and troubleshooting
- [docs/LOGFLARE.md](docs/LOGFLARE.md) — the logging pipeline and its variables
- [docs/DECISIONS.md](docs/DECISIONS.md) — why the implementation deviates from
  the original plan where it does
