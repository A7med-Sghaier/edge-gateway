# Continuous deployment

`edge-gateway` deploys itself with a **GitHub Actions self-hosted runner** that lives
on each target server. Because the runner *is* the deploy target, there are no SSH
keys, deploy users, or remote secrets to manage — a push to `main` reloads the edge
in place, on every edge server, in parallel.

```
push to main ─▶ GitHub Actions ─▶ matrix: one job per edge server
                                     │
                                     ├─ validate + resolve every path variable
                                     ├─ rsync tracked files ─▶ $DEPLOY_DIR
                                     ├─ merge Traefik static config (repo + server overlay + ACME email)
                                     ├─ assemble env: server base + GitHub overlay ─▶ $RUNNER_TEMP
                                     ├─ render routes.yml + spa.conf from that env
                                     └─ docker compose up -d  (+ restart Traefik iff static config changed)
```

> **No concrete path appears in this repository.** Every location is supplied through
> a GitHub variable and referenced by name only — here, in the workflow, and in the
> scripts. A missing variable fails the job loudly rather than resolving to a guess.

## Directory responsibilities

Four distinct areas, configured per server. Keeping them separate is what makes the
deploy safe to re-run:

| Variable | Holds | Why it is separate |
| --- | --- | --- |
| `RUNNER_DIR` | the runner software | never a deploy target — a deploy that wrote here would delete the job running it |
| `DEPLOY_DIR` | synced application source | the `rsync --delete` destination; anything not tracked in git is removed |
| `RUNTIME_CONFIG_DIR` | server-managed config: the base `.env`, the compose override, the Traefik static overlay | lives **outside** `DEPLOY_DIR` so `rsync --delete` cannot destroy it |
| *(server state)* | `letsencrypt/`, generated `traefik/dynamic/*.yml`, `nginx/generated/` | inside `DEPLOY_DIR` but protected by rsync `--exclude`s |

The workflow validates all of this before touching the filesystem: required variables
present, paths absolute, `DEPLOY_DIR`/`RUNTIME_CONFIG_DIR` not overlapping `RUNNER_DIR`,
server config not inside `DEPLOY_DIR`, and the deploy user actually holding write on
`DEPLOY_DIR` and read on the base env file.

`RUNNER_DIR` is **discovered** rather than configured: the runner exports
`RUNNER_WORKSPACE`, whose grandparent is the install root. A hand-set variable protects
nothing once it drifts from the box, so it is optional — set it only to override.

## Configuration

### Repository variable

Set in **Settings → Actions → Variables → Repository**. It must be repository-scoped:
GitHub resolves `strategy` and `runs-on` *before* applying the job's `environment:`, so
an environment-scoped value expands to an empty string, the matrix collapses to nothing,
and **the job is never created** — the run shows no jobs and no error annotation.

| Variable | Value |
| --- | --- |
| `EDGE_SERVERS` | JSON array of runner labels, one per edge server, e.g. `["edge-a","edge-b"]` |

### `Prod` environment variables

Set in **Settings → Environments → Prod → Variables**:

| Variable | Required | Purpose |
| --- | --- | --- |
| `APP_NAME` | yes | names the merged env file inside `$RUNNER_TEMP` |
| `DEPLOY_DIR` | yes | rsync destination (absolute) |
| `RUNTIME_CONFIG_DIR` | yes | server-managed config dir (absolute, outside `DEPLOY_DIR`) |
| `COMPOSE_PROJECT_NAME` | yes | compose project name for this edge |
| `RUNNER_DIR` | no | overrides the value discovered from `RUNNER_WORKSPACE` |
| `COMPOSE_ENV` | no | pins the base env file; defaults to `$RUNTIME_CONFIG_DIR/.env` |
| `COMPOSE_OVERRIDE` | no | pins the compose override; defaults to `$RUNTIME_CONFIG_DIR/docker-compose.override.yml` |
| `DASHBOARD_HOST` | no | hostname for the Traefik dashboard; empty disables it |

Pinning `COMPOSE_OVERRIDE` makes it **mandatory** — if the file is then missing, the
deploy fails instead of silently bringing Traefik up on `web` only, which 504s every
labelled backend on an app data-plane network. Left unset, a missing override is
tolerated and the base compose is used alone.

### `Prod` environment secrets

| Secret | Purpose |
| --- | --- |
| `ACME_EMAIL` (or `TRAEFIK_EMAIL`) | Let's Encrypt contact for expiry notices |
| `DASHBOARD_AUTH` | htpasswd hash for dashboard basic auth |

The ACME address is **format-validated**, not merely checked for presence: Let's Encrypt
rejects a contact it cannot parse, which fails account registration and disables issuance
and renewal for *every* host on the box. Certificates already in `acme.json` keep being
served, so the breakage stays invisible until a renewal falls due. An unparseable value
is therefore ignored with a warning — an anonymous ACME account issues and renews fine —
rather than failing the deploy and leaving the previous config running.

