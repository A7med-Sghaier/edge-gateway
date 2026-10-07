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
#                                                      # true = Let's Encrypt cert, false = plain
#                                                      # HTTP, local = the LOCAL_TLS_* cert below
#   ROUTE_1_ENTRYPOINTS=websecure                      # optional, default websecure
#   ROUTE_1_PATHS=/auth,/api                           # optional — only these path prefixes;
#                                                      # beats a same-host route without PATHS
#
# ── APP_* : static SPAs served by the dockerized edge-spa nginx ───────────────
# Each block renders (a) nginx server block(s) rooted at the on-host build dir
# (bind-mounted /var/www) and (b) Traefik routers: a web/admin router → edge-spa,
# and — when APP_N_API is set — a router for the API path prefixes → that API
# backend, with the CORS middleware Traefik answers preflights from.
#   APP_1_NAME=example-app                             # unique id
#   APP_1_WEB_HOSTS=example.com,www.example.com
#   APP_1_WEB_ROOT=/var/www/example-app/web/html       # served build dir
#   APP_1_ADMIN_HOSTS=admin.example.com                # optional
#   APP_1_ADMIN_ROOT=/var/www/example-app/admin/html   # optional (required if ADMIN_HOSTS set)
#   APP_1_API=http://api-backend:8080                  # optional (adds api router + CORS)
#   APP_1_API_PATHS=/api,/socket.io                    # optional, this is the default
#
# ── TCP_* : raw-TCP backends (non-HTTP protocols, e.g. MongoDB) ───────────────
# Routed on a DEDICATED entrypoint — a protocol that sends no cleartext SNI can't
# be multiplexed onto :443. The entrypoint is STATIC config and therefore cannot be
# declared here: each server adds it to $RUNTIME_CONFIG_DIR/traefik.override.yml
# (see traefik/traefik.override.example.yml) and publishes the port from its own
# docker-compose.override.yml.
#   TCP_1_NAME=mongo                                   # unique router/service id
#   TCP_1_ENTRYPOINT=mongo                             # entrypoint from the server overlay
#   TCP_1_SERVICE=host.docker.internal:27017           # host:port — NOT a url
#   TCP_1_HOSTSNI=mongo.example.com                    # optional, default '*'
#   TCP_1_TLS=true                                     # optional, default true
#   TCP_1_ALLOWLIST=203.0.113.7/32,198.51.100.0/24     # optional, comma-separated CIDRs
#
# ── LOCAL_TLS_* : one locally issued certificate (e.g. mkcert) ────────────────
# For a hostname Let's Encrypt cannot reach — a dev name pointed at 127.0.0.1 in
# /etc/hosts. Paths are INSIDE the traefik container; mount the files there from a
# local, gitignored docker-compose.override.yml. Routes opt in with ROUTE_N_TLS=local.
#   LOCAL_TLS_CERT_FILE=/etc/traefik/certs/dev.pem
#   LOCAL_TLS_KEY_FILE=/etc/traefik/certs/dev-key.pem
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
# Same rule for the `tcp:` block: emit it only when it has content, or Traefik
# rejects the file and drops every route in the provider directory with it.
TCP_ROUTERS="$(mktemp)"
TCP_MIDDLEWARES="$(mktemp)"
TCP_SERVICES="$(mktemp)"
trap 'rm -f "$ROUTERS" "$MIDDLEWARES" "$SERVICES" "$NGINX" \
      "$TCP_ROUTERS" "$TCP_MIDDLEWARES" "$TCP_SERVICES"' EXIT

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

