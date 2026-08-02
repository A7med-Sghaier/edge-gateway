#!/bin/sh
# Renders edge-gateway config from env vars.
#   arg 1  Traefik file-provider dynamic config   (default /out/routes.yml)
#   arg 2  nginx config for the dockerized edge-spa SPA server (optional)
# POSIX sh (runs on Alpine/busybox).
#
# ── ROUTE_* : label-less apps proxied straight by Traefik ─────────────────────
#   ROUTE_1_NAME=dashboard                             # unique router/service id
#   ROUTE_1_HOSTS=dash.example.com,app.example.com     # comma-separated hostnames
#   ROUTE_1_SERVICE=http://dashboard:8080              # backend url (container or external)
#   ROUTE_1_TLS=true                                   # optional, default true
#   ROUTE_1_ENTRYPOINTS=websecure                      # optional, default websecure
#
# ── APP_* : static SPAs served by the dockerized edge-spa nginx ───────────────
# Each block renders (a) nginx server block(s) rooted at the on-host build dir
# (bind-mounted /var/www) and (b) Traefik routers: a web/admin router → edge-spa,
# and — when APP_N_API is set — an /api + /socket.io router → that API
# backend, with the CORS middleware Traefik answers preflights from.
#   APP_1_NAME=example-app                              # unique id
#   APP_1_WEB_HOSTS=example-app.example.com,www.example-app.example.com
#   APP_1_WEB_ROOT=/var/www/example-app/web/html        # served build dir
#   APP_1_ADMIN_HOSTS=admin.example-app.example.com     # optional
#   APP_1_ADMIN_ROOT=/var/www/example-app/admin/html    # optional (required if ADMIN_HOSTS set)
#   APP_1_API=http://host.docker.internal:8080         # optional (adds api + socket.io + CORS)
#
# ── Optional Traefik dashboard ────────────────────────────────────────────────
#   DASHBOARD_HOST=traefik.example.com
#   DASHBOARD_AUTH=admin:$apr1$....   # htpasswd hash (from `htpasswd -nb admin secret`)

set -eu

OUT="${1:-/out/routes.yml}"
SPA_OUT="${2:-}"

# Accumulate each section separately so the final routes.yml only contains an
# `http:` block when there's something in it. A bare `http:` with null children
# makes Traefik reject the whole file ("http cannot be a standalone element") AND
# drop every other route in the file-provider directory with it.
ROUTERS="$(mktemp)"
MIDDLEWARES="$(mktemp)"
SERVICES="$(mktemp)"
NGINX="$(mktemp)"
trap 'rm -f "$ROUTERS" "$MIDDLEWARES" "$SERVICES" "$NGINX"' EXIT

# build_hostrule "a.com, b.com" -> Host(`a.com`) || Host(`b.com`)
build_hostrule() {
  _rule=""
  _oldIFS=$IFS
  IFS=','
  for _h in $1; do
    _h=$(printf '%s' "$_h" | tr -d ' ')
    [ -z "$_h" ] && continue
    if [ -z "$_rule" ]; then
      _rule="Host(\`$_h\`)"
    else
      _rule="$_rule || Host(\`$_h\`)"
    fi
  done
  IFS=$_oldIFS
  printf '%s' "$_rule"
}

# build_servernames "a.com, b.com" -> " a.com b.com"  (leading space, for nginx)
build_servernames() {
  _out=""
  _oldIFS=$IFS
  IFS=','
  for _h in $1; do
    _h=$(printf '%s' "$_h" | tr -d ' ')
    [ -z "$_h" ] && continue
    _out="$_out $_h"
  done
  IFS=$_oldIFS
  printf '%s' "$_out"
}

# emit_cors <name>  -> appends a permissive CORS middleware to $MIDDLEWARES
emit_cors() {
  {
    echo "    ${1}-cors:"
    echo "      headers:"
    echo "        accessControlAllowOriginList: [\"*\"]"
    echo "        accessControlAllowMethods: [GET, POST, PUT, OPTIONS]"
    echo "        accessControlAllowHeaders:"
    for _hdr in Accept Authorization Keep-Alive Origin DNT User-Agent \
                X-Requested-With If-Modified-Since Cache-Control Content-Type Range; do
      echo "          - $_hdr"
    done
    echo "        accessControlMaxAge: 1728000"
    echo "        addVaryHeader: true"
  } >> "$MIDDLEWARES"
}

