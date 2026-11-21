GPT Image Panel - 免安装二进制版 (Windows x64)

【运行】
双击 run.bat 启动，浏览器打开 http://127.0.0.1:9090
（也可以直接运行 gpt-image-panel.exe，但用 run.bat 会保证 images/data 目录存在）

【停止】
在运行窗口按 Ctrl+C。

【数据存放】
所有生成的图片在 images\ 目录，数据库在 data\app.sqlite3。
这两个目录就在本文件夹内，跟 exe 在一起，拷贝整个文件夹即可迁移/备份。

【配置】
本版本默认无访问密钥（ALLOW_UNAUTHENTICATED=true），仅建议本机使用。
如需访问密钥等设置，可在启动前设置环境变量，例如：
  set ACCESS_KEY=你的密钥
  set PORT=9090
  set HOST=127.0.0.1
  run.bat

真正生成图片需要在网页的设置里填入 GPT 兼容图片 API 的地址和密钥。

【说明】
本程序为绿色版，不需要安装 Python 或 Node，也不需要 Docker。
前端页面和后端已全部打包在内。
