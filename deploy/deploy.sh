#!/usr/bin/env bash
# GPT Image Panel - one-click server deploy (Ubuntu/Debian, root or sudo).
# Idempotent: safe to run again to update an existing deployment.
set -euo pipefail

REPO="${REPO:-https://github.com/goldsonhwy/gpt-image-linux.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/gpt-image-panel}"
PORT="${PORT:-9090}"
SERVICE="${SERVICE:-gpt-image-panel}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log() { echo -e "\033[1;32m[deploy]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (or with sudo)."; exit 1
fi

log "1/8 Install system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl ca-certificates python3 python3-venv python3-pip nginx \
  build-essential libffi-dev libssl-dev

if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')" -lt 18 ]; then
  log "Install Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
log "node $(node -v), python $($PYTHON_BIN --version 2>&1)"

log "2/8 Fetch source"
if [ -d "$APP_DIR/.git" ]; then
  cd "$APP_DIR"
  git fetch origin "$BRANCH"
  git reset --hard "origin/$BRANCH"
else
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --branch "$BRANCH" "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

log "3/8 Python venv + backend deps"
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
  $PYTHON_BIN -m venv "$APP_DIR/.venv"
fi
"$APP_DIR/.venv/bin/pip" install --upgrade pip -q
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

log "4/8 Build frontend"
(cd "$APP_DIR/frontend" && npm ci && npm run build)

log "5/8 Prepare data directories"
mkdir -p "$APP_DIR/images" "$APP_DIR/data"
chown -R root:root "$APP_DIR/images" "$APP_DIR/data"

log "6/8 Configure environment"
ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
# GPT Image Panel runtime config
HOST=127.0.0.1
PORT=$PORT
# First visit registers the admin account; no access key needed.
ALLOW_UNAUTHENTICATED=true
SESSION_DAYS=3650
# Set a stable secret so sessions survive restarts (change to a random value).
SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' )
ENABLE_VERSION_CHECK=false
EOF
  log "Created $ENV_FILE (edit it any time)"
else
  warn "$ENV_FILE exists, keeping current settings"
fi

log "7/8 Install systemd service"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=GPT Image Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/uvicorn backend.app.main:app --host \${HOST:-127.0.0.1} --port \${PORT:-9090}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"

log "8/8 Configure nginx reverse proxy"
NGINX_CONF="/etc/nginx/sites-available/$SERVICE"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 1100m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$SERVICE"
nginx -t && systemctl restart nginx

sleep 2
log "Done. Service status:"
systemctl --no-pager status "$SERVICE" | head -12 || true

echo
echo "==================================================="
echo " Open http://$(curl -s ifconfig.me 2>/dev/null || echo '<server-ip>')/"
echo " First visit: register an admin username + password (no activation code)."
echo " Session cookie stays valid for 10 years."
echo " Data: $APP_DIR/images , $APP_DIR/data/app.sqlite3"
echo " Logs: journalctl -u $SERVICE -f"
echo " Update later: re-run this script."
echo "==================================================="
