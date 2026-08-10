#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-runner.sh — install a GitHub Actions self-hosted runner on THIS server
# and register it as a systemd service, so pushes to `main` auto-deploy the edge.
#
# The runner runs ON the target server, so deploys need no SSH keys or secrets:
# the deploy workflow just syncs the repo and runs `docker compose up -d` locally.
#
# Usage (run as a normal, non-root user that can sudo and use Docker):
#   RUNNER_DIR=… DEPLOY_DIR=… ./scripts/install-runner.sh <repo-url> <registration-token>
#
#   <repo-url>            https://github.com/<owner>/<repo>   (edge-gateway repo)
#   <registration-token>  short-lived token from the repo UI:
#                         Settings → Actions → Runners → New self-hosted runner
#                         (copy the value after `--token` in the shown command)
#
# Required env (absolute paths; deliberately NOT defaulted — a guessed location
# would silently install the runner or deploy the edge somewhere nobody expects,
# and these must be two SEPARATE directories):
#   RUNNER_DIR    where the runner software is installed
#   DEPLOY_DIR    where the edge is deployed (must match the DEPLOY_DIR variable
#                 in the workflow's Prod environment)
#
# Optional env overrides:
#   RUNNER_NAME   runner name in GitHub UI    (default edge-<hostname>)
#   RUNNER_LABELS extra labels, comma-sep     (default self-hosted,edge-gateway)
#   RUNNER_VERSION pin a version              (default: latest release)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="${1:-}"
REG_TOKEN="${2:-}"

RUNNER_DIR="${RUNNER_DIR:-}"
DEPLOY_DIR="${DEPLOY_DIR:-}"
RUNNER_NAME="${RUNNER_NAME:-edge-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,edge-gateway}"
RUNNER_USER="$(id -un)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$REPO_URL" ]  || die "missing <repo-url> (arg 1)"
[ -n "$REG_TOKEN" ] || die "missing <registration-token> (arg 2)"
[ -n "$RUNNER_DIR" ] || die "RUNNER_DIR is not set — export it as an absolute path (where the runner software goes)"
[ -n "$DEPLOY_DIR" ] || die "DEPLOY_DIR is not set — export it as an absolute path (where the edge is deployed)"
case "$RUNNER_DIR" in /*) ;; *) die "RUNNER_DIR must be an absolute path" ;; esac
case "$DEPLOY_DIR" in /*) ;; *) die "DEPLOY_DIR must be an absolute path" ;; esac
# The deploy rsyncs --delete into DEPLOY_DIR. If that sits inside the runner
# installation, a deploy wipes the runner out from under the job running it.
case "$DEPLOY_DIR" in
  "$RUNNER_DIR"|"$RUNNER_DIR"/*)
    die "DEPLOY_DIR must not be inside RUNNER_DIR — the deploy's rsync --delete would destroy the runner installation" ;;
esac
[ "$(id -u)" -ne 0 ] || die "do NOT run as root — GitHub's runner refuses to configure as root. Use a normal sudo-capable user."
command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Engine + compose plugin first"
command -v curl >/dev/null 2>&1  || die "curl not found"

# ── Ensure the runner user can drive Docker ──────────────────────────────────
if ! docker info >/dev/null 2>&1; then
  echo "→ Adding $RUNNER_USER to the docker group (log out/in afterwards if this is new)…"
  sudo usermod -aG docker "$RUNNER_USER"
  echo "  NOTE: group change needs a fresh login. Re-run this script after re-logging in,"
  echo "        or the runner service (installed below) will still work as it re-reads groups."
fi

# ── Persistent deploy dir (owned by the runner user, so the workflow needs no sudo) ──
echo "→ Preparing the deploy dir (owner $RUNNER_USER)…"
sudo mkdir -p "$DEPLOY_DIR"
sudo chown -R "$RUNNER_USER":"$RUNNER_USER" "$DEPLOY_DIR"

# ── Resolve runner version + arch ────────────────────────────────────────────
if [ -z "${RUNNER_VERSION:-}" ]; then
  echo "→ Resolving latest runner version…"
  RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 | sed -E 's/.*"v([^"]+)".*/\1/')"
fi
[ -n "$RUNNER_VERSION" ] || die "could not resolve runner version (set RUNNER_VERSION=x.y.z)"

case "$(uname -m)" in
  x86_64|amd64)  RUNNER_ARCH=x64 ;;
  aarch64|arm64) RUNNER_ARCH=arm64 ;;
  *) die "unsupported CPU arch: $(uname -m)" ;;
esac

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

# ── Download + extract ───────────────────────────────────────────────────────
echo "→ Installing runner v${RUNNER_VERSION} (${RUNNER_ARCH})…"
sudo mkdir -p "$RUNNER_DIR"
sudo chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [ ! -x "./config.sh" ]; then
  curl -fsSL -o "$TARBALL" "$URL"
  tar xzf "$TARBALL"
  rm -f "$TARBALL"
fi

# ── Register (idempotent: --replace re-registers a same-named runner) ────────
echo "→ Registering with $REPO_URL as '$RUNNER_NAME' [$RUNNER_LABELS]…"
./config.sh \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "_work" \
  --unattended \
  --replace

# ── Install + start as a systemd service (survives reboots) ──────────────────
echo "→ Installing systemd service…"
sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start
sudo ./svc.sh status || true

cat <<EOF

✓ Runner installed and running as a service.

Next steps on this server (one-time, before the first auto-deploy):
  1. Create the runtime config dir (RUNTIME_CONFIG_DIR in the workflow's Prod
     environment — it must live OUTSIDE the deploy dir, which the deploy syncs
     with rsync --delete) and put this server's base .env there: copy
     .env.example from the repo and set the ROUTE_* / APP_* / TCP_* blocks.
     Credentials belong in GitHub Secrets, not in that file.
  2. docker network create web           # + any data-plane net your apps use
  3. Set the Prod environment variables (APP_NAME, DEPLOY_DIR,
     RUNTIME_CONFIG_DIR, COMPOSE_PROJECT_NAME) and the EDGE_SERVERS repository
     variable — see docs/continuous-deployment.md.
  4. Push to 'main' (or run the workflow manually) to trigger a deploy.

The deploy keeps the letsencrypt/ store and the generated config in the deploy
dir safe across runs — only tracked files are synced.
EOF
