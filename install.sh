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

# 任何未捕获错误: 打印中文原因后退出 (避免 set -e 静默终止, 让用户在 ssh 界面看懂卡在哪)
trap 'rc=$?; echo; echo "\033[1;31m[部署中断]\033[0m 第 $LINENO 行出错 (退出码 $rc)。" >&2; echo "若属 GPG/NO_PUBKEY 类, 见上方提示; 否则查上方最近的 [错误]/[注意] 行。" >&2' ERR

IMAGE="ghcr.io/goldsonhwy/gpt-image-linux:v2.1.0"
INSTALL_DIR="$HOME/gpt-image-panel"
SERVICE_NAME="gpt-image-panel"

log(){  printf '\033[1;32m[部署]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 或 sudo 运行本脚本"; exit 1; }

# ---------------------------------------------------------------- 0. 环境预检 + 暂停确认
# 检测: docker / 反代(caddy或nginx) / 必要依赖 -> 先暂停, 告诉用户什么已装/将装, 默认回车开装
probe(){ command -v "$1" >/dev/null 2>&1; }

log "环境预检 ..."
# 1) docker
if probe docker && docker compose version >/dev/null 2>&1; then
  HAS_DOCKER=1; DOCKER_STATE="docker + compose 已安装"
elif probe docker; then
  HAS_DOCKER=1; DOCKER_STATE="docker 已装, compose 插件缺失 (将补装 docker-compose-plugin)"
else
  HAS_DOCKER=0; DOCKER_STATE="docker 未安装 (将安装 docker-ce + 依赖)"
fi
# 2) 反代
RP_INSTALLED=""
if probe caddy; then RP_INSTALLED="caddy"; elif probe nginx; then RP_INSTALLED="nginx"; fi
# 3) 必要依赖
MISSING_DEPS=""
for d in ca-certificates curl gnupg openssl; do
  if ! dpkg -s "$d" >/dev/null 2>&1; then MISSING_DEPS="$MISSING_DEPS $d"; fi
done
[ -n "$MISSING_DEPS" ] && MISSING_DEPS="系统依赖未装:${MISSING_DEPS}"

# 汇总打印
echo
printf '%s\n' "========== 环境检查结果 =========="
printf '  [docker ] %s\n' "$DOCKER_STATE"
if [ -n "$RP_INSTALLED" ]; then
  printf '  [反代   ] 已装 %s (若填域名, 直接用它反代)\n' "$RP_INSTALLED"
else
  printf '  [反代   ] 未装 caddy/nginx; 若填域名, 将自动安装 caddy (含 HTTPS 证书)\n'
fi
if [ -n "$MISSING_DEPS" ]; then
  printf '  [依赖   ] %s -> 将 apt-get install\n' "$MISSING_DEPS"
else
  printf '  [依赖   ] ca-certificates/curl/gnupg/openssl 已齐\n'
fi
printf '  [将执行] 停止/删除旧容器 -> 拉镜像 %s -> 起容器 -> (有域名则配反代) -> 打印地址\n' "$IMAGE"
printf '%s\n' "=================================="
echo

# 暂停确认: 交互(tty)等输入, 默认回车=继续; 非交互(curl|bash)默认继续(可设 AUTO_NO=1 跳过)
DO_INSTALL=1
if [ -t 0 ] && [ "${AUTO_NO:-0}" != 1 ]; then
  read -r -p "开始安装? 回车继续 / 输 n 取消: " ANS || ANS=""
  case "$ANS" in
    n|N) DO_INSTALL=0 ;;
    *) DO_INSTALL=1 ;;
  esac
fi
if [ "$DO_INSTALL" != 1 ]; then
  warn "已取消, 未安装任何东西。"
  exit 0
fi
log "开始安装 ..."

# ---------------------------------------------------------------- 1. Docker + 依赖
need_docker=0;  command -v docker >/dev/null 2>&1 || need_docker=1

