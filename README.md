# Sentinel Ops — Installer & Deployment

A Linux-only installation and update system for the Sentinel Ops stack:
self-hosted **Supabase**, **Logflare**, and the **Sentinel Ops React frontend**,
all running under Docker.

A clean supported server plus a deployment key becomes a working Sentinel Ops
installation with one command, and every subsequent release ships with
`sentinel-ops update app`.

---

## Quick start

Before you begin you need an **SSH deploy key** for the private Sentinel Ops
application repository, and DNS for your two hostnames already pointing at this
server. See [Before you install](#before-you-install).

### One-liner

Run this from a directory containing your `deploy_key`:

```bash
curl -fsSL https://raw.githubusercontent.com/tanjil-al-mahmud/SentinelOPS-Installer-and-Deployment/main/install.sh | sudo bash
```

It downloads the installer, reattaches your terminal so the guided prompts still
work, and starts the installation.

### From a clone

```bash
git clone https://github.com/tanjil-al-mahmud/SentinelOPS-Installer-and-Deployment.git
cd SentinelOPS-Installer-and-Deployment
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

### Non-interactive (CI, image bakes)

```bash
sudo ./install.sh --yes
```

`--yes` accepts every default, **including the placeholder `*.example.com`
domains**. Write `config/installer.env` first, or install once interactively and
copy that file to the next server.

---

## Before you install

**Server:** Ubuntu 22.04/24.04, Debian, or RHEL/CentOS/Fedora. At least **4 GB
RAM** — the Supabase stack runs a dozen containers — and 20 GB of disk. Root or
sudo.

**Deploy key.** The application repository is private. Register an SSH deploy key
on it and put the **private** key (not the `.pub`) where the installer looks:

```
./deploy_key                        next to the installer, or the directory you run it from
/opt/sentinel-ops/deploy_key
/opt/sentinel-ops/config/deploy_key
```

```bash
chmod 600 deploy_key
```

Place it **before** running — it is needed partway through, after Supabase comes
up.

**DNS.** Point both hostnames at this server before installing, so your reverse
proxy can obtain certificates:

```bash
dig +short app.example.com
dig +short supabase.example.com
```

**Firewall.** Nothing in this stack should be publicly exposed except through
your reverse proxy:

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> Supabase's compose file publishes Kong on `0.0.0.0:8000`. The `default deny
> incoming` rule above is what keeps it off the internet — do not skip it.

**Reverse proxy.** The installer does not install one. Point yours at the
upstreams it prints — see [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md).

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
| `sentinel-ops logs <target>` | `app`, `supabase`, `logflare`, `installer` |

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
├── logflare/                standalone deployment (fallback only)
├── app/                     the Sentinel Ops checkout
│   ├── .env                 generated from Supabase config
│   └── supabase/{migrations,functions}
├── backups/<timestamp>/     database.sql + metadata.txt
├── logs/                    installer logs
└── .state/                  deployed commit, image, versions, phase markers
```

---

## Runtime architecture

```
                Internet
                   │
                   ▼
          your reverse proxy          ← you manage this
              ┌────┴─────┐
              ▼          ▼
      127.0.0.1:8000   127.0.0.1:3000
      Supabase Kong    Sentinel Ops frontend
              │        (nginx, static bundle)
              ▼
         PostgreSQL ──► Logflare / vector
```

**No reverse proxy is installed.** TLS, certificates and routing stay with the
host, to be handled however that host already does it. The installer's job is to
expose two stable upstreams and tell you what they are:

| Upstream | Default |
|---|---|
| Frontend | `127.0.0.1:3000` |
| Supabase API (Kong) | `127.0.0.1:8000` |

Both bind to **loopback only** (`APP_BIND`), so a proxy on this host reaches
them and the public internet does not. Supabase's own Kong gateway is left in
place rather than duplicated.

See [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) for nginx, Caddy and Traefik
examples, and the WebSocket/upload-size gotchas worth knowing about.

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

## Analytics (Logflare)

Deployed via Supabase's own optional overlay (`run.sh config add logs`), which
adds the **analytics** and **vector** services. Two backends are offered at
install time: `postgres` (default, no extra services) and `bigquery` (upstream's
production recommendation, needs a Google Cloud project and a service-account
key).

Tokens and the base64 `LOGFLARE_DB_ENCRYPTION_KEY` are generated once and
re-applied after every Supabase update. Port 4000 is never published — Logflare's
dashboard has no authentication of its own.

Full detail in [docs/LOGFLARE.md](docs/LOGFLARE.md).

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

## Updating the installer itself

The one-liner always installs whatever is on `main`. To install from a branch:

```bash
SENTINEL_OPS_INSTALLER_BRANCH=my-branch   curl -fsSL https://raw.githubusercontent.com/tanjil-al-mahmud/SentinelOPS-Installer-and-Deployment/my-branch/install.sh | sudo -E bash
```

`sudo -E` preserves the variable. On an existing server, pulling a newer
installer and re-running `sudo ./install.sh` is safe — completed phases are
skipped.

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
- [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) — upstreams and example proxy configs
- [docs/LOGFLARE.md](docs/LOGFLARE.md) — analytics setup, backends and variables
- [docs/DECISIONS.md](docs/DECISIONS.md) — why the implementation deviates from
  the original plan where it does
