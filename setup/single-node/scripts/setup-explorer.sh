#!/bin/bash
# setup-explorer.sh
#
# Install and configure Neuron Explorer as a long-running systemd
# service on the Neuron DLAMI host, fronted by an nginx /explorer/
# location block that rewrites the API URL inlined in the SPA shell.
#
# Idempotent.  Designed to be invoked through run-tasks.sh so it can
# be re-applied after a Spot stop/start without manual cleanup.
#
# Required env (set by the task wrapper):
#   EXPLORER_USER         user that owns the systemd unit (default: coder)
#   EXPLORER_PORT         UI port the service listens on (default: 8181;
#                         8081 is occupied by qwen-image-edit on
#                         voice-image-edit deployments)
#   EXPLORER_API_PORT     API port the service binds to (default: 3002,
#                         not configurable on neuron-explorer 2.29 - keep
#                         in sync with the upstream tool)
#   EXPLORER_DATA_DIR     state dir owned by the unit
#                         (default: /var/lib/neuron-explorer)
#   EXPLORER_SEED_DIR     pre-loaded profile dir consumed by view -d
#                         (default: $EXPLORER_DATA_DIR/seed)
#   EXPLORER_DISPLAY_NAME human-friendly name shown in the UI
#                         (default: workshop)
#   NGINX_LOCATION        sub-path served from the existing nginx site
#                         (default: /explorer)

set -euo pipefail

EXPLORER_USER="${EXPLORER_USER:-coder}"
EXPLORER_PORT="${EXPLORER_PORT:-8181}"
EXPLORER_API_PORT="${EXPLORER_API_PORT:-3002}"
EXPLORER_DATA_DIR="${EXPLORER_DATA_DIR:-/var/lib/neuron-explorer}"
EXPLORER_SEED_DIR="${EXPLORER_SEED_DIR:-$EXPLORER_DATA_DIR/seed}"
EXPLORER_DISPLAY_NAME="${EXPLORER_DISPLAY_NAME:-workshop}"
NGINX_LOCATION="${NGINX_LOCATION:-/explorer}"

NEURON_EXPLORER_BIN="/opt/aws/neuron/bin/neuron-explorer"
SYSTEMD_UNIT="/etc/systemd/system/neuron-explorer.service"
NGINX_SNIPPET="/etc/nginx/snippets/explorer-location.conf"
NGINX_SITE="/etc/nginx/sites-enabled/code-server"

