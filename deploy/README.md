# 一键部署到服务器（Ubuntu / Debian）

## 用法

在一台干净的 Ubuntu/Debian 服务器上，root 或 sudo 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/goldsonhwy/gpt-image-linux/main/deploy/deploy.sh -o deploy.sh
sudo bash deploy.sh
```

脚本会自动完成：
1. 安装 git / Python3 / venv / Node.js 22 / nginx
2. 克隆或更新代码到 `/opt/gpt-image-panel`
3. 创建 Python 虚拟环境并安装后端依赖
4. 构建前端
5. 创建 systemd 服务 `gpt-image-panel`（开机自启、崩溃自动重启）
6. 配置 nginx 反向代理（80 端口）
7. 输出访问地址

脚本是幂等的——再次运行即更新到最新版本，不会重复安装出问题。

## 首次使用

浏览器打开服务器 IP，**首次访问会要求注册管理员账户**（用户名 + 密码，无需激活码）。注册后自动登录，Cookie 有效期 10 年，不会半天掉线。

真正生成图片时，在网页「设置」里填入 GPT 兼容图片 API 的地址和密钥。

## 常用命令

```bash
# 服务状态 / 日志
sudo systemctl status gpt-image-panel
sudo journalctl -u gpt-image-panel -f

# 重启 / 停止
sudo systemctl restart gpt-image-panel
sudo systemctl stop gpt-image-panel

# 更新到最新版本（重新跑部署脚本即可）
sudo bash deploy.sh
```

## 配置

所有运行时配置在 `/opt/gpt-image-panel/.env`：

- `PORT` — 后端端口（默认 9090）
- `SESSION_DAYS` — 登录有效期天数（默认 3650 天）
- `SESSION_SECRET` — 签名密钥，重装系统外的重启都靠它保持登录，建议保持默认生成值不变
- `ALLOW_UNAUTHENTICATED=true` — 允许无激活码启动（认证由网页注册管理员完成）

图片和数据库在 `/opt/gpt-image-panel/images` 和 `/opt/gpt-image-panel/data/app.sqlite3`，备份只需拷贝这两个目录。

## HTTPS（可选）

脚本默认开 80 端口。上 HTTPS 可在 nginx 配置里加证书，例如用 certbot：

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d your-domain.com
```
