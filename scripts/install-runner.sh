#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-runner.sh — install a GitHub Actions self-hosted runner on THIS server
# and register it as a systemd service, so pushes to `main` auto-deploy the edge.
#
# The runner runs ON the target server, so deploys need no SSH keys or secrets:
# the deploy workflow just syncs the repo and runs `docker compose up -d` locally.
#
# Usage (run as a normal, non-root user that can sudo and use Docker):
#   ./scripts/install-runner.sh <repo-url> <registration-token>
#
#   <repo-url>            https://github.com/<owner>/<repo>   (edge-gateway repo)
#   <registration-token>  short-lived token from the repo UI:
#                         Settings → Actions → Runners → New self-hosted runner
#                         (copy the value after `--token` in the shown command)
#
# Optional env overrides:
#   RUNNER_DIR    install location            (default $RUNNER_DIR)
#   DEPLOY_DIR    where the edge is deployed  (default $DEPLOY_DIR)
#   RUNNER_NAME   runner name in GitHub UI    (default edge-<hostname>)
#   RUNNER_LABELS extra labels, comma-sep     (default self-hosted,edge-gateway)
#   RUNNER_VERSION pin a version              (default: latest release)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="${1:-}"
REG_TOKEN="${2:-}"

RUNNER_DIR="${RUNNER_DIR:-$RUNNER_DIR}"
DEPLOY_DIR="${DEPLOY_DIR:-$DEPLOY_DIR}"
RUNNER_NAME="${RUNNER_NAME:-edge-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,edge-gateway}"
RUNNER_USER="$(id -un)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$REPO_URL" ]  || die "missing <repo-url> (arg 1)"
[ -n "$REG_TOKEN" ] || die "missing <registration-token> (arg 2)"
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
echo "→ Preparing deploy dir $DEPLOY_DIR (owner $RUNNER_USER)…"
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
echo "→ Installing runner v${RUNNER_VERSION} (${RUNNER_ARCH}) into $RUNNER_DIR…"
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
  1. cp $DEPLOY_DIR/.env.example $DEPLOY_DIR/.env   # after the first deploy syncs files,
     \$EDITOR $DEPLOY_DIR/.env                        # OR create it now if files exist
     (set ACME_EMAIL, any ROUTE_* / DASHBOARD_* values — this file is NEVER overwritten)
  2. docker network create web           # + any data-plane net your apps use
  3. Push to 'main' (or run the workflow manually) to trigger a deploy.

The deploy workflow keeps $DEPLOY_DIR/.env and $DEPLOY_DIR/letsencrypt/ safe across
deploys — only tracked files are synced.
EOF
