#!/usr/bin/env bash
#
# GPT Image Panel — 一键部署脚本 (Debian / Ubuntu, 无 nginx 反代)
#
# 做这些事:
#   1. 安装 Docker (若未装) 及 Debian 系统依赖
#   2. 交互式提示: 监听端口 + 访问密钥 (ACCESS_KEY)
#   3. 拉取官方镜像并部署容器 (host 网络, 直接暴露端口, 无需反代)
#   4. 打印最终访问地址
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/goldsonhwy/gpt-image-linux/main/install.sh | bash
#
set -euo pipefail

REPO="Z1rconium/gpt-image-linux"
IMAGE="ghcr.io/z1rconium/gpt-image-linux:v2.0.0"
INSTALL_DIR="$HOME/gpt-image-panel"
SERVICE_NAME="gpt-image-panel"

log(){ printf '\033[1;32m[部署]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 或 sudo 运行:  $0"; exit 1; }

# ---------------------------------------------------------------- 依赖判断
need_docker=0; command -v docker >/dev/null 2>&1 || need_docker=1
need_compose=0; docker compose version >/dev/null 2>&1 || { docker-compose version >/dev/null 2>&1 || need_compose=1; }

# ---------------------------------------------------------------- 1. Docker + Debian 依赖
if [ "$need_docker" = 1 ]; then
  log "安装 Docker (Debian 官方仓库) ..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "检测到 Docker 已安装, 跳过。"
fi
# 系统依赖 (镜像自带运行时; 这些是构建/排障常用)
log "安装 Debian 系统依赖 ..."
apt-get install -y git curl ca-certificates jq >/dev/null
systemctl enable --now docker 2>/dev/null || true
warn "若当前用户无法使用 docker, 请:  usermod -aG docker \$USER (并重新登录)"

# ---------------------------------------------------------------- 2. 交互提示
if [ -f "$INSTALL_DIR/.env" ]; then
  log "已存在 $INSTALL_DIR/.env, 复用现有配置 (改端口/密钥请手动编辑该文件后重跑)。"
else
  mkdir -p "$INSTALL_DIR"
  DEFAULT_PORT=8091
  read -r -p "部署到 $INSTALL_DIR | 监听端口 [默认 $DEFAULT_PORT]: " PORT || true
  PORT="${PORT:-$DEFAULT_PORT}"; PORT="${PORT//[^0-9]/}"; [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  ACCESS_KEY=""
  if [ -t 0 ]; then
    read -r -p "访问密钥 ACCESS_KEY (回车=随机生成): " ACCESS_KEY || true
  fi
  [ -z "$ACCESS_KEY" ] && ACCESS_KEY="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # 生成 .env (仅覆盖 compose 实际用到的关键项; 其余用镜像默认值)
  cat > "$INSTALL_DIR/.env" <<EOF
GRANIAN_PORT=${PORT}
ACCESS_KEY=***
# 用 host 网络直接暴露端口, 无需反代
EOF
  log "已生成 $INSTALL_DIR/.env (端口 $PORT)"
fi

# 同步仓库里的 docker-compose.yml / Dockerfile 到安装目录 (若缺失)
cd "$INSTALL_DIR"
if [ ! -f docker-compose.yml ]; then
  log "拉取部署文件 ..."
  git clone --depth 1 "https://github.com/$REPO" .repo >/dev/null 2>&1
  cp .repo/docker-compose.yml . 2>/dev/null || true
  # 让容器名/镜像可配置
  sed "s|^container_name:.*|container_name: ${SERVICE_NAME}|" docker-compose.yml >/dev/null
fi
# 注入端口/密钥 (若 .env 存在则以其为准; 否则写进 compose)
grep -q 'GRANIAN_PORT' .env 2>/dev/null || echo "GRANIAN_PORT=${PORT:-8091}" >> .env
grep -q 'ACCESS_KEY' .env 2>/dev/null || echo "ACCESS_KEY=${ACCESS_KEY:-}" >> .env

# ---------------------------------------------------------------- 3. 拉镜像 + 部署
log "拉取镜像 $IMAGE ..."
docker pull "$IMAGE"

# 若旧容器在跑, 先停
if docker ps -a --format '{{.Names}}' | grep -qx "$SERVICE_NAME"; then
  log "检测到旧容器 $SERVICE_NAME, 停止并删除 (数据目录保留) ..."
  docker stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  docker rm "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

log "启动容器 ..."
docker compose -f docker-compose.yml up -d

# ---------------------------------------------------------------- 4. 等待就绪
log "等待服务就绪 (health check) ..."
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT:-8091}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! curl -fsS "http://127.0.0.1:${PORT:-8091}/health" >/dev/null 2>&1; then
  warn "服务可能仍在启动, 请手动查看: docker logs -f $SERVICE_NAME"
fi

# ---------------------------------------------------------------- 5. 打印访问地址
PUB_IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "${PUB_IP:-}" ] && PUB_IP="<服务器IP>"
PORT="$(grep -E '^GRANIAN_PORT=' .env | cut -d= -f2 || echo 8091)"
ACCESS_KEY="$(grep -E '^ACCESS_KEY=' .env | cut -d= -f2)"

printf '\n'
printf '\033[1;34m================ 部署完成 ================\033[0m\n'
printf '\033[1;32m网站地址:  http://%s:%s\033[0m\n' "$PUB_IP" "$PORT"
printf '\033[1;32m本机:      http://127.0.0.1:%s\033[0m\n' "$PORT"
printf '访问密钥:  %s\n' "$ACCESS_KEY"
printf '容器名:    %s   |   镜像: %s\n' "$SERVICE_NAME" "$IMAGE"
printf '安装目录:  %s\n' "$INSTALL_DIR"
printf '\033[1;36m提示: 打开上面地址后用访问密钥登录。若被云服务器防火墙拦截,\033[0m\n'
printf '请在云控制台放行入方向 TCP 端口 %s 。\n' "$PORT"
printf '\033[1;34m============================================\033[0m\n'
log "完成。"