if [ "$need_docker" = 1 ]; then
  log "安装 Docker (官方仓库) ..."
  apt-get update -y || warn "apt-get update 有告警 (可能个别源 GPG 失败), 继续 ..."
  apt-get install -y ca-certificates curl gnupg lsb-release || warn "基础依赖安装失败: 检查网络/源配置"
  install -m 0755 -d /etc/apt/keyrings
  DIST="$(. /etc/os-release && echo "$ID")"; CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  ARCH="$(dpkg --print-architecture)"
  # 下载官方 GPG key (armored)
  if ! curl -fsSL "https://download.docker.com/linux/$DIST/gpg" -o /etc/apt/keyrings/docker.asc; then
    err "无法下载 Docker GPG key (原因: 网络不通或 download.docker.com 被墙/代理拦截)。"
    err "排查: 1) 服务器能否访问外网  2) 是否有代理需配置 http_proxy  3) 重试 curl -I https://download.docker.com"
    exit 1
  fi
  # 下载后校验 key 文件非空且像 GPG key (防下到空文件/HTML 错误页导致后续验签假成功)
  if [ ! -s /etc/apt/keyrings/docker.asc ] || ! grep -q "BEGIN PGP PUBLIC KEY BLOCK\|-----BEGIN PGP\|0x" /etc/apt/keyrings/docker.asc; then
    err "下载到的 GPG key 文件异常 (原因: 空文件/被代理拦截返回了 HTML/格式不符)。"
    err "排查: 手动 'curl -I https://download.docker.com/linux/$DIST/gpg' 看是否 200; 若走代理检查 http_proxy。"
    exit 1
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  # 同时生成 dearmor 版 .gpg (部分 apt/全新机只认二进制)
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc 2>/dev/null || true

  # 验签探测: 写 .list, 跑 apt update, 抓输出判断 NO_PUBKEY (apt update 部分失败仍退0, 必须看输出)
  try_docker_repo(){  # $1=signed-by 路径
    echo "deb [arch=$ARCH signed-by=$1] https://download.docker.com/linux/$DIST $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    local out
    out="$(apt-get update -y 2>&1 || true)"
    if echo "$out" | grep -q "NO_PUBKEY"; then return 1; fi
    if echo "$out" | grep -qE "download\.docker\.com.*$CODENAME|docker.*InRelease"; then return 0; fi
    echo "$out" | grep -q "W: GPG error\|E: The repository" && return 1 || true
    return 0
  }

  ok=0
  # 1) 先试 dearmor 二进制 .gpg
  if [ -s /etc/apt/keyrings/docker.gpg ] && try_docker_repo /etc/apt/keyrings/docker.gpg; then
    ok=1; log "Docker GPG key (.gpg 二进制) 验签通过。"
  fi
  # 2) 退回 armored .asc
  if [ "$ok" = 0 ] && try_docker_repo /etc/apt/keyrings/docker.asc; then
    ok=1; log "Docker GPG key (.asc armored) 验签通过。"
  fi
  # 3) 都失败 -> 放行不验签装好 docker (NO_PUBKEY 通常是 Docker 换 key 或 key 文件不完整; 放行可先装, 装后重新验签)
  if [ "$ok" = 0 ]; then
    warn "Docker 仓库 GPG 验签失败 (NO_PUBKEY)。"
    warn "原因: apt 缺少 Docker 签名公钥 / key 文件与 InRelease 不匹配 / Docker 换了签名 key。"
    warn "处理: 本次先【临时放行不验签】装好 docker (安全: docker-ce 包体另有 SHA512 校验)。"
    echo "deb [arch=$ARCH] https://download.docker.com/linux/$DIST $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y -o Acquire::AllowInsecureRepositories=true 2>/dev/null || warn "放行后 apt 更新仍有告警 (见上), 继续尝试安装 ..."
  fi

  if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    err "Docker 安装失败 (原因: 上述 apt 步骤某处报错, 可能放行后网络仍不稳或仓库被禁)。"
    err "排查: 手动跑 'apt-get install -y docker-ce' 看完整报错; 或确认该机器 distro=$DIST/$CODENAME 受支持。"
    exit 1
  fi
  # 装好后恢复严格验签 (重新 update, 此时 apt 已缓存 docker key)
  apt-get update -y >/dev/null 2>&1 || true
  systemctl enable --now docker || warn "docker 服务启动失败: 请手动 'systemctl enable --now docker' 并查 'journalctl -u docker'"
else
  log "检测到 Docker 已安装, 跳过。"
fi
systemctl enable --now docker 2>/dev/null || true
# compose 在 docker 就绪后再检测 (避免 docker 未装时误判)
need_compose=0; docker compose version >/dev/null 2>&1 || need_compose=1
# compose 插件缺失 -> 补装
if [ "$need_compose" = 1 ]; then
  log "安装 docker-compose-plugin ..."
  apt-get install -y docker-compose-plugin >/dev/null || warn "compose 插件安装失败, 请手动装 docker-compose"
fi

