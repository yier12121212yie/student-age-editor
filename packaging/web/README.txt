学生时代模组编辑器 · 网页版（web-app）使用说明
================================================

本 zip 是 `flutter build web` 的产物，属独立发行物，与桌面安装包/APK 互不
混包。解压后得到网页资源目录（含 index.html、main.dart.js 等）。

一、本机浏览器形态（推荐起步）
  1. 下载本 web-app zip 与对应平台的桌面发行包（student-age-editor-*.zip），
     两者分别解压。
  2. 在桌面包目录打开终端/命令行，执行：
         backend --web-root <web-app 解压目录>
     （Windows 为 backend.exe；backend 会一并拉起本地后端服务。）
  3. 按命令行提示的地址（默认本机端口）在浏览器打开即可使用；
     数据与桌面版同源，缓存写在 backend 工作目录。

二、在线托管形态
  Linux 服务器部署 backend + backend_gateway（发行物
  editor-server-linux-*.zip），配 systemd 服务与 Caddy 反向代理（TLS），
  网页资源（本 zip 内容）由 backend --web-root 托管或由 Caddy 直接服务。
  示例 systemd unit / Caddyfile 见服务器包内 gateway/ 目录。

完整指南见仓库 WEB_GUIDE.md（在线托管、HTTPS 域名、端口与鉴权等细节）。