# emit_server_block "<server_names>" "<root>"  -> appends an nginx SPA server{}
emit_server_block() {
  {
    echo "server {"
    echo "    listen 80;"
    echo "    server_name${1};"
    echo "    root ${2};"
    echo "    index index.html;"
    echo ""
    echo "    location / { try_files \$uri \$uri/ /index.html; }"
    echo "    location = /index.html { add_header Cache-Control \"no-cache\"; }"
    echo "    location ~* \.(?:js|css|woff2?|ttf|eot|png|jpe?g|gif|svg|ico|webp|map)\$ {"
    echo "        expires 30d;"
    echo "        add_header Cache-Control \"public, immutable\";"
    echo "    }"
    echo "    location ~ /\. { deny all; }"    # never serve .env, .git, dotfiles
    echo ""
    echo "    gzip on;"
    echo "    gzip_types text/css application/javascript application/json image/svg+xml;"
    echo "}"
  } >> "$NGINX"
}

route_count=0
app_count=0

# ── ROUTE_* (Traefik-only proxies) ────────────────────────────────────────────
n=1
while :; do
  eval "name=\${ROUTE_${n}_NAME:-}"
  [ -z "$name" ] && break

  eval "hosts=\${ROUTE_${n}_HOSTS:-}"
  eval "service=\${ROUTE_${n}_SERVICE:-}"
  eval "tls=\${ROUTE_${n}_TLS:-true}"
  eval "entry=\${ROUTE_${n}_ENTRYPOINTS:-websecure}"

  if [ -z "$hosts" ] || [ -z "$service" ]; then
    echo "ERROR: ROUTE_${n} ($name) is missing HOSTS or SERVICE" >&2
    exit 1
  fi

  rule="$(build_hostrule "$hosts")"
  {
    echo "    ${name}:"
    echo "      rule: \"${rule}\""
    echo "      entryPoints: [${entry}]"
    echo "      service: ${name}"
    if [ "$tls" = "true" ]; then
      echo "      tls:"
      echo "        certResolver: le"
    fi
  } >> "$ROUTERS"
  {
    echo "    ${name}:"
    echo "      loadBalancer:"
    echo "        servers:"
    echo "          - url: \"${service}\""
  } >> "$SERVICES"

  route_count=$((route_count + 1))
  n=$((n + 1))
done

# ── APP_* (dockerized edge-spa SPAs + optional API) ───────────────────────────
n=1
while :; do
  eval "name=\${APP_${n}_NAME:-}"
  [ -z "$name" ] && break

  eval "web_hosts=\${APP_${n}_WEB_HOSTS:-}"
  eval "web_root=\${APP_${n}_WEB_ROOT:-}"
  eval "admin_hosts=\${APP_${n}_ADMIN_HOSTS:-}"
  eval "admin_root=\${APP_${n}_ADMIN_ROOT:-}"
  eval "api=\${APP_${n}_API:-}"

  if [ -z "$web_hosts" ] || [ -z "$web_root" ]; then
    echo "ERROR: APP_${n} ($name) is missing WEB_HOSTS or WEB_ROOT" >&2
    exit 1
  fi
  if [ -n "$admin_hosts" ] && [ -z "$admin_root" ]; then
    echo "ERROR: APP_${n} ($name) sets ADMIN_HOSTS but no ADMIN_ROOT" >&2
    exit 1
  fi

  # All hostnames this app answers on (web + admin), used by the Traefik rules.
  all_hosts="$web_hosts"
  [ -n "$admin_hosts" ] && all_hosts="$web_hosts,$admin_hosts"
  all_rule="$(build_hostrule "$all_hosts")"

  # Traefik: one web/admin router → the shared edge-spa nginx (server_name routed).
  {
    echo "    ${name}-web:"
    echo "      rule: \"${all_rule}\""
    echo "      entryPoints: [websecure]"
    echo "      service: ${name}-web"
    echo "      priority: 1"
    echo "      tls:"
    echo "        certResolver: le"
  } >> "$ROUTERS"
  {
    echo "    ${name}-web:"
    echo "      loadBalancer:"
    echo "        servers:"
    echo "          - url: \"http://edge-spa:80\""
  } >> "$SERVICES"

  # Traefik: optional API + socket.io router (priority beats the web catch-all).
  if [ -n "$api" ]; then
    {
      echo "    ${name}-api:"
      echo "      rule: \"(${all_rule}) && (PathPrefix(\`/api\`) || PathPrefix(\`/socket.io\`))\""
      echo "      entryPoints: [websecure]"
      echo "      service: ${name}-api"
      echo "      priority: 100"
      echo "      middlewares: [${name}-cors]"
      echo "      tls:"
      echo "        certResolver: le"
    } >> "$ROUTERS"
    {
      echo "    ${name}-api:"
      echo "      loadBalancer:"
      echo "        servers:"
      echo "          - url: \"${api}\""
    } >> "$SERVICES"
    emit_cors "$name"
  fi

  # nginx: a server block per web/admin host set, each rooted at its build dir.
  emit_server_block "$(build_servernames "$web_hosts")" "$web_root"
  [ -n "$admin_hosts" ] && emit_server_block "$(build_servernames "$admin_hosts")" "$admin_root"

  app_count=$((app_count + 1))
  n=$((n + 1))