log "安装系统依赖 ..."
apt-get install -y git curl ca-certificates jq openssl >/dev/null 2>&1 || true

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
  # 清洗域名: 去掉 http(s):// 前缀和尾部斜杠
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
  ACCESS_KEY=""
  if [ -t 0 ]; then
    read -r -p "访问密钥 ACCESS_KEY (默认留空=首次进面板自行设置密码; 直接回车跳过): " ACCESS_KEY || true
  fi
  # 生成 .env (仅覆盖 compose 实际用到的关键项; 其余用镜像默认值)
  # 访问密码: 默认留空 -> 面板首次进入时【自行设置密码】(你的需求)
  #          手动填了 -> 直接锁定该密码, 不再首次自设
  {
    echo "GRANIAN_PORT=${PORT}"
    [ -n "$ACCESS_KEY" ] && echo "ACCESS_KEY=${ACCESS_KEY}" || echo "ACCESS_KEY="
    echo "DOMAIN=${DOMAIN}"
  } > "$INSTALL_DIR/.env"
  if [ -n "$DOMAIN" ]; then
    echo "PUBLIC_ORIGIN=https://$DOMAIN" >> "$INSTALL_DIR/.env"
    echo "ALLOWED_HOSTS=$DOMAIN,127.0.0.1:$PORT,localhost:$PORT" >> "$INSTALL_DIR/.env"
    log "已生成 .env (端口 $PORT, 域名 $DOMAIN -> HTTPS 反代)"
  else
    log "已生成 .env (端口 $PORT, 无域名 -> 仅 IP 直连)"
  fi
  if [ -n "$ACCESS_KEY" ]; then
    log "已设访问密钥: ${ACCESS_KEY:0:4}... (登录面板用它)"
  else
    log "访问密钥留空 -> 首次打开面板时按提示自行设置密码"
  fi
fi

# ---------------------------------------------------------------- 3. 部署 (生成 compose 兜底, 不依赖 clone)
cd "$INSTALL_DIR"
# 无论 .env 新建还是复用, 确保 PORT/ACCESS_KEY 有值 (set -u 防 unbound)
PORT="$(grep -E '^GRANIAN_PORT=' .env 2>/dev/null | cut -d= -f2 || true)"
[ -z "$PORT" ] && PORT=8091
ACCESS_KEY="$(grep -E '^ACCESS_KEY=' .env 2>/dev/null | cut -d= -f2 || true)"
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
if ! docker pull "$IMAGE"; then
  err "拉取镜像失败 (原因: 无法访问 ghcr.io / 网络受限 / 镜像标签不存在 / docker 未登录该仓库)。"
  err "排查: 1) 试 'docker pull $IMAGE' 看完整报错  2) 服务器能否访问 ghcr.io  3) 若在受限网络, 配置 http_proxy/https_proxy 后重试。"
  exit 1
fi

# 旧容器先停 (数据目录保留)
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVICE_NAME"; then
  log "检测到旧容器 $SERVICE_NAME, 停止并删除 ..."
  docker stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  docker rm "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

log "启动容器 ..."
if ! docker compose -f docker-compose.yml up -d; then
  err "容器启动失败 (原因: 端口 $PORT 被占用 / .env 配置错 / 镜像架构不符 / compose 语法错)。"
  err "排查: 1) 'docker logs $SERVICE_NAME' 看容器日志  2) 确认端口未被占: 'ss -ltnp | grep $PORT'  3) 检查 $INSTALL_DIR/.env。"
  exit 1
fi

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
  # 5a. 检测已装反代: caddy 优先, 其次 nginx (if 包裹, 防 set -e 在检测不到时崩)
  RP=""
  if command -v caddy >/dev/null 2>&1; then RP="caddy"; fi
  if [ -z "$RP" ] && command -v nginx >/dev/null 2>&1; then RP="nginx"; fi
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
    # caddy: 在默认 Caddyfile 追加域名站点 (不破坏已有其它站点)
    mkdir -p /etc/caddy
    CADDY_MAIN="/etc/caddy/Caddyfile"
    # 文件不存在则创建空 Caddyfile; 已含该域名则跳过 (幂等)
    [ -f "$CADDY_MAIN" ] || : > "$CADDY_MAIN"
    if ! grep -qxF "$DOMAIN" "$CADDY_MAIN"; then
      cat >> "$CADDY_MAIN" <<EOF

# gpt-image-panel (install.sh)
$DOMAIN {
    reverse_proxy 127.0.0.1:${PORT} {
        header_up Host {upstream_hostport}
    }
    encode gzip zstd
}
EOF
      log "已向 $CADDY_MAIN 追加 $DOMAIN 站点。"
    fi
    systemctl enable --now caddy >/dev/null 2>&1 || systemctl restart caddy 2>/dev/null || true
    caddy validate --config "$CADDY_MAIN" >/dev/null 2>&1 || warn "caddy 配置校验失败, 请检查 $CADDY_MAIN"
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy 2>/dev/null || true
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
if [ -n "$ACCESS_KEY" ]; then
  printf '访问密钥:  %s  (用它在面板登录)\n' "$ACCESS_KEY"
else
  printf '访问密钥:  (未设) -> 首次打开面板时按提示自行设置密码\n'
fi
printf '容器名:    %s   |   镜像: %s\n' "$SERVICE_NAME" "$IMAGE"
printf '安装目录:  %s\n' "$INSTALL_DIR"
printf '\033[1;36m提示: 首次进入面板会要求设置访问密码; 若被云防火墙拦截, 放行入方向 TCP 80/443 (有域名) 或 %s (直连)。\033[0m\n' "$PORT"
printf '\033[1;34m============================================\033[0m\n'
log "完成。"