log() { echo "[setup-explorer] $*"; }
fail() { echo "[setup-explorer:fail] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -x "$NEURON_EXPLORER_BIN" ] || fail "neuron-explorer not found at $NEURON_EXPLORER_BIN"
id "$EXPLORER_USER" >/dev/null 2>&1 || fail "user $EXPLORER_USER does not exist"
[ -f "$NGINX_SITE" ] || fail "nginx site $NGINX_SITE missing - run setup-code-server first"

# ---------------------------------------------------------------------------
# 2. State directory layout
# ---------------------------------------------------------------------------
log "create state layout under $EXPLORER_DATA_DIR"
install -d -o "$EXPLORER_USER" -g "$EXPLORER_USER" -m 0755 "$EXPLORER_DATA_DIR"
install -d -o "$EXPLORER_USER" -g "$EXPLORER_USER" -m 0755 "$EXPLORER_DATA_DIR/data"
install -d -o "$EXPLORER_USER" -g "$EXPLORER_USER" -m 0755 "$EXPLORER_DATA_DIR/logs"

if [ ! -d "$EXPLORER_SEED_DIR" ]; then
    log "create empty seed dir $EXPLORER_SEED_DIR"
    install -d -o "$EXPLORER_USER" -g "$EXPLORER_USER" -m 0755 "$EXPLORER_SEED_DIR"
fi

# ---------------------------------------------------------------------------
# 3. systemd unit
# ---------------------------------------------------------------------------
log "write $SYSTEMD_UNIT"
cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=Neuron Explorer (web UI + REST API)
Documentation=https://awsdocs-neuron.readthedocs-hosted.com/
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${EXPLORER_USER}
Group=${EXPLORER_USER}
Environment=HOME=/home/${EXPLORER_USER}
WorkingDirectory=${EXPLORER_DATA_DIR}

# neuron-explorer 2.29 binds two ports under one PID:
#   * UI / static assets on -p (configurable, default 8181)
#   * REST API on a fixed internal port (currently 3002)
# Both bind to 127.0.0.1 only.  nginx is the single ingress.
#
# We do NOT pass -d EXPLORER_SEED_DIR here. neuron-explorer 2.30 treats
# the seed dir as a required input profile bundle and exits with status=1
# if it has no *.ntff or trace_info.pb. Operators upload profiles later
# via 'neuron-explorer upload' (or capture-and-upload.sh), so the
# steady-state UI must be able to start with an empty inbox.
ExecStart=${NEURON_EXPLORER_BIN} view \\
    --display-name ${EXPLORER_DISPLAY_NAME} \\
    --data-path ${EXPLORER_DATA_DIR}/data \\
    -p ${EXPLORER_PORT}

Restart=on-failure
RestartSec=5
StandardOutput=append:${EXPLORER_DATA_DIR}/logs/explorer.log
StandardError=append:${EXPLORER_DATA_DIR}/logs/explorer.log

# Light hardening (the binary is large and pulls in libnrt; we cannot
# go full sandbox without losing access to /opt/aws/neuron).
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${EXPLORER_DATA_DIR} /home/${EXPLORER_USER}

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------------------
# 4. Build-time bundle rewriter
# ---------------------------------------------------------------------------
# The Explorer SPA bundle ships URL-construction logic that branches
# on whether window.NEURON_API_URL contains "localhost".  When served
# from a non-localhost origin, the production branch builds absolute
# URLs against a bare hostname "explorer" with a "/prod/api/..." prefix,
# which obviously doesn't resolve on a same-origin deployment.
#
# We rewrite the bundle ONCE at deploy time with a Python script.  The
# rewritten asset is served as a static file by nginx; the upstream
# bundle is consulted only on the first request after a (re-)deploy.
# This is far cleaner than per-request sub_filter (no buffer math, no
# chunk-boundary surprises, full regex power, idempotent on disk).
REWRITER_SRC="$(dirname "$0")/rewrite-explorer-bundle.py"
REWRITER_INSTALL_DIR="/opt/neuron-explorer"
REWRITER_INSTALL="${REWRITER_INSTALL_DIR}/rewrite-explorer-bundle.py"
REWRITER_OUT_DIR="${EXPLORER_DATA_DIR}/assets"
REWRITER_STATUS="${EXPLORER_DATA_DIR}/rewriter.status"
REWRITER_MARK="${EXPLORER_DATA_DIR}/bundle.sha256"
REWRITER_UNIT="/etc/systemd/system/neuron-explorer-rewrite.service"

if [ ! -f "$REWRITER_SRC" ]; then
    fail "rewriter source $REWRITER_SRC missing - upload before running setup-explorer"
fi

log "install rewriter to $REWRITER_INSTALL"
install -d -m 0755 "$REWRITER_INSTALL_DIR"
install -m 0755 "$REWRITER_SRC" "$REWRITER_INSTALL"

# Install the capture-and-upload helper next to the rewriter so users
# can capture a profile and push it to the local view server with one
# command (see docs/explorer.md).  This file is optional; setup
# continues even if the source is not present yet.
CAPTURE_SRC="$(dirname "$0")/capture-and-upload.sh"
if [ -f "$CAPTURE_SRC" ]; then
    log "install capture-and-upload helper to ${REWRITER_INSTALL_DIR}/capture-and-upload.sh"
    install -m 0755 "$CAPTURE_SRC" "${REWRITER_INSTALL_DIR}/capture-and-upload.sh"
fi

log "create rewriter output dir $REWRITER_OUT_DIR"
install -d -o "$EXPLORER_USER" -g "$EXPLORER_USER" -m 0755 "$REWRITER_OUT_DIR"

log "write $REWRITER_UNIT"
cat > "$REWRITER_UNIT" <<UNIT
[Unit]
Description=Rewrite Neuron Explorer SPA bundle for same-origin URLs
Documentation=https://github.com/littlemex/aws-neuron-samples
After=neuron-explorer.service
Requires=neuron-explorer.service

[Service]
Type=oneshot
RemainAfterExit=no

# Wait for the upstream view server to come online before we try to
# fetch its bundle.  Up to 60 seconds.
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do curl -sf http://127.0.0.1:${EXPLORER_PORT}/ >/dev/null && exit 0 || sleep 2; done; exit 1'
ExecStart=/usr/bin/python3 ${REWRITER_INSTALL} \\
    --upstream http://127.0.0.1:${EXPLORER_PORT} \\
    --out ${REWRITER_OUT_DIR} \\
    --status ${REWRITER_STATUS} \\
    --mark ${REWRITER_MARK} \\
    --prefix ${NGINX_LOCATION}

# Exit codes:
#   0 = no-op or full success
#   1 = transient (upstream unreachable; nginx falls back via try_files)
#   2 = DEGRADED (rewrite incomplete; serves original; status reflects)
SuccessExitStatus=0 2

# Light hardening.  /opt/aws/neuron is read-only at runtime.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${EXPLORER_DATA_DIR}

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------------------
# 5. nginx fragment for /explorer/
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/nginx/snippets

log "write $NGINX_SNIPPET"
cat > "$NGINX_SNIPPET" <<NGINX
# /explorer/ -> Neuron Explorer UI.  Sub-path served from the same
# nginx site that already fronts code-server.  The SPA shell hard-codes
# 'http://localhost:${EXPLORER_API_PORT}' as the API base; sub_filter
# rewrites that literal so the bundle talks to /explorer/api/* via the
# same host.  The HTML shell is small (~1.6 KB) so per-request
# sub_filter is fine here.
location ${NGINX_LOCATION}/ {
    proxy_pass http://127.0.0.1:${EXPLORER_PORT}/;

    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Strip Accept-Encoding so sub_filter sees plain HTML rather than
    # gzipped bytes.
    proxy_set_header Accept-Encoding "";

    # The HTML shell needs three rewrites:
    #
    # 1. The API URL literal — flip "http://localhost:3002" to the
    #    sub-path root so the SPA fetches against same-origin paths.
    # 2. The asset hrefs — the upstream shell references "/assets/*"
    #    (root-absolute), which CloudFront cannot route because no
    #    cache behavior covers that path.  Rewrite to
    #    "/explorer/assets/*" so the existing /explorer/* behavior
    #    catches the request.
    # 3. The escaped form of (1): bundlers sometimes emit a JS string
    #    literal with backslash-escaped slashes inside template
    #    literals.
    sub_filter_types text/html;
    sub_filter_once off;
    sub_filter "http://localhost:${EXPLORER_API_PORT}"     "${NGINX_LOCATION}";
    sub_filter "http:\\\\/\\\\/localhost:${EXPLORER_API_PORT}" "${NGINX_LOCATION}";
    sub_filter '"/assets/'                                 '"${NGINX_LOCATION}/assets/';
    sub_filter "'/assets/"                                 "'${NGINX_LOCATION}/assets/";

    proxy_connect_timeout 60s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    send_timeout 300s;
}

# /explorer/assets/ -> rewritten Explorer SPA bundle on disk.
#
# The bundle is rewritten once at deploy time by the
# neuron-explorer-rewrite.service unit; nginx serves the rewritten
# file as a static asset.  If the rewrite has not happened yet (first
# boot race) or the upstream bundle is newer than the disk copy,
# try_files falls through to the @upstream-explorer-assets named
# location which proxies the unmodified upstream bundle.  The fall-
# through case is fail-open: SPA loads, but profile detail may emit
# the original (broken) URLs until the rewriter catches up.
#
# We mount under /explorer/assets/ rather than /assets/ so a single
# CloudFront cache behavior (/explorer/*) covers UI, API, and assets.
# The HTML shell's "/assets/*" references are rewritten by
# sub_filter above to "/explorer/assets/*" so the SPA loads cleanly.
location ${NGINX_LOCATION}/assets/ {
    alias ${REWRITER_OUT_DIR}/;
    try_files \$uri @upstream-explorer-assets;

    # Bundle assets are content-hashed in their filenames, so they are
    # safe to cache aggressively.
    expires 1h;
    add_header Cache-Control "public, immutable";
}

location @upstream-explorer-assets {
    rewrite ^${NGINX_LOCATION}/assets/(.*)$ /assets/\$1 break;
    proxy_pass http://127.0.0.1:${EXPLORER_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
}

# /explorer/health -> rewriter status (plain text).  Lets a smoke test
# or monitoring scrape confirm the bundle was rewritten cleanly.  The
# file's first line is "OK <sha>" or "DEGRADED <reason>".
location = ${NGINX_LOCATION}/health {
    alias ${REWRITER_STATUS};
    default_type text/plain;
    add_header Cache-Control "no-store";
}

# /explorer/api/ -> REST API on the same neuron-explorer PID.
# proxy_pass strips the /explorer prefix and hands /api/v1/... straight
# to the backend, which is what the binary expects.
location ${NGINX_LOCATION}/api/ {
    proxy_pass http://127.0.0.1:${EXPLORER_API_PORT}/api/;

    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # The API checks an x-user-id header for ownership-scoped lookups.
    # \$cf_user is mapped at the http{} scope (see cf-user-map.conf):
    # the cookie value when present, otherwise the Explorer display
    # name so direct SSM port-forward users still see a usable UI.
    proxy_set_header X-User-Id \$cf_user;

    proxy_connect_timeout 60s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    send_timeout 300s;
}
NGINX

# ---------------------------------------------------------------------------
# 5. Patch the existing site to include the snippet
# ---------------------------------------------------------------------------
INCLUDE_LINE="    include ${NGINX_SNIPPET};"
if ! grep -qF "$NGINX_SNIPPET" "$NGINX_SITE"; then
    log "patch $NGINX_SITE to include explorer snippet"
    # Insert the include directive just inside the server block, before
    # the catch-all 'location /' that fronts code-server.  Anchoring on
    # 'location / {' keeps the patch idempotent across re-runs.
    awk -v line="$INCLUDE_LINE" '
        /^[[:space:]]*location \/ \{/ && !done { print line; done=1 }
        { print }
    ' "$NGINX_SITE" > "${NGINX_SITE}.tmp"
    mv "${NGINX_SITE}.tmp" "$NGINX_SITE"
else
    log "include line already present in $NGINX_SITE"
fi

# ---------------------------------------------------------------------------
# 6. http{}-scope helper: cf_user cookie -> $cf_user variable.
#    Lives in /etc/nginx/conf.d/ so it loads before the server{} block.
# ---------------------------------------------------------------------------
CF_USER_MAP="/etc/nginx/conf.d/cf-user-map.conf"
log "write $CF_USER_MAP"
cat > "$CF_USER_MAP" <<MAP
# cf_user cookie -> X-User-Id header.  Set by the OAuth Lambda when the
# request travels via CloudFront; absent on direct SSM port-forward.
# In the latter case we fall back to the Explorer display name so the
# UI is usable without auth context.
map \$cookie_cf_user \$cf_user {
    default ${EXPLORER_DISPLAY_NAME};
    "~^.+\$" \$cookie_cf_user;
}
MAP

# ---------------------------------------------------------------------------
# 7. Reload services
# ---------------------------------------------------------------------------
log "reload systemd and nginx"
systemctl daemon-reload
nginx -t
systemctl reload nginx

systemctl enable neuron-explorer.service
systemctl restart neuron-explorer.service

# Run the rewriter once now (so the first user request hits a
# rewritten bundle, not the upstream fallback).  Subsequent re-runs
# are idempotent: the script short-circuits when the bundle's sha256
# matches the on-disk marker.
systemctl enable neuron-explorer-rewrite.service || true
systemctl start neuron-explorer-rewrite.service || true

# ---------------------------------------------------------------------------
# 8. Smoke check
# ---------------------------------------------------------------------------
log "wait for explorer to come online"
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${EXPLORER_PORT}/" >/dev/null 2>&1; then
        log "explorer is responding on :${EXPLORER_PORT}"
        break
    fi
    sleep 2
done

curl -sI "http://127.0.0.1/${NGINX_LOCATION#/}/" | head -1 || true
log "done"