done

# ── Optional dashboard router (its service is api@internal — no services entry) ─
DASHBOARD_HOST="${DASHBOARD_HOST:-}"
DASHBOARD_AUTH="${DASHBOARD_AUTH:-}"
if [ -n "$DASHBOARD_HOST" ]; then
  {
    echo "    traefik-dashboard:"
    echo "      rule: \"Host(\`${DASHBOARD_HOST}\`)\""
    echo "      entryPoints: [websecure]"
    echo "      service: api@internal"
    echo "      tls:"
    echo "        certResolver: le"
    if [ -n "$DASHBOARD_AUTH" ]; then
      echo "      middlewares: [traefik-dashboard-auth]"
    fi
  } >> "$ROUTERS"

  if [ -n "$DASHBOARD_AUTH" ]; then
    {
      echo "    traefik-dashboard-auth:"
      echo "      basicAuth:"
      echo "        users:"
      echo "          - \"${DASHBOARD_AUTH}\""
    } >> "$MIDDLEWARES"
  fi
fi

# ── Assemble Traefik routes.yml (emit http: / sub-sections only when non-empty) ─
{
  echo "# AUTO-GENERATED by scripts/generate-routes.sh — DO NOT EDIT BY HAND."
  echo "# Edit ../.env and re-run:  docker compose run --rm route-generator"
  if [ -s "$ROUTERS" ] || [ -s "$MIDDLEWARES" ] || [ -s "$SERVICES" ]; then
    echo "http:"
    if [ -s "$ROUTERS" ]; then
      echo "  routers:"
      cat "$ROUTERS"
    fi
    if [ -s "$MIDDLEWARES" ]; then
      echo "  middlewares:"
      cat "$MIDDLEWARES"
    fi
    if [ -s "$SERVICES" ]; then
      echo "  services:"
      cat "$SERVICES"
    fi
  fi
} > "$OUT"

# ── Assemble edge-spa nginx config (only when an output path was given) ─────────
if [ -n "$SPA_OUT" ]; then
  {
    echo "# AUTO-GENERATED by scripts/generate-routes.sh — DO NOT EDIT BY HAND."
    echo "# Edit the APP_* blocks in ../.env and re-run route-generator."
    # Drop requests for any host we don't explicitly serve.
    echo "server { listen 80 default_server; server_name _; return 444; }"
    [ -s "$NGINX" ] && cat "$NGINX"
  } > "$SPA_OUT"
fi

echo "Wrote $OUT (${route_count} route(s), ${app_count} app(s)${DASHBOARD_HOST:+ + dashboard})${SPA_OUT:+ + $SPA_OUT}."
