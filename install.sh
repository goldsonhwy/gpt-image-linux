#!/usr/bin/env bash
#
# GPT Image Panel — 一键部署脚本 (Debian / Ubuntu)
#
# 做这些事:
#   1. 安装 Docker (若未装) 及系统依赖
#   2. 交互式提示: 监听端口 + 域名(可选) + 访问密钥
#   3. 拉取官方镜像并部署容器 (host 网络, 直接暴露端口)
#   4. 若填了域名 -> 自动检测已装 caddy/nginx (没有就装 caddy) 做 HTTPS 反向代理
#   5. 打印最终访问地址 (https://域名 与/或 http://IP:端口)
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/goldsonhwy/gpt-image-linux/main/install.sh | bash
#
set -euo pipefail

IMAGE="ghcr.io/z1rconium/gpt-image-linux:v2.0.0"
INSTALL_DIR="$HOME/gpt-image-panel"
SERVICE_NAME="gpt-image-panel"

log(){  printf '\033[1;32m[部署]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 或 sudo 运行本脚本"; exit 1; }

# ---------------------------------------------------------------- 1. Docker + 依赖
need_docker=0;  command -v docker >/dev/null 2>&1 || need_docker=1
need_compose=0; docker compose version >/dev/null 2>&1 || need_compose=1

if [ "$need_docker" = 1 ]; then
  log "安装 Docker (官方仓库) ..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "检测到 Docker 已安装, 跳过。"
fi

# compose 插件缺失 -> 补装
if [ "$need_compose" = 1 ]; then
  log "安装 docker-compose-plugin ..."
  apt-get install -y docker-compose-plugin >/dev/null || warn "compose 插件安装失败, 请手动装 docker-compose"
fi

log "安装系统依赖 ..."
apt-get install -y git curl ca-certificates jq openssl >/dev/null 2>&1 || true
systemctl enable --now docker 2>/dev/null || true

# ---------------------------------------------------------------- 2. 交互提示
if [ -f "$INSTALL_DIR/.env" ]; then
  log "已存在 $INSTALL_DIR/.env, 复用现有配置 (改端口/域名/密钥请手动编辑后重跑)。"
else
  mkdir -p "$INSTALL_DIR"
  DEFAULT_PORT=8091
  read -r -p "监听端口 [默认 $DEFAULT_PORT]: " PORT || true
  PORT="${PORT:-$DEFAULT_PORT}"; PORT="${PORT//[^0-9]/}"; [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  # 域名 (可选; 回车=跳过, 只用 IP:端口 直连)。填了则自动 HTTPS 反代。
  DOMAIN=""
  if [ -t 0 ]; then
    read -r -p "域名 (回车=跳过; 填了将自动 HTTPS 反代): " DOMAIN || true
  fi
  DOMAIN="$(printf '%s' "${DOMAIN:-}" | sed 's#^https\{0,1\}//##; s#/\{0,1\}$##')"
  ACCESS_KEY=""
  if [ -t 0 ]; then
    read -r -p "访问密钥 ACCESS_KEY (回车=随机生成): " ACCESS_KEY || true
  fi
  [ -z "$ACCESS_KEY" ] && ACCESS_KEY="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # 生成 .env (仅覆盖 compose 实际用到的关键项; 其余用镜像默认值)
  cat > "$INSTALL_DIR/.env" <<EOF
GRANIAN_PORT=${PORT}
ACCESS_KEY=***
DOMAIN=${DOMAIN}
EOF
  if [ -n "$DOMAIN" ]; then
    echo "PUBLIC_ORIGIN=https://$DOMAIN" >> "$INSTALL_DIR/.env"
    echo "ALLOWED_HOSTS=$DOMAIN,127.0.0.1:$PORT,localhost:$PORT" >> "$INSTALL_DIR/.env"
    log "已生成 .env (端口 $PORT, 域名 $DOMAIN -> HTTPS 反代)"
  else
    log "已生成 .env (端口 $PORT, 无域名 -> 仅 IP 直连)"
  fi
fi

# ---------------------------------------------------------------- 3. 部署 (生成 compose 兜底, 不依赖 clone)
cd "$INSTALL_DIR"
if [ ! -f docker-compose.yml ]; then
  log "生成 docker-compose.yml ..."
  cat > docker-compose.yml <<EOF
services:
  web:
    image: ${IMAGE}
    container_name: ${SERVICE_NAME}
    network_mode: host
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./images:/app/images
      - ./data:/app/data
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:${PORT}/health')"]
      interval: 10s
      timeout: 5s
      retries: 30
EOF
  warn "已生成最小 compose (镜像 $IMAGE)。需要高级配置可替换该文件。"
fi
# .env 兜底 (缺项补默认)
grep -q '^GRANIAN_PORT=' .env 2>/dev/null || echo "GRANIAN_PORT=${PORT:-8091}" >> .env
grep -q '^ACCESS_KEY='  .env 2>/dev/null || echo "ACCESS_KEY=${ACCESS_KEY:-}" >> .env

# 拉镜像
log "拉取镜像 $IMAGE ..."
docker pull "$IMAGE"

# 旧容器先停 (数据目录保留)
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVICE_NAME"; then
  log "检测到旧容器 $SERVICE_NAME, 停止并删除 ..."
  docker stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  docker rm "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

log "启动容器 ..."
docker compose -f docker-compose.yml up -d

# ---------------------------------------------------------------- 4. 等待就绪
PORT="$(grep -E '^GRANIAN_PORT=' .env | cut -d= -f2 || echo 8091)"
log "等待服务就绪 (health check, 端口 $PORT) ..."
ok=0
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] && log "服务已就绪。" || warn "服务未就绪, 查看日志: docker logs -f $SERVICE_NAME"

# ---------------------------------------------------------------- 5. 反向代理 (仅当填了域名)
DOMAIN="$(grep -E '^DOMAIN=' .env | cut -d= -f2 || echo "")"
if [ -n "$DOMAIN" ]; then
  log "配置反向代理 https://$DOMAIN -> 127.0.0.1:$PORT ..."
  # 5a. 检测已装反代: caddy 优先, 其次 nginx
  RP=""
  command -v caddy >/dev/null 2>&1 && RP="caddy"
  [ -z "$RP" ] && command -v nginx >/dev/null 2>&1 && RP="nginx"
  # 5b. 都没 -> 安装 caddy (官方源, 自动 Let's Encrypt)
  if [ -z "$RP" ]; then
    log "未检测到 caddy/nginx, 安装 caddy ..."
    apt-get install -y ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://dl.caddyserver.com/caddy-key.asc" -o /etc/apt/keyrings/caddy.asc
    echo "deb [signed-by=/etc/apt/keyrings/caddy.asc] https://dl.caddyserver.com/ubuntu stable main" > /etc/apt/sources.list.d/caddyserver.list
    apt-get update -y
    apt-get install -y caddy
    RP="caddy"
  fi

  if [ "$RP" = "caddy" ]; then
    # caddy: 整体接管默认 Caddyfile, 加域名站点 (避免默认 :80 站点抢端口)
    CADDY_MAIN="/etc/caddy/Caddyfile"
    # 备份默认 Caddyfile, 若里面没有我们站点则加进去
    [ -f "$CADDY_MAIN" ] && grep -qxF "$DOMAIN" "$CADDY_MAIN" || {
      # 追加站点 (保留已有站点, 不破坏其它服务)
      cat >> "$CADDY_MAIN" <<EOF

$DOMAIN {
    reverse_proxy 127.0.0.1:${PORT} {
        header_up Host {upstream_hostport}
    }
    encode gzip zstd
}
EOF
    }
    systemctl enable caddy >/dev/null 2>&1 || true
    caddy validate --config "$CADDY_MAIN" >/dev/null 2>&1 || warn "caddy 配置校验失败, 请检查 $CADDY_MAIN"
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
    warn "caddy 已配 $DOMAIN -> :$PORT (自动申请 Let's Encrypt)。请确保该域名 DNS A 记录指向本机 IP。"
  else
    # nginx: 反代 + certbot
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > /etc/nginx/sites-available/gpt-image-panel <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/gpt-image-panel /etc/nginx/sites-enabled/gpt-image-panel
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx
    if command -v certbot >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
      log "nginx: 申请 Let's Encrypt 证书 ..."
      certbot -q -n --nginx -d "$DOMAIN" >/dev/null 2>&1 || warn "证书申请失败, 手动: certbot --nginx -d $DOMAIN"
    else
      warn "nginx 反代已配 (HTTP), 未装 certbot。装 HTTPS: apt-get install -y python3-certbot-nginx && certbot --nginx -d $DOMAIN"
    fi
  fi
  log "反代完成: https://$DOMAIN"
fi

# ---------------------------------------------------------------- 6. 打印访问地址
PUB_IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "${PUB_IP:-}" ] && PUB_IP="<服务器IP>"
ACCESS_KEY="$(grep -E '^ACCESS_KEY=' .env | cut -d= -f2)"

printf '\n'
printf '\033[1;34m================ 部署完成 ================\033[0m\n'
if [ -n "$DOMAIN" ]; then
  printf '\033[1;32m网站地址:  https://%s   (反向代理)\033[0m\n' "$DOMAIN"
  printf '\033[1;36m备用直连:  http://%s:%s\033[0m\n' "$PUB_IP" "$PORT"
fi
printf '\033[1;32m本机:      http://127.0.0.1:%s\033[0m\n' "$PORT"
printf '访问密钥:  %s\n' "$ACCESS_KEY"
printf '容器名:    %s   |   镜像: %s\n' "$SERVICE_NAME" "$IMAGE"
printf '安装目录:  %s\n' "$INSTALL_DIR"
printf '\033[1;36m提示: 用访问密钥登录。若被云防火墙拦截, 放行入方向 TCP 80/443 (有域名) 或 %s (直连)。\033[0m\n' "$PORT"
printf '\033[1;34m============================================\033[0m\n'
log "完成。"
