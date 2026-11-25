# GPT Image Panel

![FastAPI](https://img.shields.io/badge/FastAPI-0.115+-009688?logo=fastapi)
![SvelteKit](https://img.shields.io/badge/SvelteKit-2-FF3E00?logo=svelte)
![Python](https://img.shields.io/badge/Python-3.11+-3776AB?logo=python)
![SQLite](https://img.shields.io/badge/SQLite-3-003B57?logo=sqlite)
![Docker](https://img.shields.io/badge/Docker-24.0+-2496ED?logo=docker)

## 一键部署（Debian/Ubuntu，无需反代）

```bash
curl -fsSL https://raw.githubusercontent.com/goldsonhwy/gpt-image-linux/main/manage.sh | bash
# 运行后选: 1=安装, 2=卸载
```

> **统一脚本 `manage.sh`**（安装+卸载合并）：选 `1` 安装——环境预检+暂停确认 → 装 Docker/依赖 → 拉镜像起容器 → 有域名自动 HTTPS 反代 → 打印地址；访问密码**默认留空=首次进面板自行设置**（想手动锁定就在交互处填）。选 `2` 卸载——只删本程序+其产物（容器/镜像/数据目录/我加的 caddy 站点），**不删 docker、不删 caddy/nginx 反代程序**。
>
> 旧的 [`install.sh`](install.sh) / [`uninstall.sh`](uninstall.sh) 仍保留可用（向后兼容），功能等同。

> 不填域名 = 纯 IP:端口 直连（无反代）；填域名 = 自动 HTTPS 反代（域名 DNS A 记录需指向本机 IP）。

## 本 fork 相比原版的改动（gima 版）

> 本仓库 fork 自 [原版 GPT Image Panel](https://github.com/Z1rconium/gpt-image-panel)（上游：Z1rconium/gpt-image-panel）。原版的功能与用法见其 README；以下是本 fork 在原版基础上额外做的修改。

### 前端（`frontend/`，构建产物随仓库发布在 `frontend-build/`）

- **图库分页改为「加载更多」**：底部原来的「上一页 / 下一页 / 第 X 页输入框」被替换成中间一个居中的「加载更多」按钮；点击在下方**追加**下一页，已加载的页面全部保留，可一直点直到没有更多。
- **等待进度条 15 档渐变**：生成等待期间的进度条从原来的 3 色（绿/黄/红）改为 **15 档颜色渐变**（浅绿 `#A8E6CF` → 黑红 `#1A0005`），并按 15 个时间档位切换底部提示文案（0–90s 封顶）。
- **页头交互调整**：点击左上角 Logo（图标 + 标题）整块**刷新页面**（重新进入）；中英文切换按钮从最左边移到**最右侧**、紧挨「反推」按钮的左边。
- **生成按钮无限排队**：提交一次任务后「开始生成」按钮**不再置灰**、不再限并发、无冷却，可持续点击排队下一个任务；仅编辑态（参考图编辑进行中）仍会暂时禁用。
- **预览图自适应**：高瘦图片（如 821×1916）在预览框内**整体缩放到一屏看全**，不滚动、不裁切（原为滚动或裁切）。
- **参考图选择器 / 双列 fullpage 布局**：参考图改为 2 列网格、整卡宽 contain；工作台三列布局（提示词 | 预览 | 参数+参考图+生成），参数模块放到右列。

### 后端（`backend/`）

- **收藏夹（collections）**：新增图库收藏/集合的 CRUD 路由，前端「存到收藏夹 / 收藏夹」功能依赖它。
- **批量 ZIP 导入（async 202 + 任务轮询）**：图库支持整包 ZIP 导入（含 `metadata.json`），异步导入任务可轮询进度；前端「上传参考图存入收藏夹」即走此通道。

> 其余原版功能、用法与默认行为保持不变。
