# Continuous deployment

`edge-gateway` deploys itself with a **GitHub Actions self-hosted runner** that lives
on the target server. Because the runner *is* the deploy target, there are no SSH keys,
deploy users, or remote secrets to manage — a push to `main` reloads the edge in place.

```
push to main ──▶ GitHub Actions ──▶ self-hosted runner (on the server)
                                        │
                                        ├─ rsync tracked files ─▶ $DEPLOY_DIR
                                        ├─ render routes.yml from .env
                                        └─ docker compose up -d   (Traefik hot-reloads)
```

## 1. Install the runner on the server (one-time)

On the server, as a normal sudo-capable user (not root) that can use Docker:

```bash
git clone https://github.com/<owner>/edge-gateway.git
cd edge-gateway
./scripts/install-runner.sh https://github.com/<owner>/edge-gateway <registration-token>
```

Get `<registration-token>` from the repo UI: **Settings → Actions → Runners → New
self-hosted runner** (it's the value after `--token` in the generated command; it
expires in ~1 hour). The script downloads the latest runner, registers it with the
labels `self-hosted,edge-gateway`, and installs it as a systemd service that survives
reboots.

## 2. Provision server-only state (one-time)

These files live in the deploy dir (`$DEPLOY_DIR` by default) and are **never**
overwritten by a deploy:

```bash
cd $DEPLOY_DIR
cp .env.example .env && $EDITOR .env   # set ACME_EMAIL, ROUTE_* / DASHBOARD_* as needed
docker network create web              # + any data-plane network your apps attach to
```

## 3. Deploy

Push to `main` (touching `docker-compose.yml`, `traefik/**`, or `scripts/**`) or run the
**Deploy edge-gateway** workflow manually (`workflow_dispatch`). Each run:

1. Syncs tracked files into `$DEPLOY_DIR` with `rsync --delete`, excluding
   `.env`, `letsencrypt/`, and the rendered `traefik/dynamic/*.yml`.
2. Re-renders `routes.yml` from `.env` via the `route-generator` service.
3. Runs `docker compose up -d`. Traefik hot-reloads dynamic config; it only restarts
   when the compose file or its static config actually changes.

## Configuration

| Setting | How to override | Default |
| --- | --- | --- |
| Deploy directory | repo variable `DEPLOY_DIR` (Settings → Actions → Variables) | `$DEPLOY_DIR` |
| Runner install dir | `RUNNER_DIR` env when running the script | `$RUNNER_DIR` |
| Runner labels | `RUNNER_LABELS` env when running the script | `self-hosted,edge-gateway` |

> The workflow targets the runner by the `[self-hosted, edge-gateway]` label pair, so
> you can run multiple edge servers off the same repo by giving each its own runner
> with a distinct extra label and a matching `runs-on`.

## Rollback

Revert the offending commit and push — the runner redeploys the previous state.
`.env` and issued certificates are untouched, so recovery is just another deploy.