# build_pathrule "/api, /socket.io" -> PathPrefix(`/api`) || PathPrefix(`/socket.io`)
build_pathrule() {
  _rule=""
  _oldIFS=$IFS
  IFS=','
  for _p in $1; do
    _p=$(printf '%s' "$_p" | tr -d ' ')
    [ -z "$_p" ] && continue
    # A prefix without a leading slash matches nothing, and Traefik accepts the
    # rule happily — the only symptom is the SPA catch-all answering every API
    # request with index.html.
    case "$_p" in
      /*) ;;
      *)
        echo "ERROR: API path prefix '$_p' must start with '/'" >&2
        exit 1
        ;;
    esac
    if [ -z "$_rule" ]; then
      _rule="PathPrefix(\`$_p\`)"
    else
      _rule="$_rule || PathPrefix(\`$_p\`)"
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

# emit_cidrlist "1.2.3.4/32, 5.6.7.0/24" "<indent>"  -> yaml list items on stdout
emit_cidrlist() {
  _oldIFS=$IFS
  IFS=','
  for _c in $1; do
    _c=$(printf '%s' "$_c" | tr -d ' ')
    [ -z "$_c" ] && continue
    printf '%s- "%s"\n' "$2" "$_c"
  done
  IFS=$_oldIFS
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
tcp_count=0

LOCAL_TLS_CERT_FILE="${LOCAL_TLS_CERT_FILE:-}"
LOCAL_TLS_KEY_FILE="${LOCAL_TLS_KEY_FILE:-}"
# Half a pair loads no certificate at all, and Traefik then answers with its own
# self-signed default, which looks like a trust problem rather than a config one.
if { [ -n "$LOCAL_TLS_CERT_FILE" ] && [ -z "$LOCAL_TLS_KEY_FILE" ]; } ||
   { [ -z "$LOCAL_TLS_CERT_FILE" ] && [ -n "$LOCAL_TLS_KEY_FILE" ]; }; then
  echo "ERROR: set both LOCAL_TLS_CERT_FILE and LOCAL_TLS_KEY_FILE, or neither" >&2
  exit 1
fi

# ── ROUTE_* (Traefik-only proxies) ────────────────────────────────────────────
n=1
while :; do
  eval "name=\${ROUTE_${n}_NAME:-}"
  [ -z "$name" ] && break

  eval "hosts=\${ROUTE_${n}_HOSTS:-}"
  eval "service=\${ROUTE_${n}_SERVICE:-}"
  eval "tls=\${ROUTE_${n}_TLS:-true}"
  eval "entry=\${ROUTE_${n}_ENTRYPOINTS:-websecure}"
  eval "paths=\${ROUTE_${n}_PATHS:-}"

  if [ -z "$hosts" ] || [ -z "$service" ]; then
    echo "ERROR: ROUTE_${n} ($name) is missing HOSTS or SERVICE" >&2
    exit 1
  fi

  case "$tls" in
    true | false) ;;
    local)
      if [ -z "$LOCAL_TLS_CERT_FILE" ]; then
        echo "ERROR: ROUTE_${n} ($name) has TLS=local but LOCAL_TLS_CERT_FILE/LOCAL_TLS_KEY_FILE are not set" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: ROUTE_${n} ($name) TLS must be true, false or local (got '$tls')" >&2
      exit 1
      ;;
  esac

  rule="$(build_hostrule "$hosts")"
  # A path-scoped route shares its hosts with a catch-all one (an SPA with its API
  # on the same name). Traefik ranks routers by rule length, so the longer rule
  # with the PathPrefix wins without an explicit priority.
  if [ -n "$paths" ]; then
    path_rule="$(build_pathrule "$paths")"
    if [ -z "$path_rule" ]; then
      echo "ERROR: ROUTE_${n} ($name) sets PATHS but none is a usable prefix" >&2
      exit 1
    fi
    rule="(${rule}) && (${path_rule})"
  fi
  {
    echo "    ${name}:"
    echo "      rule: \"${rule}\""
    echo "      entryPoints: [${entry}]"
    echo "      service: ${name}"
    if [ "$tls" = "true" ]; then
      echo "      tls:"
      echo "        certResolver: le"
    elif [ "$tls" = "local" ]; then
      # No resolver: Traefik picks the LOCAL_TLS_* certificate from its store by SNI.
      echo "      tls: {}"
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
  eval "api_paths=\${APP_${n}_API_PATHS:-/api,/socket.io}"

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

  # Traefik: optional API router on the APP_N_API_PATHS prefixes (its priority
  # beats the web catch-all, which would otherwise answer with index.html).
  if [ -n "$api" ]; then
    path_rule="$(build_pathrule "$api_paths")"
    if [ -z "$path_rule" ]; then
      echo "ERROR: APP_${n} ($name) sets API but API_PATHS has no usable prefix" >&2
      exit 1
    fi
    {
      echo "    ${name}-api:"
      echo "      rule: \"(${all_rule}) && (${path_rule})\""
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

# ── TCP_* (raw-TCP backends on their own entrypoint) ──────────────────────────
n=1
while :; do
  eval "name=\${TCP_${n}_NAME:-}"
  [ -z "$name" ] && break

  eval "entry=\${TCP_${n}_ENTRYPOINT:-}"
  eval "service=\${TCP_${n}_SERVICE:-}"
  eval "hostsni=\${TCP_${n}_HOSTSNI:-*}"
  eval "tls=\${TCP_${n}_TLS:-true}"
  eval "allowlist=\${TCP_${n}_ALLOWLIST:-}"

  if [ -z "$entry" ] || [ -z "$service" ]; then
    echo "ERROR: TCP_${n} ($name) is missing ENTRYPOINT or SERVICE" >&2
    exit 1
  fi
  # A TCP service takes a bare host:port. A url is the ROUTE_*_SERVICE shape and
  # is the obvious copy-paste mistake; Traefik would accept it and never connect.
  case "$service" in
    *://*)
      echo "ERROR: TCP_${n} ($name) SERVICE must be host:port, not a url ('$service')" >&2
      exit 1
      ;;
  esac
  # Traefik can only get a certificate for a name it knows, and it refuses a
  # non-wildcard HostSNI on a router that isn't doing TLS. Both mistakes fail the
  # whole file at load time, so catch them here where the error names the block.
  if [ "$tls" = "true" ] && [ "$hostsni" = "*" ]; then
    echo "ERROR: TCP_${n} ($name) has TLS=true but HOSTSNI='*' — set HOSTSNI to the hostname the cert is for, or TLS=false" >&2
    exit 1
  fi
  if [ "$tls" != "true" ] && [ "$hostsni" != "*" ]; then
    echo "ERROR: TCP_${n} ($name) sets HOSTSNI='$hostsni' but TLS=false — Traefik rejects a non-wildcard HostSNI on a plaintext TCP router" >&2
    exit 1
  fi
  if [ -z "$allowlist" ]; then
    echo "WARNING: TCP_${n} ($name) has no ALLOWLIST — this backend is reachable from the entire internet." >&2
  fi

  {
    echo "    ${name}:"
    echo "      rule: \"HostSNI(\`${hostsni}\`)\""
    echo "      entryPoints: [${entry}]"
    echo "      service: ${name}"
    [ -n "$allowlist" ] && echo "      middlewares: [${name}-allowlist]"
    if [ "$tls" = "true" ]; then
      echo "      tls:"
      echo "        certResolver: le"
    fi
  } >> "$TCP_ROUTERS"
  if [ -n "$allowlist" ]; then
    {
      echo "    ${name}-allowlist:"
      echo "      ipAllowList:"
      echo "        sourceRange:"
      emit_cidrlist "$allowlist" "          "
    } >> "$TCP_MIDDLEWARES"
  fi
  {
    echo "    ${name}:"
    echo "      loadBalancer:"
    echo "        servers:"
    echo "          - address: \"${service}\""
  } >> "$TCP_SERVICES"

  tcp_count=$((tcp_count + 1))
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
  if [ -s "$TCP_ROUTERS" ] || [ -s "$TCP_MIDDLEWARES" ] || [ -s "$TCP_SERVICES" ]; then
    echo "tcp:"
    if [ -s "$TCP_ROUTERS" ]; then
      echo "  routers:"
      cat "$TCP_ROUTERS"
    fi
    if [ -s "$TCP_MIDDLEWARES" ]; then
      echo "  middlewares:"
      cat "$TCP_MIDDLEWARES"
    fi
    if [ -s "$TCP_SERVICES" ]; then
      echo "  services:"
      cat "$TCP_SERVICES"
    fi
  fi
  if [ -n "$LOCAL_TLS_CERT_FILE" ]; then
    echo "tls:"
    echo "  certificates:"
    echo "    - certFile: \"${LOCAL_TLS_CERT_FILE}\""
    echo "      keyFile: \"${LOCAL_TLS_KEY_FILE}\""
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

echo "Wrote $OUT (${route_count} route(s), ${app_count} app(s), ${tcp_count} tcp route(s)${DASHBOARD_HOST:+ + dashboard})${SPA_OUT:+ + $SPA_OUT}."