## How the runtime environment is assembled

**CI never writes the server's env file.** The file compose actually reads is built
fresh for each job and thrown away with it:

1. **Base** — the server-managed env file, copied *verbatim*. It carries this server's
   `ROUTE_*` / `APP_*` / `TCP_*` blocks, stays root-owned, and the job needs only read
   access. Manual edits on the server are preserved, because CI never touches it.
2. **Overlay** — GitHub secrets and variables appended *after* the base, so they win:
   compose takes the **last** occurrence of a duplicate key.
3. **Destination** — `$RUNNER_TEMP/$APP_NAME.env`, `umask 077` + `chmod 0600`, passed as
   `--env-file`. `RUNNER_TEMP` is wiped when the job ends, so the one place both layers
   meet on disk does not persist.

Three rules the overlay enforces, each of which has silently broken a deploy before:

- An unset value is **skipped**, never written as `NAME=` — that would override the
  inherited base value with an empty string.
- `$` is escaped to `$$`. Compose interpolates `--env-file` contents, so an unescaped
  `$` silently *truncates* the value at that point (`a$b` arrives as `a`).
- A value containing a newline is **rejected** — it splits across two lines and corrupts
  everything after it.

## How the Traefik static config is produced

Traefik's static-configuration sources are **mutually exclusive** (file → flags → env,
first one wins) and it reads exactly **one** file. While `traefik/traefik.yml` is
mounted, every `TRAEFIK_*` environment variable and `command:` flag is read by nothing.
So per-server entrypoints and the ACME email cannot be injected — they have to be merged
into that single file:

```
repo traefik/traefik.yml
  + $RUNTIME_CONFIG_DIR/traefik.override.yml   (per-server, deep-merged, read-only to the job)
  + the ACME email secret
  ─────────────────────────────────────────────
  = the synced copy Traefik loads
```

Mappings merge key-by-key; scalars and lists are replaced wholesale. The result is
written into `DEPLOY_DIR`, which the next rsync overwrites from the repo base — so the
merge is recomputed every run and never drifts.

Traefik reads static config **only at startup**, and `up -d` does not recreate a
container just because a bind-mounted file changed underneath it. The deploy therefore
checksums the rendered file, keeps the previous checksum beside it (excluded from the
sync), and restarts Traefik itself when it changed — but only if compose did not already
recreate the container, since an unnecessary restart drops every live connection through
the edge. The checksum is recorded only *after* the restart succeeds, so a failed deploy
leaves the change pending for the next run.

## Deploying

Push to `main` touching `docker-compose.yml`, `traefik/**`, `scripts/**`, or the workflow
itself — or run **Deploy edge-gateway** manually (`workflow_dispatch`). Each job:

1. Resolves and validates every path variable.
2. Syncs tracked files with `rsync --delete`, excluding `.env`, the compose override,
   `letsencrypt/`, the rendered `traefik/dynamic/*.yml`, and `nginx/generated/`.
3. Merges the Traefik static config and checksums it.
4. Assembles the runtime env into `$RUNNER_TEMP`.
5. Validates Docker access and `docker compose config --quiet`.
6. Creates any external network the merged config declares but the host lacks —
   discovered from the config, not hardcoded, so it self-heals after a `docker network prune`.
7. Renders `routes.yml` + `spa.conf`, runs `up -d`, restarts Traefik only if needed, and
   reloads the `edge-spa` nginx.
8. Verifies Traefik actually joined every network its config declares — the guard for the
   incident where the override failed to merge and every labelled backend 504'd.

Concurrency is per server, so two deploys of the same edge never overlap while different
servers still deploy in parallel. `fail-fast: false` keeps one failing server from
aborting the others.

## Installing a runner on a new server

```bash
git clone https://github.com/A7med-Sghaier/edge-gateway.git
cd edge-gateway
RUNNER_DIR=<runner install dir> DEPLOY_DIR=<deploy dir> \
  ./scripts/install-runner.sh https://github.com/A7med-Sghaier/edge-gateway <registration-token>
```

Get `<registration-token>` from **Settings → Actions → Runners → New self-hosted runner**
(the value after `--token`; it expires in about an hour). Run it as a normal sudo-capable
user, never root — GitHub's runner refuses to configure as root.

The script requires `RUNNER_DIR` and `DEPLOY_DIR` explicitly and refuses to guess them:
a wrong deploy dir is not a visible mistake, and a deploy dir *inside* the runner
installation would have `rsync --delete` destroy the runner. It registers with the labels
`self-hosted,edge-gateway` (override with `RUNNER_LABELS`) and installs a systemd service
that survives reboots.

Then, before the first deploy: add this server's label to the `EDGE_SERVERS` repository
variable, create the runtime config dir with its base `.env`, and
`docker network create web`.

## Rollback

Revert the offending commit and push — the runner redeploys the previous state. The base
`.env`, the per-server overlays, and issued certificates are untouched, so recovery is
just another deploy.
