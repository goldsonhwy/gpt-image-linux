#!/usr/bin/env bash
#
# GPT Image Panel — 一键卸载脚本 (配合 install.sh 使用)
# 删掉 install.sh 装的东西: 容器/镜像/数据目录/.env/反代(caddy 站点)/装的系统包
# 幂等, 可重复跑; 不影响其它程序; 删前列出将删什么, 输 y 确认 (DRY=1 只列不执行)。
# 用法 (在装了它的那台机器上):
#   curl -fsSL https://raw.githubusercontent.com/goldsonhwy/gpt-image-linux/main/uninstall.sh | bash
set -uo pipefail

SERVICE_NAME="gpt-image-panel"
IMAGE="ghcr.io/z1rconium/gpt-image-linux:v2.0.0"
INSTALL_DIR="$HOME/gpt-image-panel"
DRY="${DRY:-0}"          # DRY=1 只列出将删什么, 不执行
CONFIRM="${CONFIRM:-1}"  # CONFIRM=0 跳过 y/N 确认
CADDY_MARKER="# gpt-image-panel (install.sh)"   # install.sh 写进 Caddyfile 的站点标记

run(){  # DRY 模式只打印不执行
  if [ "$DRY" = 1 ]; then printf '  [DRY] %s\n' "$*"; else "$@"; fi
}

echo "============================================"
echo " GPT Image Panel 卸载"
echo "============================================"

# 1. 停并删容器
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVICE_NAME"; then
  echo "- 容器 $SERVICE_NAME (将停止并删除)"
  run docker stop "$SERVICE_NAME" 2>/dev/null || true
  run docker rm "$SERVICE_NAME" 2>/dev/null || true
else
  echo "- 容器 $SERVICE_NAME: 不存在 (跳过)"
fi

# 2. 删镜像 (仅该 tag)
if docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "$IMAGE"; then
  echo "- 镜像 $IMAGE (将删除)"
  run docker rmi "$IMAGE" 2>/dev/null || true
else
  echo "- 镜像 $IMAGE: 不存在 (跳过)"
fi

# 3. 数据目录 (.env / 图片 / 日志)
if [ -d "$INSTALL_DIR" ]; then
  echo "- 数据目录 $INSTALL_DIR (含 .env / 图片 / 日志, 将删除)"
  run rm -rf "$INSTALL_DIR"
else
  echo "- 数据目录 $INSTALL_DIR: 不存在 (跳过)"
fi

# 4. caddy 反代站点 (仅删我加的那段, 用 marker 识别, 避免误删别人的 Caddyfile)
CADDY_MAIN="/etc/caddy/Caddyfile"
if [ -f "$CADDY_MAIN" ] && grep -qF "$CADDY_MARKER" "$CADDY_MAIN"; then
  echo "- caddy 站点 (我加的, 将从 $CADDY_MAIN 移除)"
  if [ "$DRY" = 1 ]; then
    echo "  [DRY] 移除 caddy 站点 + 重载"
  else
    tmp="$(mktemp)"
    # 删我加的块: 从 marker 行开始, 删到该站点块的收尾 "}" (顶格 }, 站点级)
    awk -v m="$CADDY_MARKER" '
      index($0, m) { skip=1; depth=0 }
      skip {
        depth += gsub(/\{/,"{") - gsub(/\}/,"}")
        if (depth<=0 && $0 ~ /\}/) skip=0
        next
      }
      { print }
    ' "$CADDY_MAIN" > "$tmp"
    cp "$tmp" "$CADDY_MAIN"
    rm -f "$tmp"
    # 删后若 Caddyfile 只剩空白/注释, 写个空占位避免 caddy validate 报错
    if ! grep -qE '^[^#[:space:]]' "$CADDY_MAIN"; then printf '# (no sites)\n' > "$CADDY_MAIN"; fi
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
  fi
else
  echo "- caddy 站点: 未找到我加的 (跳过, 不误删)"
fi

# 确认 (DRY=1 或 CONFIRM=0 时跳过交互)
if [ "$DRY" != 1 ] && [ "$CONFIRM" = 1 ]; then
  echo
  read -r -p "确认删除以上? 输 y 继续 (其它回车取消): " ans || ans=""
  [ "$ans" != "y" ] && { echo "已取消, 未删除任何东西。"; exit 0; }
  echo "开始执行 ..."
fi

echo "已卸载。若想彻底移除 Docker 本身 (一般不需要, 可能装过别的), 可另跑:"
echo "  apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && apt-get autoremove -y"